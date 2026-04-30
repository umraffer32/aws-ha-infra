variable "project_name" {
  description = "Prefix for resource naming and tagging"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to deploy into"
  type        = string
}

variable "azs" {
  description = "Availability zones to deploy NAT instances into"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs, one per AZ"
  type        = list(string)
}

variable "ami_id" {
  description = "AMI ID for NAT instances"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type for NAT instances"
  type        = string
  default     = "t2.micro"
}

variable "iam_instance_profile" {
  description = "IAM instance profile name for SSM access"
  type        = string
  default     = "SSM-EC2"
}
