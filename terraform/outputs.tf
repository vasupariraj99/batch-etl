# terraform/outputs.tf
output "raw_bucket" {
  value       = aws_s3_bucket.raw.bucket
  description = "Raw S3 bucket name"
}

output "processed_bucket" {
  value       = aws_s3_bucket.processed.bucket
  description = "Processed S3 bucket name"
}

output "scripts_bucket" {
  value       = aws_s3_bucket.scripts.bucket
  description = "Scripts S3 bucket name"
}

output "crawler_name" {
  value       = aws_glue_crawler.raw.name
  description = "Glue crawler name"
}

output "glue_job_name" {
  value       = aws_glue_job.etl.name
  description = "Glue job name"
}

output "redshift_namespace" {
  value       = aws_redshiftserverless_namespace.ns.namespace_name
  description = "Redshift Serverless namespace name"
}

output "redshift_workgroup" {
  value       = aws_redshiftserverless_workgroup.wg.workgroup_name
  description = "Redshift Serverless workgroup name"
}

output "redshift_db" {
  value       = var.redshift_db_name
  description = "Redshift database name"
}

output "redshift_secret_arn" {
  value       = aws_secretsmanager_secret.redshift.arn
  description = "Secrets Manager secret ARN for Redshift credentials"
}

output "redshift_copy_role_arn" {
  value       = aws_iam_role.redshift_s3.arn
  description = "IAM Role ARN for Redshift COPY from S3"
}
