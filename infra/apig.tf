# ============================================================================
# Layer 6 — APIG（API 网关）与 FGS 的对接
# ============================================================================
# APIG 专享版通过 instance + group + custom API 三层资源暴露 FunctionGraph 后端：
#   huaweicloud_apig_instance（实例） → huaweicloud_apig_group（分组） → huaweicloud_apig_api（API 定义）
# 环境上线由 API 创建请求隐式完成。
# ============================================================================

resource "huaweicloud_apig_instance" "main" {
  name              = "${var.project_name}-apig"
  edition           = "BASIC"
  vpc_id            = huaweicloud_vpc.main.id
  subnet_id         = huaweicloud_vpc_subnet.main.id
  security_group_id = huaweicloud_networking_secgroup.main.id

  # APIG 专享版要求显式声明可用区列表（BASIC 单 AZ 即可）。
  availability_zones = [data.huaweicloud_availability_zones.current.names[0]]

  maintain_begin = "02:00:00"

  tags = local.common_tags
}

resource "huaweicloud_apig_group" "main" {
  name        = "${var.project_name}-api-group"
  instance_id = huaweicloud_apig_instance.main.id
  description = "API group for ${var.project_name} (transactions broker)"
}

# NOTE: huaweicloud_apig_api.create_transaction is intentionally NOT managed here.
# The huaweicloud provider rejects any in-place change to the APIG API's
# `func_graph` block ("func_graph can't be updated"), and even `terraform`
# `-replace` cannot bypass it because the provider throws during plan validation.
# Combined with a stale `network_type=V1` drift in state, this blocks EVERY
# `terraform plan`/`apply` for the whole stack. The live API (id
# 29315aecd4d04f1eb91d6079be13ec5a) is healthy on cloud; it was removed from
# state (`terraform state rm`) and from this config so the rest of the stack
# (FGS + GeminiDB + agency) can be managed. To fully re-manage it, delete the
# cloud API first, then restore this block and `terraform apply`.
