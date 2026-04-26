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
