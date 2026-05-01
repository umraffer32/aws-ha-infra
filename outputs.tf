output "vpc_id" {
  description = "ID of the VPC"
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "List of private subnet IDs"
  value       = module.network.private_subnet_ids
}

output "azs" {
  description = "Availability Zones used"
  value       = local.azs
}

output "nat_asg_names" {
  description = "NAT autoscaling group names, one per AZ"
  value       = module.compute.nat_asg_names
}

output "private_asg_names" {
  description = "Private autoscaling group names, one per AZ"
  value       = module.compute.private_asg_names
}

output "private_security_group_id" {
  description = "Security group ID used by private instances"
  value       = module.compute.private_security_group_id
}

output "nat_route_healer_lambda_name" {
  description = "Lambda function that auto-heals private default routes after NAT replacement"
  value       = module.nat_route_healer.lambda_name
}

output "nat_route_healer_event_rule_name" {
  description = "EventBridge rule name that triggers NAT route healing"
  value       = module.nat_route_healer.event_rule_name
}
