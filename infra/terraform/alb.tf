# ── Application Load Balancer ────────────────────────────────────────────────
# One public entry point across both public subnets. Health checks take a
# failed instance out of rotation, so campaign links keep working.
resource "aws_lb_target_group" "app" {
  name        = "shortify-app"
  vpc_id      = aws_vpc.main.id
  protocol    = "HTTP"
  port        = var.app_port
  target_type = "instance"

  # A redirect takes milliseconds: 30 s drains in-flight requests. The 300 s
  # default would stall every blue/green deploy (Phase 3b) for five minutes.
  deregistration_delay = 30

  health_check {
    protocol            = "HTTP"
    port                = "traffic-port"
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 5 # a new instance proves itself for 2.5 min
    unhealthy_threshold = 2 # a failed one leaves rotation in about 60 s
  }

  tags = {
    Name = "shortify-app"
  }
}

resource "aws_lb" "main" {
  name               = "shortify-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.public_subnet_ids # both AZs

  # The only internet-facing component: malformed headers stop here.
  drop_invalid_header_fields = true

  tags = {
    Name = "shortify-alb"
  }
}

# HTTP only for now. HTTPS (ACM) and an 80 -> 443 redirect come later.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
