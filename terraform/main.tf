resource "aws_ecs_cluster" "jsonmock_ecs_cluster" {
  name = "jsonmock-${terraform.workspace}"

  setting {
    name  = "containerInsights"
    value = terraform.workspace == "PROD" ? "enabled" : "disabled"
  }

  tags = var.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "jsonmock_cluster_capacityprovider" {
  cluster_name = aws_ecs_cluster.jsonmock_ecs_cluster.name

  capacity_providers = [terraform.workspace == "PROD" ? "FARGATE" : "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = terraform.workspace == "PROD" ? "FARGATE" : "FARGATE_SPOT"
  }
}


resource "aws_cloudwatch_log_group" "ecs_service_log_group" {
  name              = "/ecs/jsonmock-${terraform.workspace}"
  retention_in_days = terraform.workspace == "PROD" ? 90 : 3
}


data "template_file" "task_definition" {
  template = file("./task_defination/container_defination.tpl")

  vars = {
    CW_LOG_GROUP     = aws_cloudwatch_log_group.ecs_service_log_group.name
    WORKSPACE        = terraform.workspace
    CONTAINER_CPU    = var.task_defination.cpu
    CONTAINER_MEMORY = var.task_defination.memory
    CONTAINER_PORT   = var.task_defination.container_port
    IMAGE_URI        = var.image
  }
}

resource "aws_ecs_task_definition" "task_definition" {
  family                   = "jsonmock-${terraform.workspace}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_defination.cpu
  memory                   = var.task_defination.memory
  container_definitions    = data.template_file.task_definition.rendered
  execution_role_arn       = var.task_defination.execution_role_arn
}

resource "aws_security_group" "alb_sg" {
  name        = substr("jsonmock-alb-${terraform.workspace}-sg", 0, 30)
  description = "Allow inbound traffic"
  vpc_id      = var.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group_rule" "alb_sg_allow_port_80" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_sg.id
}


resource "aws_security_group_rule" "alb_sg_allow_port_443" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.alb_sg.id
}

resource "aws_lb" "jsonmock_alb" {
  name               = substr("jsonmock-${terraform.workspace}-alb", 0, 30)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = var.public_subnets

  enable_deletion_protection = terraform.workspace == "PROD" ? true : false
}

resource "aws_lb_listener" "jsonmock_alb_listner_80" {
  load_balancer_arn = aws_lb.jsonmock_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_security_group" "ecs_sg" {
  name        = substr("jsonmock-ecs-${terraform.workspace}-sg", 0, 30)
  description = "Allow inbound traffic from ALB"
  vpc_id      = var.vpc_id

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group_rule" "ecs_sg_allow_from_alb" {
  type                     = "ingress"
  from_port                = var.task_defination.container_port
  to_port                  = var.task_defination.container_port
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.alb_sg.id
  security_group_id        = aws_security_group.ecs_sg.id
}


resource "aws_alb_target_group" "ecs_service_target_group" {
  name = substr("jsonmock-${terraform.workspace}-ecs-tg", 0, 30)

  health_check {
    healthy_threshold   = "3"
    interval            = "30"
    protocol            = "HTTP"
    timeout             = "3"
    path                = "/api/movies"
    unhealthy_threshold = "2"
  }

  port        = var.task_defination.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  depends_on = [aws_lb.jsonmock_alb]
}

locals {
  dns  = terraform.workspace == "PROD" ? var.dns_name : "private.${var.dns_name}"
  fqdn = terraform.workspace == "PROD" ? "jsonmock.${local.dns}" : "jsonmock-${terraform.workspace}.${local.dns}"
}

data "aws_acm_certificate" "acm" {
  domain   = "*.${local.dns}"
  statuses = ["ISSUED"]
}


resource "aws_lb_listener" "jsonmock_alb_listner_443" {
  load_balancer_arn = aws_lb.jsonmock_alb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = data.aws_acm_certificate.acm.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_alb_target_group.ecs_service_target_group.id
  }
}


resource "aws_ecs_service" "jsonmock_service" {
  name                               = "jsonmock-${terraform.workspace}"
  cluster                            = aws_ecs_cluster.jsonmock_ecs_cluster.name
  task_definition                    = aws_ecs_task_definition.task_definition.id
  desired_count                      = terraform.workspace == "PROD" ? 2 : 1
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets         = var.private_subnets
    security_groups = [aws_security_group.ecs_sg.id]
  }

  load_balancer {
    target_group_arn = aws_alb_target_group.ecs_service_target_group.id
    container_name   = "HR-Jsonmock-${terraform.workspace}"
    container_port   = var.task_defination.container_port
  }

  capacity_provider_strategy {
    base              = 1
    capacity_provider = terraform.workspace == "PROD" ? "FARGATE" : "FARGATE_SPOT"
    weight            = 100
  }

  deployment_circuit_breaker {
    enable   = terraform.workspace == "PROD" ? true : false
    rollback = terraform.workspace == "PROD" ? true : false
  }

  deployment_controller {
    type = "ECS"
  }

  propagate_tags = "NONE"

  health_check_grace_period_seconds = 3

  tags = {
    Environment = "Test"
  }

}

data "aws_route53_zone" "dns" {
  name         = "${var.dns_name}."
  private_zone = false
}


resource "aws_route53_record" "jsonmock-CNAME" {
  depends_on = [aws_ecs_service.jsonmock_service]

  zone_id = data.aws_route53_zone.dns.zone_id
  name    = local.fqdn
  type    = "CNAME"
  records = [aws_lb.jsonmock_alb.dns_name]
  ttl     = "300"
}

output "dns_name" {
  value = aws_route53_record.jsonmock-CNAME.name
}
