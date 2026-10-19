output "zone_id" {
  description = "The Route 53 public hosted zone ID."
  value       = data.aws_route53_zone.primary.zone_id
}

output "zone_name" {
  description = "The Route 53 public hosted zone name."
  value       = data.aws_route53_zone.primary.name
}

output "name_servers" {
  description = "The name servers assigned to the hosted zone."
  value       = data.aws_route53_zone.primary.name_servers
}
