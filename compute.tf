data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
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
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ec2_instance_type
  subnet_id              = element(local.private_subnet_ids, count.index % length(local.private_subnet_ids))
  vpc_security_group_ids = [aws_security_group.ec2_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  key_name               = var.ec2_key_name

  user_data = <<-EOF
              #!/bin/bash
              set -euxo pipefail
              dnf update -y
              dnf install -y amazon-efs-utils nfs-utils
              mkdir -p /mnt/data /mnt/config
              echo "${aws_efs_file_system.data.id}:/ /mnt/data efs _netdev,tls 0 0" >> /etc/fstab
              echo "${aws_efs_file_system.config.id}:/ /mnt/config efs _netdev,tls 0 0" >> /etc/fstab
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
