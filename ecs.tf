############################################
# ECS Fargate service for docconvert
#
# Runs container "docconvert" from a private ECR in another account:
#   598044228206.dkr.ecr.eu-central-1.amazonaws.com/mundi/prod
#
# Notes (cross-account ECR): The source ECR repository (in account 598044228206)
# must have a repository policy that allows this account to pull images
# (ecr:BatchGetImage, ecr:GetDownloadUrlForLayer, ecr:BatchCheckLayerAvailability).
# The task execution role here has standard permissions via
# AmazonECSTaskExecutionRolePolicy to authenticate to ECR and write CloudWatch logs.
############################################

resource "aws_ecs_cluster" "docconvert" {
  name = "${var.project}-${var.environment}-ecs"
}

resource "aws_cloudwatch_log_group" "docconvert" {
  name              = "/ecs/${var.project}-${var.environment}-docconvert"
  retention_in_days = 14
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project}-${var.environment}-ecs-execution"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = { Service = "ecs-tasks.amazonaws.com" },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "docconvert" {
  family                   = "${var.project}-${var.environment}-docconvert"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.docconvert_cpu)
  memory                   = tostring(var.docconvert_memory)
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  container_definitions = jsonencode([
    {
      name  = "docconvert",
      image = var.docconvert_image,
      essential = true,
      portMappings = [{
        containerPort = var.docconvert_container_port,
        hostPort      = var.docconvert_container_port,
        protocol      = "tcp"
      }],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = aws_cloudwatch_log_group.docconvert.name,
          awslogs-region        = var.aws_region,
          awslogs-stream-prefix = "docconvert"
        }
      }
    }
  ])
}

resource "aws_security_group" "docconvert" {
  name        = "${var.project}-${var.environment}-docconvert"
  description = "Security group for docconvert ECS tasks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "From EC2 app instances"
    from_port       = var.docconvert_container_port
    to_port         = var.docconvert_container_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2_sg.id]
  }

  # Restrict all outbound to within VPC only (no Internet)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
}

# Service discovery (Cloud Map) for private name resolution inside VPC
resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = var.service_discovery_namespace
  description = "Private DNS namespace for ECS services"
  vpc         = aws_vpc.main.id
}

resource "aws_service_discovery_service" "docconvert" {
  name = "docconvert"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }
  health_check_custom_config {
    failure_threshold = 1
  }
}

resource "aws_ecs_service" "docconvert" {
  name            = "${var.project}-${var.environment}-docconvert"
  cluster         = aws_ecs_cluster.docconvert.id
  task_definition = aws_ecs_task_definition.docconvert.arn
  desired_count   = var.docconvert_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [for s in aws_subnet.private : s.id]
    security_groups = [aws_security_group.docconvert.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.docconvert.arn
  }
}
