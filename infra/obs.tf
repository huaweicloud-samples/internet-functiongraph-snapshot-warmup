# ============================================================================
# Layer 2 — Storage: OBS bucket hosting the FGS function jar
# ============================================================================
# OBS 仅作为函数代码托管桶（详细决策见 docs/architecture.md §4）。
# ============================================================================

resource "huaweicloud_obs_bucket" "function_code" {
  bucket        = var.function_code_bucket
  acl           = "private"
  force_destroy = true
  versioning    = true

  tags = merge(local.common_tags, {
    purpose = "fgs-function-code"
  })
}

# Upload the prebuilt FGS jar so the function (code_type="obs") is runnable
# without a separate build_and_upload.sh step. The function's code_url points
# at this exact object key; the function cannot start unless it is present.
# Idempotent: if the object already exists with the same content, no change.
resource "huaweicloud_obs_bucket_object" "function_jar" {
  bucket = huaweicloud_obs_bucket.function_code.bucket
  key    = var.function_code_object_key
  source = "${path.module}/../src/functions/unicorn-stock-broker/target/unicorn-stock-broker-1.0-fgs.jar"
  # 9.0M fat jar; upload may take a moment on first apply.
}