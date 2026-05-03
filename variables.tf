variable "region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "Local AWS CLI/SSO profile name used for authentication"
  type        = string
  default     = "mrpocket2726"
}

variable "project_name" {
  description = "Short name used as a prefix for tagging and resource naming"
  type        = string
  default     = "ha"
}

variable "debian_version" {
  description = "Major Debian version for NAT/app AMIs (e.g., 12, 13)"
  type        = string
  default     = "13"
}

variable "ubuntu_version" {
  description = "Ubuntu LTS version for AMI lookup (e.g., 22.04, 24.04)"
  type        = string
  default     = "24.04"
}

variable "db_name" {
  description = "Name of the initial PostgreSQL database"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for the PostgreSQL database"
  type        = string
  default     = "appuser"
}

variable "db_password" {
  description = "Master password for the PostgreSQL database (set in terraform.tfvars)"
  type        = string
  sensitive   = true
}
