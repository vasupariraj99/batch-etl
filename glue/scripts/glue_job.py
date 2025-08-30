import sys, os, json, time
import boto3
from datetime import datetime
from pyspark.sql import SparkSession, functions as F, types as T
from awsglue.context import GlueContext
from awsglue.utils import getResolvedOptions

# --------- robust arg parsing (handles --raw_bucket AND --RAW_BUCKET) ----------
def parse_kv(argv):
    d={}
    i=0
    while i < len(argv):
        a=argv[i]
        if a.startswith("--"):
            k=a[2:]
            v="true"
            if i+1 < len(argv) and not argv[i+1].startswith("--"):
                v=argv[i+1]
                i+=1
            d[k]=v
        i+=1
    return d

argv_map = parse_kv(sys.argv)

def pick(*candidates, default=None):
    for c in candidates:
        if c in argv_map: 
            return argv_map[c]
        if c.lower() in argv_map:
            return argv_map[c.lower()]
        if c.upper() in argv_map:
            return argv_map[c.upper()]
    return default

# Required-ish inputs with safe fallbacks
raw_bucket          = pick("raw_bucket", "RAW_BUCKET")
raw_prefix          = pick("raw_prefix", "RAW_PREFIX", default="raw/")
processed_bucket    = pick("processed_bucket", "PROCESSED_BUCKET")
processed_prefix    = pick("processed_prefix", "PROCESSED_PREFIX", default="processed/sales/")
redshift_workgroup  = pick("redshift_workgroup", "REDSHIFT_WORKGROUP")
redshift_db         = pick("redshift_db", "REDSHIFT_DB", default="dev")
redshift_secret_arn = pick("redshift_secret_arn", "REDSHIFT_SECRET_ARN")
redshift_iam_role   = pick("redshift_iam_role_arn", "REDSHIFT_IAM_ROLE_ARN")
temp_dir            = pick("TempDir", "TEMP_DIR", default=None)

missing = [k for k,v in {
    "raw_bucket":raw_bucket,
    "processed_bucket":processed_bucket,
    "redshift_workgroup":redshift_workgroup,
    "redshift_secret_arn":redshift_secret_arn,
    "redshift_iam_role_arn":redshift_iam_role
}.items() if not v]
if missing:
    print("FATAL: Missing required job args:", missing, file=sys.stderr)
    sys.exit(2)

# Normalize prefixes
def norm(p):
    p = (p or "").lstrip("/")
    if p and not p.endswith("/"): p += "/"
    return p

raw_prefix       = norm(raw_prefix)
processed_prefix = norm(processed_prefix)

raw_path       = f"s3://{raw_bucket}/{raw_prefix}"
processed_path = f"s3://{processed_bucket}/{processed_prefix}"

print(json.dumps({
    "resolved_args": {
        "raw_bucket": raw_bucket,
        "raw_prefix": raw_prefix,
        "processed_bucket": processed_bucket,
        "processed_prefix": processed_prefix,
        "redshift_workgroup": redshift_workgroup,
        "redshift_db": redshift_db,
        "redshift_secret_arn": redshift_secret_arn,
        "redshift_iam_role_arn": redshift_iam_role,
        "temp_dir": temp_dir
    },
    "paths": {
        "raw_path": raw_path,
        "processed_path": processed_path
    }
}, indent=2))

# --------- Spark / Glue setup ----------
spark = SparkSession.builder.getOrCreate()
glueContext = GlueContext(spark.sparkContext)

# If TempDir provided, surface it for Glue dynamic frames / writers
if temp_dir:
    spark.conf.set("spark.hadoop.mapreduce.fileoutputcommitter.marksuccessfuljobs","false")

# --------- Read CSV from RAW S3 ----------
schema = T.StructType([
    T.StructField("order_id", T.StringType(), True),
    T.StructField("customer_id", T.StringType(), True),
    T.StructField("product_id", T.StringType(), True),
    T.StructField("quantity", T.IntegerType(), True),
    T.StructField("unit_price", T.DoubleType(), True),
    T.StructField("order_timestamp", T.TimestampType(), True),
])

# Support both a single file sales.csv and many files
input_glob = raw_path + "*.csv"
df = (spark.read
      .option("header", True)
      .schema(schema)
      .csv(input_glob))

# Derive
df = (df
      .withColumn("revenue", F.col("quantity") * F.col("unit_price"))
      .withColumn("order_date", F.to_date(F.col("order_timestamp"))))

# --------- Write Parquet to PROCESSED ----------
(df
 .repartition(1)
 .write
 .mode("overwrite")
 .format("parquet")
 .save(processed_path))

print(f"Wrote Parquet to {processed_path}")

# --------- Load into Redshift via Data API + COPY (Parquet) ----------
redshift = boto3.client("redshift-data")
def exec_sql(sql):
    rid = redshift.execute_statement(
        WorkgroupName=redshift_workgroup,
        Database=redshift_db,
        SecretArn=redshift_secret_arn,
        Sql=sql
    )["Id"]
    while True:
        d = redshift.describe_statement(Id=rid)
        s = d["Status"]
        if s in ("FINISHED","FAILED","ABORTED"):
            if s != "FINISHED":
                print("SQL failed:", sql, "detail:", d, file=sys.stderr)
            return d
        time.sleep(1)

# Create schema/table
exec_sql("create schema if not exists sales;")
exec_sql("""
create table if not exists sales.sales_fact (
    order_id        varchar(64),
    customer_id     varchar(64),
    product_id      varchar(64),
    quantity        int,
    unit_price      double precision,
    order_timestamp timestamp,
    revenue         double precision,
    order_date      date
)
""")

# Truncate and copy fresh parquet
exec_sql("truncate table sales.sales_fact;")

copy_sql = f"""
copy sales.sales_fact
from '{processed_path}'
iam_role '{redshift_iam_role}'
format parquet;
"""
d = exec_sql(copy_sql)
if d["Status"] != "FINISHED":
    raise RuntimeError("COPY failed")

# --------- Simple validations ----------
cnt = exec_sql("select count(*) as c from sales.sales_fact;")
sumrev = exec_sql("select to_char(sum(revenue), 'FM999999990.00') as total_revenue from sales.sales_fact;")
byday = exec_sql("select order_date, count(*) as n, sum(revenue)::numeric(18,2) as revenue from sales.sales_fact group by 1 order by 1;")

def rows_to_list(get_stmt):
    res = redshift.get_statement_result(Id=get_stmt["Id"])
    cols = [c["name"] for c in res["ColumnMetadata"]]
    out=[]
    for r in res["Records"]:
        out.append({cols[i]: list(r[i].values())[0] if r[i] else None for i in range(len(cols))})
    return out

print(json.dumps({
    "validation": {
        "count": rows_to_list(cnt),
        "sum_revenue": rows_to_list(sumrev),
        "by_day": rows_to_list(byday)
    }
}, indent=2))
