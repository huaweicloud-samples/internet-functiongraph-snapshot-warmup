# ============================================================================
# Layer 5 — FunctionGraph (the FGS function itself)
# ============================================================================
# 可选 `reserved_instances` block 在平台层预热 N 个常驻实例，跳过 JVM 启动、
# 框架初始化、业务初始化：
#   - count > 0: 预热池模式，前 N 次调用零冷启动时延
#   - count = 0: 标准 FunctionGraph（每次冷启动走完整 JVM 启动）
#
# 通过 `var.function_reserved_instance_count` 切换；默认 1（开启预热池）。
# ============================================================================

resource "huaweicloud_fgs_function" "broker" {
  name        = "${var.project_name}-broker"
  # FGS `app` (package/group name) must match ^[a-zA-Z0-9_]{1,64}$ — NO hyphens.
  # The function name `fgs-unicorn-broker` contains a hyphen, and when `app` is
  # left unset the API derives the package from the name (split on "-"), yielding
  # the invalid "fgs-unicorn" (FSS.1027). Pin an explicit underscore app to avoid it.
  app         = "fgs_unicorn"
  agency      = huaweicloud_identity_agency.functiongraph.name
  # FunctionGraph Java handler format is `[package].[class].[method]` separated
  # by DOTS (e.g. `com.example.MyClass.myMethod`). The `::` form
  # `com.example.MyClass::myMethod` is rejected by FGS as
  # FSS.1003 "Invalid function handler".
  handler     = "com.unicorn.broker.FunctionGraphHandler.handleRequest"
  memory_size = var.function_memory_size
  timeout     = var.function_timeout
  runtime     = "Java11"

  # Pin the function into the same VPC/subnet as GeminiDB.
  # Huawei Cloud documentation requires the client (FunctionGraph here) and the
  # GeminiDB instance to be in the same VPC and the same subnet for intra-VPC
  # access to the DynamoDB-compatible LB VIP. Cross-subnet placement was tested
  # and resulted in the same ~23s TCP connect timeout.
  vpc_id     = huaweicloud_vpc.main.id
  network_id = huaweicloud_vpc_subnet.main.id

  description = "Unicorn Stock Broker — Java 11 transaction-write API on FunctionGraph"

  # Function code lives in OBS; the jar is uploaded by huaweicloud_obs_bucket_object.function_jar
  # (added so apply is self-contained — no separate build_and_upload.sh step needed).
  code_type = "obs"
  code_url  = "https://${huaweicloud_obs_bucket.function_code.bucket_domain_name}/${var.function_code_object_key}"

  # Ensure the jar object exists in the bucket before the function is created.
  depends_on = [huaweicloud_obs_bucket_object.function_jar]

  # GeminiDB's DynamoDB-compatible data plane authenticates with the INSTANCE
  # DATABASE ACCOUNT (the fixed administrator "rwuser" + the instance
  # administrator password). It does not accept Huawei Cloud IAM AK/SK and does
  # not support a security token, so the temporary credentials carried by the
  # function's IAM agency must NOT be used here. Both values are injected as
  # environment variables; the jar itself still contains no secrets.
  user_data = jsonencode({
    TABLE_NAME        = var.table_name
    # Resolved dynamically from the live GeminiDB instance so a recreate (new VIP)
    # is picked up automatically — no manual VIP swap needed after `terraform apply`.
    # NOTE: the load-balancer VIP for the DynamoDB-compatible data plane listens on
    # port 80, while the individual data nodes listen on port 8000. Clients must
    # connect to the LB VIP on port 80; connecting to the VIP on port 8000 times out.
    GEMINIDB_ENDPOINT = "http://${huaweicloud_geminidb_instance.main.lb_ip_address}:80"  # GeminiDB DynamoDB-compatible LB VIP
    # The DynamoDB Java SDK v2 uses this only for SigV4 signing against the
    # DynamoDB-compatible data plane. Huawei Cloud GeminiDB examples use
    # "cn-north-1" for the signing region regardless of the actual cloud region.
    REGION            = "cn-north-1"
    GEMINIDB_USER     = "rwuser"
    GEMINIDB_PASSWORD = var.geminidb_password
  })

  # Reserved instances block — only emitted when count > 0.
  # Terraform's `dynamic` + a boolean var gives us the with/without toggle.
  dynamic "reserved_instances" {
    for_each = var.function_reserved_instance_count > 0 ? [1] : []
    content {
      count = var.function_reserved_instance_count
      # idle_mode is a BOOL in the provider schema ("whether to enable the idle
      # mode"), not the string "on"/"off". Passing a string fails at apply even
      # though `terraform validate` does not flag it inside a dynamic block.
      idle_mode      = true
      qualifier_name = "latest"
      qualifier_type = "version"
    }
  }

  tags = local.common_tags
}