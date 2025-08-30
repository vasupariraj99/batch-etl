# terraform/variables.tf
variable "project_prefix" {
  description = "Short name prefix for all resources"
  type        = string
  default     = "batch-etl"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "AWS named profile"
  type        = string
  default     = "ak-build"
}

variable "redshift_db_name" {
  description = "Default Redshift database name"
  type        = string
  default     = "dev"
}

variable "redshift_admin_username" {
  description = "Admin username for Redshift Namespace"
  type        = string
  default     = "rs_admin"
}

variable "redshift_admin_password" {
  description = "Admin password for Redshift Namespace"
  type        = string
  sensitive   = true
}
