variable "project_name" {
  description = "Prefix used for resource naming and tagging"
  type        = string
}

variable "nat_asg_to_private_route_table" {
  description = "Map of NAT ASG name to the private route table ID that should default-route through that NAT"
  type        = map(string)
}

variable "destination_cidr_block" {
  description = "Destination CIDR block to repair in private route tables"
  type        = string
  default     = "0.0.0.0/0"
}
