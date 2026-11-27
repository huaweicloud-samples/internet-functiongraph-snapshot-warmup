# ============================================================================
# Layer 4 — Data: GeminiDB DynamoDB-compatible instance
# ============================================================================
# GeminiDB DynamoDB 兼容实例：对外暴露 DynamoDB 协议的 lb_ip_address 端点。
# 数据节点端口固定为 8000；负载均衡 VIP 将客户端流量转发到数据节点，
# 因此客户端应连接 LB VIP 的 80 端口（高可用端口），而不是 8000。
# 连接 VIP:8000 会 TCP 超时。
# 表在首次写入时自动创建。
#
# spec_code 取目标 region 的 Cassandra 规格族（geminidb.cassandra.*）——
# DynamoDB 兼容接口运行在 Cassandra 算力引擎之上，所以兼容实例复用的就是
# cassandra 规格族，不存在独立的 geminidb.dynamodb.* 规格族。
# 用 huaweicloud_geminidb_flavors 数据源、且不传 engine_name 即可列出（传
# engine_name 会被服务端判为 "Invalid database type"）。可用 spec_code 以
# huaweicloud_geminidb_flavors 数据源（output: geminidb_available_flavors）为准，
# 在 cn-north-4 本地 plan 时实测列出，起步规格通常为 geminidb.cassandra.large.4。
# ============================================================================

# 规格发现：列出目标 region 当前在售的 GeminiDB Cassandra 规格族（DynamoDB 兼容
# 实例复用该族）。不传 engine_name 才能列出（传 engine_name 服务端报
# "Invalid database type"）。本地 `terraform plan` 后由 output geminidb_available_flavors
# 透出，据此回填 terraform.tfvars 的 geminidb_flavor。
data "huaweicloud_geminidb_flavors" "available" {}

resource "huaweicloud_geminidb_instance" "main" {
  name     = "${var.project_name}-gdb"
  mode     = "Cluster"
  password = var.geminidb_password
  # Single-AZ cluster — GeminiDB's DynamoDB-compatible engine is replicated
  # internally; for cross-AZ resilience use multiple huaweicloud_geminidb_instance
  # resources rather than a multi-AZ list here.
  # Single-AZ cluster — GeminiDB's DynamoDB-compatible engine is replicated
  # internally; for cross-AZ resilience use multiple huaweicloud_geminidb_instance
  # resources rather than a multi-AZ list here.
  # NOTE: 账户对 cn-north-1 无访问权限（APIGW.0802 forbidden），故回落到
  # cn-north-4（账户主 region，GeminiDB 库存已恢复）。实测 cn-north-4 在售：
  #   - geminidb.cassandra.large.4  / 2xlarge.4 ：单 AZ cn-north-4a = normal（有货）
  #   - geminidb.cassandra.xlarge.4           ：单 AZ unsupported，仅 3-AZ 组合
  #     "cn-north-4a,cn-north-4b,cn-north-4c" = normal
  # 为最小在售 + 单 AZ 最稳，本实践采用 large.4 @ cn-north-4a；需更大容量可改
  # 2xlarge.4（单 AZ 4a 有货）或 xlarge.4（三 AZ 组合）。
  availability_zone = "cn-north-4a"
  vpc_id            = huaweicloud_vpc.main.id
  subnet_id         = huaweicloud_vpc_subnet.main.id
  security_group_id = huaweicloud_networking_secgroup.main.id

  # DynamoDB 兼容接口：type 必须是小写 "dynamodb"（大写 "DynamoDB" 会被服务端以
  # DBS.280235 Invalid database type 拒绝）。version 必须是空字符串 ""（填任何版本号
  # 都会被 DBS.280236 Invalid database version 拒绝）。storage_engine 沿用 rocksDB
  # （与 Cassandra 同算力底座）。
  datastore {
    type           = "dynamodb"
    storage_engine = "rocksDB"
    version        = ""
  }

  flavor {
    num       = 3
    size      = 100
    spec_code = var.geminidb_flavor
    storage   = "ULTRAHIGH"
  }

  tags = local.common_tags
}