data "aws_route53_zone" "primary" {
  name         = var.domain_name
  private_zone = false
}
