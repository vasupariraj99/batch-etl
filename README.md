Awesome—here’s a complete, copy-pasteable README.md you can drop in your repo. It’s written step-by-step so you can run the whole thing end-to-end and explain it confidently.

# README.md

# Serverless Batch ETL on AWS (Glue 4.0 + S3 + Glue Catalog + Redshift Serverless)

This project builds a tiny yet complete batch ETL pipeline:

- **Raw CSV** lands in **S3 (raw)**
- A **Glue Crawler** discovers schema into the **Glue Data Catalog**
- A **Glue ETL (Spark, Glue 4.0 / Python 3)** job reads CSV → casts types → adds `revenue` → writes **Parquet** to **S3 (processed)**
- The job then uses **Redshift Data API** to **create schema/table** and **COPY** Parquet from S3 → **Redshift Serverless**
- Finally, it runs **validation SQL** (row count, revenue sum, by day) and prints results

You deploy **infrastructure with Terraform only** (no AWS Console). Runtime and validation use **AWS CLI**.

---

## 0) Prerequisites (macOS / Linux)

- AWS account + IAM profile that can create S3, Glue, IAM roles/policies, Redshift Serverless, Secrets Manager
- **AWS CLI v2**
- **Terraform ≥ 1.5**
- `jq` (for pretty JSON), optional
- (Optional) Python 3.10+ if you want to preview the Parquet locally

Check versions:

