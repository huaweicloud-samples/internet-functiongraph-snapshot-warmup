# ============================================================================
# Variables — FGS 进程级快照实践
# ============================================================================
# 输入参数：区域、项目前缀、OBS 桶、函数运行时参数、GeminiDB 规格与凭据。
#
# 默认值适用于 cn-north-4 / cn-north-1。通过 terraform.tfvars 或 -var 覆盖；
# 生产环境必须覆盖 `geminidb_password`。
# ============================================================================

variable "region" {
  description = "Huawei Cloud region"
  type        = string
  default     = "cn-north-4"
}

variable "project_name" {
  description = "Project prefix applied to every resource name"
  type        = string
  default     = "fgs-unicorn"
}

variable "function_code_bucket" {
  description = "OBS bucket hosting the FGS function jar (created by obs.tf)"
  type        = string
  default     = "fgs-unicorn-artifacts"
}

variable "function_code_object_key" {
  description = "Object key of the FGS function jar inside function_code_bucket"
  type        = string
  default     = "function-code/unicorn-stock-broker-1.0-fgs.jar"
}

variable "function_memory_size" {
  description = "FGS function memory (MB)"
  type        = number
  default     = 2048
}

variable "function_timeout" {
  description = "FGS function timeout (seconds)"
  type        = number
  default     = 200
}

variable "function_reserved_instance_count" {
  description = <<-EOT
    Number of warm reserved instances to keep online. Set to >0 to enable
    process-level snapshot acceleration — the first N instances are pre-warmed
    so the Java cold start (~5s+) is paid for once, not per request.
    0 = no reserved instances (cold-start mode).
  EOT
  type        = number
  default     = 1
}

variable "geminidb_password" {
  description = "GeminiDB (DynamoDB-compatible) password for the rwuser account"
  type        = string
  sensitive   = true
}

variable "geminidb_flavor" {
  description = <<-EOT
    spec_code of the GeminiDB DynamoDB-compatible instance flavor.

    IMPORTANT — DynamoDB-compatible instances run the DynamoDB API on TOP of the
    Cassandra compute engine, so their flavor codes are the Cassandra-family
    codes (geminidb.cassandra.*), NOT a "geminidb.dynamodb.*" family (which does
    not exist). The compatible interface is selected via datastore.type="DynamoDB"
    in geminidb.tf; the flavor code here selects the underlying compute.

    To list the codes available in your region, query the huaweicloud_geminidb_flavors
    data source with engine_name OMITTED — passing engine_name (even "DynamoDB" or
    "Cassandra") makes the API return "Invalid database type"; leaving it unset
    returns the cassandra-family codes, which are exactly what DynamoDB-compatible
    instances use. 起步规格通常为 geminidb.cassandra.large.4 (2 vCPU / 8 GB)；
    但 cn-north-4 在售 spec_code 须以 huaweicloud_geminidb_flavors 数据源
    （output: geminidb_available_flavors）本地 plan 实测列出的为准，再回填本变量。
  EOT
  type        = string
  default     = "geminidb.cassandra.large.4"

  validation {
    condition     = can(regex("^geminidb\\.cassandra\\.", var.geminidb_flavor))
    error_message = "geminidb_flavor must be a Cassandra-family code (geminidb.cassandra.*). DynamoDB-compatible GeminiDB instances reuse the Cassandra compute flavor family; there is no geminidb.dynamodb.* family."
  }
}

variable "domain_name" {
  description = "Huawei Cloud account domain (Agency delegated_domain_name)"
  type        = string
  default     = "your-huaweicloud-domain"
}

variable "table_name" {
  description = "GeminiDB DynamoDB-compatible table name (default: TransactionsTable)"
  type        = string
  default     = "TransactionsTable"
}