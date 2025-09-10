data "aws_ssm_parameter" "al2023_ami" {
  # Amazon Linux 2023 (x86_64) latest AMI ID via SSM Parameter Store
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
}

data "aws_ssm_parameter" "al2023_ami_arm64" {
  # Amazon Linux 2023 (ARM64) latest AMI ID via SSM Parameter Store
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}

resource "aws_iam_role" "ec2_ssm_role" {
  name = "${var.project}-${var.environment}-ec2-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-${var.environment}-ec2-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

locals {
  private_subnet_ids = [for s in aws_subnet.private : s.id]
  private_subnet_azs = [for s in aws_subnet.private : s.availability_zone]
}

resource "aws_instance" "app" {
  count                  = var.app_instance_count
  ami                    = var.app_ami_id != null ? var.app_ami_id : data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.app_instance_type
  subnet_id              = element(local.private_subnet_ids, count.index % length(local.private_subnet_ids))
  private_ip             = cidrhost(var.private_subnets[count.index % length(local.private_subnet_ids)], 11 + count.index)
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.ec2_key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
              #!/bin/bash
              set -euxo pipefail
              dnf -y update
              dnf -y install amazon-efs-utils nfs-utils

              # Ensure SSM Agent is running (preinstalled on Amazon Linux 2023)
              systemctl enable --now amazon-ssm-agent || true

              # Ensure SSH is installed and running
              dnf -y install openssh-server || true
              systemctl enable --now sshd || true

              # Set and preserve hostname to match the instance Name tag
              HOSTNAME="${var.project}-${var.environment}-app-${count.index + 1}"
              hostnamectl set-hostname "$HOSTNAME"
              mkdir -p /etc/cloud/cloud.cfg.d
              printf "preserve_hostname: true\n" > /etc/cloud/cloud.cfg.d/99_hostname.cfg
              grep -q "\b$HOSTNAME\b" /etc/hosts || echo "127.0.0.1 $HOSTNAME" >> /etc/hosts

              mkdir -p /mnt/data/config
              mkdir -p /mnt/data/mail
              if [ -n "${try(aws_efs_file_system.archive[0].id, "")}" ]; then
                mkdir -p /mnt/data/archive
              fi
              echo "${aws_efs_file_system.config.id}:/ /mnt/data/config efs _netdev,tls,noatime,nodiratime 0 0" >> /etc/fstab
              echo "${aws_efs_file_system.data.id}:/ /mnt/data/mail efs _netdev,tls,noatime,nodiratime 0 0" >> /etc/fstab
              if [ -n "${try(aws_efs_file_system.archive[0].id, "")}" ]; then
                echo "${try(aws_efs_file_system.archive[0].id, "")}:/ /mnt/data/archive efs _netdev,tls,noatime,nodiratime 0 0" >> /etc/fstab
              fi
              systemctl daemon-reload
              mount -a -t efs,nfs4

              EOF

  lifecycle {
    ignore_changes = [
      ami,
      user_data,
    ]
  }

  tags = {
  Name = "${var.project}-${var.environment}-app-${count.index + 1}"
  }
}

# SSM-only Bastion (no public IP, no inbound SSH; access via SSM Session Manager)
resource "aws_security_group" "bastion_sg" {
  count       = var.create_bastion ? 1 : 0
  name        = "${var.project}-${var.environment}-bastion"
  description = "Bastion SG (SSM-only, no inbound)"
  vpc_id      = aws_vpc.main.id

  # Optional SSH ingress to bastion when enabled
  dynamic "ingress" {
    for_each = var.enable_ssh_access ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.allowed_ssh_cidr
    }
  }

  # Allow ICMP within VPC for diagnostics (ping)
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "bastion" {
  count                  = var.create_bastion ? 1 : 0
  ami                    = data.aws_ssm_parameter.al2023_ami_arm64.value
  instance_type          = var.bastion_instance_type
  subnet_id              = local.private_subnet_ids[0]
  private_ip             = cidrhost(var.private_subnets[0], 10)
  vpc_security_group_ids = [aws_security_group.bastion_sg[0].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false
  key_name               = var.ec2_key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
              #!/bin/bash
              set -euxo pipefail
              dnf -y update
              # Ensure SSM Agent is running (preinstalled on Amazon Linux 2023)
              systemctl enable --now amazon-ssm-agent || true
              # Ensure SSH is installed and running
              dnf -y install openssh-server || true
              systemctl enable --now sshd || true
              # Set default shell to bash for ssm-user once it exists (created by SSM Agent)              
              usermod -s /bin/bash ssm-user || true
              systemctl enable --now set-ssm-user-shell.service || true
              # Set and preserve hostname to match the instance Name tag
              HOSTNAME="${var.project}-${var.environment}-bastion"
              hostnamectl set-hostname "$HOSTNAME"
              mkdir -p /etc/cloud/cloud.cfg.d
              printf "preserve_hostname: true\n" > /etc/cloud/cloud.cfg.d/99_hostname.cfg
              grep -q "\b$HOSTNAME\b" /etc/hosts || echo "127.0.0.1 $HOSTNAME" >> /etc/hosts
              # SSH available if security group allows it; SSM remains available
              EOF

  lifecycle {
    ignore_changes = [
      ami,
      user_data,
    ]
  }

  tags = {
    Name = "${var.project}-${var.environment}-bastion"
  }
}

# Dedicated EC2 instance for Fulltext
resource "aws_instance" "fulltext" {
  count                  = var.fulltext_instance_count
  ami                    = data.aws_ssm_parameter.al2023_ami_arm64.value
  instance_type          = var.fulltext_instance_type
  subnet_id              = element(local.private_subnet_ids, count.index % length(local.private_subnet_ids))
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.ec2_key_name
  user_data_replace_on_change = true

  # Keep user_data minimal; volume will be attached separately
  user_data = <<-EOF
              #!/bin/bash
              set -euxo pipefail
              dnf -y update
              # Ensure SSM Agent is running (preinstalled on Amazon Linux 2023)
              systemctl enable --now amazon-ssm-agent || true
              # Ensure SSH is installed and running
              dnf -y install openssh-server || true
              systemctl enable --now sshd || true
              EOF

  lifecycle {
    ignore_changes = [
      ami,
      user_data,
    ]
  }

  tags = {
    Name = "${var.project}-${var.environment}-fulltext-${count.index + 1}"
  }
}

# EBS volumes for Fulltext EC2 instances (one per instance)
resource "aws_ebs_volume" "fulltext" {
  count             = var.fulltext_instance_count
  availability_zone = element(local.private_subnet_azs, count.index % length(local.private_subnet_azs))
  size              = var.fulltext_ebs_size_gb
  type              = "gp3"

  tags = {
    Name = "${var.project}-${var.environment}-fulltext-data-${count.index + 1}"
  }
}

# Attach each EBS volume to its corresponding Fulltext instance
resource "aws_volume_attachment" "fulltext" {
  count       = var.fulltext_instance_count
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.fulltext[count.index].id
  instance_id = aws_instance.fulltext[count.index].id
}
