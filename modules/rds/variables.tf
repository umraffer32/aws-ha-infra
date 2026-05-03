variable "project_name" {
  description = "Short name used as a prefix for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC to place the RDS instance in"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the DB subnet group (must span at least 2 AZs)"
  type        = list(string)
}

variable "private_security_group_id" {
  description = "Security group ID of the private instances — RDS will allow inbound from it"
  type        = string
}

variable "db_engine_version" {
  description = "PostgreSQL engine version"
  type        = string
  default     = "16"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Allocated storage in GiB"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the initial database"
  type        = string
}

variable "db_username" {
  description = "Master username for the database"
  type        = string
}

variable "db_password" {
  description = "Master password for the database"
  type        = string
  sensitive   = true
}
