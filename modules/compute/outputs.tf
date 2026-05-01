output "nat_asg_names" {
  description = "NAT autoscaling group names, one per AZ"
  value       = [for asg in aws_autoscaling_group.nat : asg.name]
}

output "private_asg_names" {
  description = "Private autoscaling group names, one per AZ"
  value       = [for asg in aws_autoscaling_group.private : asg.name]
}

output "private_security_group_id" {
  description = "Security group ID used by private instances"
  value       = aws_security_group.private.id
}
