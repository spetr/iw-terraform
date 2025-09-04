data "aws_ssm_parameter" "al2023_ami" {
  # Amazon Linux 2023 (x86_64) latest AMI ID via SSM Parameter Store
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64"
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
}

resource "aws_instance" "app" {
  count                  = var.ec2_instance_count
  ami                    = var.ec2_ami_id != null ? var.ec2_ami_id : data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.ec2_instance_type
  subnet_id              = element(local.private_subnet_ids, count.index % length(local.private_subnet_ids))
  private_ip             = cidrhost(var.private_subnets[0], 11 + count.index)
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
              HOSTNAME="${var.project}-${var.environment}-app-${count.index}"
              hostnamectl set-hostname "$HOSTNAME"
              mkdir -p /etc/cloud/cloud.cfg.d
              printf "preserve_hostname: true\n" > /etc/cloud/cloud.cfg.d/99_hostname.cfg
              grep -q "\b$HOSTNAME\b" /etc/hosts || echo "127.0.0.1 $HOSTNAME" >> /etc/hosts

              # Simple web app placeholder
              dnf install -y nginx
              echo "<h1>${var.project}-${var.environment} EC2 up (${count.index})</h1>" > /usr/share/nginx/html/index.html
              systemctl enable --now nginx

              mkdir -p /opt/icewarp/config
              mkdir -p /opt/icewarp/mail
              if [ -n "${try(aws_efs_file_system.archive[0].id, "")}" ]; then
                mkdir -p /opt/icewarp/archive
              fi
              echo "${aws_efs_file_system.config.id}.efs.${var.aws_region}.amazonaws.com:/ /opt/icewarp/config efs _netdev,tls,nconnect=4,noresvport,nfsvers=4.1,noatime,nodiratime,rsize=1048576,wsize=1048576 0 0" >> /etc/fstab
              echo "${aws_efs_file_system.data.id}.efs.${var.aws_region}.amazonaws.com:/ /opt/icewarp/mail efs _netdev,tls,nconnect=16,noresvport,nfsvers=4.1,noatime,nodiratime,rsize=1048576,wsize=1048576 0 0" >> /etc/fstab
              if [ -n "${try(aws_efs_file_system.archive[0].id, "")}" ]; then
                echo "${try(aws_efs_file_system.archive[0].id, "")}.efs.${var.aws_region}.amazonaws.com:/ /opt/icewarp/archive efs _netdev,tls,nconnect=8,noresvport,nfsvers=4.1,noatime,nodiratime,rsize=1048576,wsize=1048576 0 0" >> /etc/fstab
              fi
              systemctl daemon-reload
              mount -a -t efs,nfs4

              EOF

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
  ami                    = var.ec2_ami_id != null ? var.ec2_ami_id : data.aws_ssm_parameter.al2023_ami.value
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

  tags = {
    Name = "${var.project}-${var.environment}-bastion"
  }
}
