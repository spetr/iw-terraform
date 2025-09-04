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
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.ec2_key_name

  user_data = <<-EOF
              #!/bin/bash
              set -euxo pipefail
              dnf -y update
              dnf -y install amazon-efs-utils nfs-utils
              # Ensure SSM Agent is running (preinstalled on Amazon Linux 2023)
              systemctl enable --now amazon-ssm-agent || true
              mkdir -p /opt/icewarp/config
              mkdir -p /opt/icewarp/mail
              if [ -n "${try(aws_efs_file_system.archive[0].id, "")}" ]; then
                mkdir -p /opt/icewarp/archive
              fi
              echo "${aws_efs_file_system.config.id}:/ /opt/icewarp/config efs _netdev,tls,nconnect=16,noresvport,nfsvers=4.1 0 0" >> /etc/fstab
              echo "${aws_efs_file_system.data.id}:/ /opt/icewarp/mail efs _netdev,tls,nconnect=16,noresvport,nfsvers=4.1 0 0" >> /etc/fstab
              # Mount archive EFS if created
              if [ -n "${try(aws_efs_file_system.archive[0].id, "")}" ]; then
                echo "${try(aws_efs_file_system.archive[0].id, "")}:/ /opt/icewarp/archive efs _netdev,tls,nconnect=4,noresvport,nfsvers=4.1 0 0" >> /etc/fstab
              fi
              systemctl daemon-reload
              mount -a -t efs,nfs4
              # Simple web app placeholder
              dnf install -y nginx
              echo "<h1>${var.project}-${var.environment} EC2 up (${count.index})</h1>" > /usr/share/nginx/html/index.html
              systemctl enable --now nginx
              EOF

  tags = {
  Name = "${var.project}-${var.environment}-app-${count.index}"
  }
}

# SSM-only Bastion (no public IP, no inbound SSH; access via SSM Session Manager)
resource "aws_security_group" "bastion_sg" {
  count       = var.create_bastion ? 1 : 0
  name        = "${var.project}-${var.environment}-bastion"
  description = "Bastion SG (SSM-only, no inbound)"
  vpc_id      = aws_vpc.main.id

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
  vpc_security_group_ids = [aws_security_group.bastion_sg[0].id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  associate_public_ip_address = false

  user_data = <<-EOF
              #!/bin/bash
              set -euxo pipefail
              dnf -y update
              # Ensure SSM Agent is running (preinstalled on Amazon Linux 2023)
              systemctl enable --now amazon-ssm-agent || true
              # No SSH opening; rely on SSM
              EOF

  tags = {
    Name = "${var.project}-${var.environment}-bastion"
  }
}
