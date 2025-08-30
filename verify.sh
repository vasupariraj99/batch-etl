#!/usr/bin/env bash
set -euo pipefail
export AWS_PROFILE=${AWS_PROFILE:-ak-build}
export AWS_REGION=${AWS_REGION:-us-east-1}

# Fetch outputs
WG=$(terraform -chdir=terraform output -raw redshift_workgroup)
DB=$(terraform -chdir=terraform output -raw redshift_db)
SEC=$(terraform -chdir=terraform output -raw redshift_secret_arn)
CRAWLER=$(terraform -chdir=terraform output -raw crawler_name)
RAW=$(terraform -chdir=terraform output -raw raw_bucket)
PROC=$(terraform -chdir=terraform output -raw processed_bucket)
JOB=$(terraform -chdir=terraform output -raw glue_job_name)

report=verification_report.txt
: > "$report"

hdr(){ echo -e "\n===== $* =====" | tee -a "$report"; }

hdr "Terraform outputs"
terraform -chdir=terraform output | tee -a "$report"

hdr "S3 raw bucket contents"
aws s3 ls "s3://$RAW/raw/" --recursive | tee -a "$report"

hdr "S3 processed Parquet"
aws s3 ls "s3://$PROC/processed/sales/" --recursive | tee -a "$report"

hdr "Glue Crawler status"
aws glue get-crawler --name "$CRAWLER" \
  --query 'Crawler.{Name:Name,State:State,LastStatus:LastCrawl.Status,Error:LastCrawl.ErrorMessage}' \
  --output table | tee -a "$report"

hdr "Last Glue job run"
aws glue get-job-runs --job-name "$JOB" \
  --query 'JobRuns[0].{RunId:Id,State:JobRunState,Error:ErrorMessage,StartedOn:StartedOn,CompletedOn:CompletedOn}' \
  --output table | tee -a "$report"

# Helper to run SQL and dump a compact table
rsql() {
  local SQL="$1"
  local ID ST
  ID=$(aws redshift-data execute-statement \
        --workgroup-name "$WG" --database "$DB" --secret-arn "$SEC" \
        --sql "$SQL" --query 'Id' --output text)
  while true; do
    ST=$(aws redshift-data describe-statement --id "$ID" --query 'Status' --output text)
    [ "$ST" = "FINISHED" ] && break
    [ "$ST" = "FAILED" -o "$ST" = "ABORTED" ] && aws redshift-data describe-statement --id "$ID" && return 1
    sleep 1
  done
  aws redshift-data get-statement-result --id "$ID" --output table | tee -a "$report"
}

hdr "Redshift: row count"
rsql "select count(*) as row_count from sales.sales_fact;"

hdr "Redshift: total revenue"
rsql "select round(sum(revenue),2) as total_revenue from sales.sales_fact;"

hdr "Redshift: sample rows"
rsql "select * from sales.sales_fact order by order_timestamp limit 10;"

echo -e "\nDone. See $report"
