data "aws_iam_policy_document" "glue_catalog_extra" {
  statement {
    sid    = "GlueCatalogAccess"
    effect = "Allow"
    actions = [
      "glue:GetCatalogImportStatus",
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:CreatePartition",
      "glue:BatchCreatePartition",
      "glue:CreateDatabase",
      "glue:UpdateDatabase"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "glue_catalog_extra" {
  name   = "batch-etl-glue-catalog-extra-${random_id.suffix.hex}"
  policy = data.aws_iam_policy_document.glue_catalog_extra.json
}

resource "aws_iam_role_policy_attachment" "glue_catalog_extra" {
  role       = aws_iam_role.glue.name
  policy_arn = aws_iam_policy.glue_catalog_extra.arn
}