```bash
aws --version
terraform version
jq --version || true


⸻

1) Clone this repo (or open your local folder)

cd "<your path>/batch-etl"

Make sure you see terraform/, glue/, and data/ folders.

⸻

2) Configure your shell (profile + region)

This project is designed to run with AWS profile ak-build in us-east-1.

export AWS_PROFILE=ak-build
export AWS_REGION=us-east-1

# sanity check identity
aws sts get-caller-identity


⸻

3) Set Redshift admin password (Terraform variable)

Terraform needs an admin password for the Redshift namespace.

export TF_VAR_redshift_admin_password='StrongPass123!'   # choose your own strong password

Other Terraform variables have safe defaults:
	•	project_prefix="batch-etl"
	•	region="us-east-1"
	•	aws_profile="ak-build"
	•	redshift_db_name="dev"
	•	redshift_admin_username="rs_admin"

(You can override any of these via env vars like TF_VAR_project_prefix.)

⸻

4) Deploy infrastructure with Terraform

terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve

On success you’ll get outputs like:
	•	raw_bucket / processed_bucket / scripts_bucket (globally unique)
	•	crawler_name (Glue crawler)
	•	glue_job_name
	•	redshift_namespace, redshift_workgroup, redshift_db
	•	redshift_secret_arn (Secrets Manager JSON credentials)
	•	redshift_copy_role_arn (IAM role used by Redshift COPY)

Save them to shell vars for convenience:

RB=$(terraform -chdir=terraform output -raw raw_bucket)
PB=$(terraform -chdir=terraform output -raw processed_bucket)
SB=$(terraform -chdir=terraform output -raw scripts_bucket)
CRAWLER=$(terraform -chdir=terraform output -raw crawler_name)
JOB=$(terraform -chdir=terraform output -raw glue_job_name)
NS=$(terraform -chdir=terraform output -raw redshift_namespace)
WG=$(terraform -chdir=terraform output -raw redshift_workgroup)
DB=$(terraform -chdir=terraform output -raw redshift_db)
SEC=$(terraform -chdir=terraform output -raw redshift_secret_arn)
COPY_ROLE=$(terraform -chdir=terraform output -raw redshift_copy_role_arn)


⸻

5) One-time Redshift permission nudge (safe + idempotent)

Some accounts need the Redshift namespace’s default IAM role set explicitly so COPY can read from S3. Run:

aws redshift-serverless update-namespace \
  --namespace-name "$NS" \
  --default-iam-role-arn "$COPY_ROLE" \
  --iam-roles "$COPY_ROLE"

(Optional) Wait for the namespace status to be AVAILABLE:

while true; do
  ST=$(aws redshift-serverless get-namespace --namespace-name "$NS" --query 'namespace.status' --output text)
  echo "Namespace status: $ST"
  [ "$ST" = "AVAILABLE" ] && break
  sleep 5
done


⸻

6) Upload sample CSV to S3 (raw)

A small demo dataset is in data/sales.csv.

aws s3 cp data/sales.csv "s3://$RB/raw/"
aws s3 ls "s3://$RB/raw/" --recursive


⸻

7) Run the Glue Crawler (discover schema)

Start and wait:

aws glue start-crawler --name "$CRAWLER"

echo "Waiting for crawler to finish..."
while true; do
  ST=$(aws glue get-crawler --name "$CRAWLER" --query 'Crawler.State' --output text)
  echo "Crawler state: $ST"
  [ "$ST" = "READY" ] && break
  sleep 10
done

# Optional: last crawl status/details
aws glue get-crawler --name "$CRAWLER" \
  --query 'Crawler.{State:State,LastCrawl:LastCrawl}'


⸻

8) Run the Glue ETL job (Spark → Parquet → COPY → validate)

Start:

RUN_ID=$(aws glue start-job-run --job-name "$JOB" --query 'JobRunId' --output text)
echo "Glue Job Run: $RUN_ID"

Wait for completion:

while true; do
  ST=$(aws glue get-job-run --job-name "$JOB" --run-id "$RUN_ID" \
       --query 'JobRun.JobRunState' --output text)
  echo "Job state: $ST"
  [ "$ST" = "SUCCEEDED" ] && break
  case "$ST" in FAILED|ERROR|STOPPED) echo "Job failed"; exit 1;; esac
  sleep 15
done

The job will:
	1.	Read CSV from s3://$RB/raw/
	2.	Cast columns, add revenue = quantity * unit_price
	3.	Write Parquet to s3://$PB/processed/sales/
	4.	Use Redshift Data API to:
	•	Create schema sales (if not exists)
	•	Create/replace table sales_fact
	•	COPY Parquet into Redshift using the IAM role from Terraform
	•	Run validation queries (count, sum revenue, by day)

⸻

9) Check S3 outputs (processed Parquet)

aws s3 ls "s3://$PB/processed/sales/" --recursive

Optional: pull a file locally (to peek inside later):

mkdir -p out
aws s3 cp "s3://$PB/processed/sales/" out/ --recursive


⸻

10) Query Redshift with the Data API

Define a tiny shell helper q (makes running SQL easy):

q() {
  local SQL="$1"
  local ID ST
  ID=$(aws redshift-data execute-statement \
        --workgroup-name "$WG" --database "$DB" --secret-arn "$SEC" \
        --sql "$SQL" --query 'Id' --output text)
  while true; do
    ST=$(aws redshift-data describe-statement --id "$ID" --query 'Status' --output text)
    [ "$ST" = "FINISHED" ] && break
    case "$ST" in FAILED|ABORTED) aws redshift-data describe-statement --id "$ID"; return 1;; esac
    sleep 1
  done
  aws redshift-data get-statement-result --id "$ID" --output table
}

Now run validations:

# total rows
q "select count(*) as row_count from sales.sales_fact;"

# total revenue (double check business logic)
q "select round(sum(revenue)::numeric,2) as total_revenue from sales.sales_fact;"

# sample rows
q "select * from sales.sales_fact order by order_timestamp limit 10;"

# by day
q "select order_date, count(*) as n, round(sum(revenue)::numeric,2) as revenue
   from sales.sales_fact group by 1 order by 1;"


⸻

11) (Optional) Compare CSV vs. Redshift for peace of mind

Quick compares (counts and revenue):

# CSV count
awk 'END{print NR-1}' data/sales.csv

# CSV total revenue (quantity * unit_price)
awk -F, 'NR>1 {sum += $4 * $5} END {printf "%.2f\n", sum}' data/sales.csv

# Redshift count
q "select count(*) from sales.sales_fact;"

# Redshift revenue
q "select round(sum(revenue)::numeric,2) from sales.sales_fact;"

Numbers should match.

⸻

12) (Optional) Generate a verification report file (handy for instructors)

This writes verification_report.txt with all the proof:

cat > verification_report.txt <<'TXT'
===== Terraform outputs =====
TXT
terraform -chdir=terraform output >> verification_report.txt

{
  echo
  echo "===== S3 raw bucket contents ====="
  aws s3 ls "s3://$RB/raw/" --recursive
  echo
  echo "===== S3 processed Parquet ====="
  aws s3 ls "s3://$PB/processed/sales/" --recursive
  echo
  echo "===== Glue Crawler status ====="
  aws glue get-crawler --name "$CRAWLER" --output table \
    --query 'Crawler.{Error:LastCrawl.ErrorMessage, LastStatus:LastCrawl.Status, Name:Name, State:State}'
  echo
  echo "===== Last Glue job run ====="
  aws glue get-job-runs --job-name "$JOB" --max-items 1 --output table \
    --query 'JobRuns[0].{RunId:Id, State:JobRunState, Error:ErrorMessage, StartedOn:StartedOn, CompletedOn:CompletedOn}'
  echo
  echo "===== Redshift: row count ====="
  q "select count(*) as row_count from sales.sales_fact;"
  echo
  echo "===== Redshift: total revenue ====="
  q "select sum(revenue) as total_revenue from sales.sales_fact;"
  echo
  echo "===== Redshift: sample rows ====="
  q "select * from sales.sales_fact order by order_timestamp limit 10;"
} >> verification_report.txt

Open it:

cat verification_report.txt


⸻

13) Rerun pipeline after changing data
	•	Upload a new CSV (same schema) to s3://$RB/raw/ (you can overwrite sales.csv)
	•	Rerun crawler (only needed if schema changes)
	•	Rerun Glue job
	•	Re-query Redshift

aws s3 cp data/sales.csv "s3://$RB/raw/"
aws glue start-crawler --name "$CRAWLER"
RUN_ID=$(aws glue start-job-run --job-name "$JOB" --query 'JobRunId' --output text)
# wait loop as before...


⸻

14) Troubleshooting cheatsheet

Crawler says AccessDeniedException on glue:GetDatabase:
Terraform attaches the right policies. If you recreated pieces manually, make sure the Glue role has:
	•	AWSGlueServiceRole managed policy
	•	Inline/attached policy allowing glue:GetDatabase, glue:GetTable, glue:CreateTable, etc. on your catalog/database

List attached policies:

GLUE_ROLE_NAME=$(terraform -chdir=terraform state show aws_iam_role.glue 2>/dev/null | awk '/^id[[:space:]]*=/{print $3}' | tr -d '"')
aws iam list-attached-role-policies --role-name "$GLUE_ROLE_NAME"

Crawler creation error “tags … in deleting state”:
AWS is still cleaning up a deleted crawler with the same name. Wait ~1–3 minutes and terraform apply again, or change the suffix (random_id) / project_prefix, or import the existing crawler to state.

Glue job fails “NoSuchBucket”:
Buckets are recreated (new names). Re-run terraform apply and re-upload:
	•	the job script is auto-uploaded by Terraform
	•	your CSV must be re-uploaded to the new raw_bucket

Redshift COPY permission error:
Run section 5) to set namespace default IAM role to the provided redshift_copy_role_arn.

Region/profile mismatches:
Every AWS CLI command here uses AWS_PROFILE=ak-build, region us-east-1. Keep these consistent.

Zsh “suspended jobs” noise:
You hit Ctrl+Z earlier. Clean them up:

jobs -p | xargs -I{} kill -9 {} 2>/dev/null || true


⸻

15) Clean up (to avoid charges)
	1.	Empty the S3 buckets (raw, processed, scripts):

aws s3 rm "s3://$RB" --recursive
aws s3 rm "s3://$PB" --recursive
aws s3 rm "s3://$SB" --recursive

	2.	Destroy with Terraform:

terraform -chdir=terraform destroy -auto-approve


⸻

16) What to show your instructor (acceptance mapping)

Proof	How to show it
Infra created by Terraform only	terraform -chdir=terraform apply output; terraform output values
Raw S3 contains CSV	aws s3 ls "s3://$RB/raw/" --recursive
Crawler ran and cataloged	aws glue get-crawler --name "$CRAWLER" --output table (LastStatus=SUCCEEDED)
ETL wrote Parquet	aws s3 ls "s3://$PB/processed/sales/" --recursive
Redshift has data	q "select count(*) from sales.sales_fact;" and sample rows
Validation (business logic)	q "select round(sum(revenue)::numeric,2) from sales.sales_fact;" + q "select order_date, count(*), round(sum(revenue)::numeric,2) from sales.sales_fact group by 1 order by 1;"
End-to-end artifact	Show verification_report.txt


⸻

17) Push to GitHub (safe)

# create .gitignore (if not present)
cat > .gitignore <<'EOF'
.DS_Store
__pycache__/
*.pyc
.venv/
.env
.terraform/
terraform.tfstate
terraform.tfstate.*
crash.log
out/
*.log
EOF

git init -b main
git add .
git status --porcelain | grep tfstate || echo "No tfstate files staged 👍"
git commit -m "Initial commit: Serverless batch ETL"
# Either:
# gh repo create batch-etl --private --source=. --remote=origin --push
# Or:
git remote add origin https://github.com/<you>/batch-etl.git
git push -u origin main


⸻

18) Architecture (quick ASCII)

S3 (raw CSV)
   │
   └── Glue Crawler ──> Glue Data Catalog (table)
                           │
                           └─ Glue ETL (Spark, Glue 4.0, Python 3)
                                ├─ reads CSV from S3 raw
                                ├─ casts, adds revenue
                                ├─ writes Parquet to S3 processed
                                └─ calls Redshift Data API:
                                      - create schema/table
                                      - COPY Parquet → Redshift (IAM role)
                                      - run validation SQL

