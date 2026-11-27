# ============================================================================
# Layer 3 — IAM Agency
# ============================================================================
# IAM Agency 是函数执行权限的载体：通过委托（delegated trust）让 FGS 函数从
# OBS 拉取 jar，jar / 源码内不存任何静态 AK/SK。
#
# 注意：这里不需要授予任何 GeminiDB 权限。GeminiDB 的 DynamoDB 兼容数据面只认
# 实例自带的数据库账号（rwuser + 实例管理员密码），不接受 IAM 委托凭据，
# 因此授予 GeminiDB 相关角色对该数据面写入并不生效。
#
# 该 Agency 在项目级声明；同时被热实例 / 冷启动两种模式复用。
# ============================================================================

resource "huaweicloud_identity_agency" "functiongraph" {
  name                  = "${var.project_name}-fgs-agency"
  description           = "Agency for ${var.project_name} FunctionGraph to read the function jar from OBS"
  duration              = "FOREVER"
  delegated_domain_name = var.domain_name

  project_role {
    project = var.region
    roles = [
      # FGS pulls the function jar from OBS via the function's code_url.
      # This is the only permission the function actually needs.
      "OBS OperateAccess",
      # FGS attaches the function's network interface to the project's VPC/subnet
      # when vpc_id + network_id are set on the function. Without this role,
      # attaching fails with FSS.1037 / VPC.2201 ("Policy doesn't allow
      # vpc:subnets:get to be performed"). VPC ReadOnlyAccess is sufficient
      # for the get; Administrator grants the broader vpc:* required by FGS
      # (vpc:subnets:get, vpc:vpcs:get, vpc:ports:*).
      "VPC Administrator",
    ]
  }
}