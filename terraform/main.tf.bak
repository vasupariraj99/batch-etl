# terraform/main.tf
provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  suffix  = random_id.suffix.hex
  project = var.project_prefix
  tags = {
    Project = local.project
    Stack   = "demo"
  }
}

# ---------------------------
# S3 Buckets (force_destroy for easy cleanup)
# ---------------------------
resource "aws_s3_bucket" "raw" {
  bucket        = "${local.project}-raw-${local.suffix}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket" "processed" {
  bucket        = "${local.project}-processed-${local.suffix}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket" "scripts" {
  bucket        = "${local.project}-scripts-${local.suffix}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "processed" {
  bucket                  = aws_s3_bucket.processed.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_public_access_block" "scripts" {
  bucket                  = aws_s3_bucket.scripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Upload the Glue script to S3
resource "aws_s3_object" "glue_script" {
  bucket = aws_s3_bucket.scripts.id
  key    = "scripts/glue_job.py"
  source = "${path.module}/../glue/scripts/glue_job.py"
  etag   = filemd5("${path.module}/../glue/scripts/glue_job.py")
}

# ---------------------------
# Glue Catalog + Crawler
# ---------------------------
resource "aws_glue_catalog_database" "raw_db" {
  name = "${replace(local.project, "-", "_")}_raw_db"
}

data "aws_iam_policy_document" "glue_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

# One role used by both Crawler and Job for simplicity
resource "aws_iam_role" "glue" {
  name               = "${local.project}-glue-role-${local.suffix}"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "glue_inline" {
  statement {
    sid     = "S3AccessRawProcessedScripts"
    effect  = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]
    resources = [
      aws_s3_bucket.raw.arn,
      aws_s3_bucket.processed.arn,
      aws_s3_bucket.scripts.arn
    ]
  }

  statement {
    sid     = "S3ObjectsAccess"
    effect  = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "${aws_s3_bucket.raw.arn}/*",
      "${aws_s3_bucket.processed.arn}/*",
      "${aws_s3_bucket.scripts.arn}/*"
    ]
  }

  statement {
    sid     = "LogsForGlue"
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "UseRedshiftDataAPI"
    effect  = "Allow"
    actions = [
      "redshift-data:ExecuteStatement",
      "redshift-data:DescribeStatement",
      "redshift-data:GetStatementResult",
      "redshift-data:CancelStatement"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ReadRedshiftSecret"
    effect  = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [aws_secretsmanager_secret.redshift.arn]
  }
}

resource "aws_iam_role_policy" "glue_inline" {
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue_inline.json
}

resource "aws_glue_crawler" "raw" {
  name          = "${local.project}-crawler-${local.suffix}"
  role          = aws_iam_role.glue.arn
  database_name = aws_glue_catalog_database.raw_db.name

  s3_target {
    path = "s3://${aws_s3_bucket.raw.bucket}/raw/"
  }

  configuration = jsonencode({
    Version       = 1.0
    CrawlerOutput = {
      Partitions = { AddOrUpdateBehavior = "InheritFromTable" }
    }
  })

  tags = local.tags
}

# ---------------------------
# Redshift Serverless
# ---------------------------
data "aws_iam_policy_document" "redshift_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["redshift.amazonaws.com"]
    }
  }
}

# Role used by Redshift COPY to read from processed bucket
resource "aws_iam_role" "redshift_s3" {
  name               = "${local.project}-redshift-s3-${local.suffix}"
  assume_role_policy = data.aws_iam_policy_document.redshift_assume.json
  tags               = local.tags
}

data "aws_iam_policy_document" "redshift_s3_access" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket"
    ]
    resources = [
      aws_s3_bucket.processed.arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject"
    ]
    resources = [
      "${aws_s3_bucket.processed.arn}/*"
    ]
  }
}

resource "aws_iam_role_policy" "redshift_s3_access" {
  role   = aws_iam_role.redshift_s3.id
  policy = data.aws_iam_policy_document.redshift_s3_access.json
}

resource "aws_redshiftserverless_namespace" "ns" {
  namespace_name      = "${local.project}-ns-${local.suffix}"
  admin_username      = var.redshift_admin_username
  admin_user_password = var.redshift_admin_password
  db_name             = var.redshift_db_name
  tags                = local.tags
}

resource "aws_redshiftserverless_workgroup" "wg" {
  workgroup_name      = "${local.project}-wg-${local.suffix}"
  namespace_name      = aws_redshiftserverless_namespace.ns.namespace_name
  base_capacity       = 8
  publicly_accessible = true
  tags                = local.tags
}

# ---------------------------
# Secrets Manager (Redshift creds for Data API)
# ---------------------------
resource "aws_secretsmanager_secret" "redshift" {
  name = "${local.project}-redshift-credentials-${local.suffix}"
  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "redshift" {
  secret_id     = aws_secretsmanager_secret.redshift.id
  secret_string = jsonencode({
    username = var.redshift_admin_username,
    password = var.redshift_admin_password
  })
}

# ---------------------------
# Glue Job (Glue 4.0, Python 3)
# ---------------------------
resource "aws_glue_job" "etl" {
  name     = "${local.project}-job-${local.suffix}"
  role_arn = aws_iam_role.glue.arn

  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"

  command {
    name            = "glueetl"
    script_location = "s3://${aws_s3_bucket.scripts.bucket}/${aws_s3_object.glue_script.key}"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"          = "python"
    "--enable-metrics"        = "true"
    "--raw_bucket"            = aws_s3_bucket.raw.bucket
    "--raw_prefix"            = "raw/"
    "--processed_bucket"      = aws_s3_bucket.processed.bucket
    "--processed_prefix"      = "processed/sales/"
    "--redshift_workgroup"    = aws_redshiftserverless_workgroup.wg.workgroup_name
    "--redshift_db"           = var.redshift_db_name
    "--redshift_secret_arn"   = aws_secretsmanager_secret.redshift.arn
    "--redshift_iam_role_arn" = aws_iam_role.redshift_s3.arn
    "--TempDir"               = "s3://${aws_s3_bucket.scripts.bucket}/temp/"
  }

  tags = local.tags

  depends_on = [
    aws_s3_object.glue_script
  ]
}
