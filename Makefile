\
# Makefile
PROFILE ?= ak-build
REGION  ?= us-east-1
TFDIR   := terraform

.SILENT:

init:
	AWS_PROFILE=$(PROFILE) terraform -chdir=$(TFDIR) init

plan:
	AWS_PROFILE=$(PROFILE) terraform -chdir=$(TFDIR) plan

apply:
	@if [ -z "$$TF_VAR_redshift_admin_password" ]; then echo "Set TF_VAR_redshift_admin_password first"; exit 1; fi
	AWS_PROFILE=$(PROFILE) terraform -chdir=$(TFDIR) apply -auto-approve

upload-data:
	RAW=$$(terraform -chdir=$(TFDIR) output -raw raw_bucket); \
	echo "Uploading data/sales.csv to s3://$$RAW/raw/"; \
	aws s3 cp data/sales.csv s3://$$RAW/raw/ --profile $(PROFILE) --region $(REGION)

crawl:
	CRAWLER=$$(terraform -chdir=$(TFDIR) output -raw crawler_name); \
	echo "Starting crawler $$CRAWLER"; \
	aws glue start-crawler --name $$CRAWLER --profile $(PROFILE) --region $(REGION) >/dev/null; \
	echo "Waiting for crawler to be READY..."; \
	while true; do \
	  ST=$$(aws glue get-crawler --name $$CRAWLER --query 'Crawler.State' --output text --profile $(PROFILE) --region $(REGION)); \
	  echo "Crawler state: $$ST"; \
	  [ "$$ST" = "READY" ] && break; \
	  sleep 10; \
	done

start-job:
	JOB=$$(terraform -chdir=$(TFDIR) output -raw glue_job_name); \
	RUN=$$(aws glue start-job-run --job-name $$JOB --query 'JobRunId' --output text --profile $(PROFILE) --region $(REGION)); \
	echo $$RUN > .last_job_run_id; \
	echo "Started job $$JOB run $$RUN"

wait-job:
	JOB=$$(terraform -chdir=$(TFDIR) output -raw glue_job_name); \
	RUN=$$(cat .last_job_run_id 2>/dev/null || aws glue get-job-runs --job-name $$JOB --max-items 1 --query 'JobRuns[0].Id' --output text --profile $(PROFILE) --region $(REGION)); \
	echo "Waiting for job $$JOB run $$RUN..."; \
	while true; do \
	  ST=$$(aws glue get-job-run --job-name $$JOB --run-id $$RUN --query 'JobRun.JobRunState' --output text --profile $(PROFILE) --region $(REGION)); \
	  echo "State: $$ST"; \
	  [ "$$ST" = "SUCCEEDED" ] && break; \
	  case "$$ST" in FAILED|ERROR|STOPPED) echo "Job failed"; exit 1;; esac; \
	  sleep 15; \
	done

query:
	WG=$$(terraform -chdir=$(TFDIR) output -raw redshift_workgroup); \
	DB=$$(terraform -chdir=$(TFDIR) output -raw redshift_db); \
	SEC=$$(terraform -chdir=$(TFDIR) output -raw redshift_secret_arn); \
	echo "Executing COUNT(*) on sales.sales_fact"; \
	ID=$$(aws redshift-data execute-statement --workgroup-name $$WG --database $$DB --secret-arn $$SEC --sql "select count(*) as row_count from sales.sales_fact;" --query 'Id' --output text --profile $(PROFILE) --region $(REGION)); \
	echo "Statement Id: $$ID"; \
	while true; do \
	  ST=$$(aws redshift-data describe-statement --id $$ID --query 'Status' --output text --profile $(PROFILE) --region $(REGION)); \
	  echo "Status: $$ST"; \
	  [ "$$ST" = "FINISHED" ] && break; \
	  case "$$ST" in FAILED|ABORTED) echo "Query failed"; exit 1;; esac; \
	  sleep 2; \
	done; \
	aws redshift-data get-statement-result --id $$ID --profile $(PROFILE) --region $(REGION)

destroy:
	RAW=$$(terraform -chdir=$(TFDIR) output -raw raw_bucket 2>/dev/null || true); \
	PRC=$$(terraform -chdir=$(TFDIR) output -raw processed_bucket 2>/dev/null || true); \
	SCR=$$(terraform -chdir=$(TFDIR) output -raw scripts_bucket 2>/dev/null || true); \
	[ -n "$$RAW" ] && aws s3 rm s3://$$RAW --recursive --profile $(PROFILE) --region $(REGION) || true; \
	[ -n "$$PRC" ] && aws s3 rm s3://$$PRC --recursive --profile $(PROFILE) --region $(REGION) || true; \
	[ -n "$$SCR" ] && aws s3 rm s3://$$SCR --recursive --profile $(PROFILE) --region $(REGION) || true; \
	AWS_PROFILE=$(PROFILE) terraform -chdir=$(TFDIR) destroy -auto-approve
