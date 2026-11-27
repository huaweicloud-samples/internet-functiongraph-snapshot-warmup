# ============================================================================
# Terraform 入口 — FunctionGraph 进程级快照加速实践
# ============================================================================
# 本文件是模块入口，只承载跨层共享的公共定义；具体资源按下表分层拆分，
# 每个文件对应一个资源层，层间通过资源引用建立依赖：
#
#   providers.tf      Provider 版本约束与后端配置
#   variables.tf      输入变量
#   network.tf        VPC / 子网 / 安全组
#   obs.tf            函数代码托管桶与代码对象
#   iam.tf            函数执行委托（Agency）
#   geminidb.tf       GeminiDB（DynamoDB 兼容）实例
#   functiongraph.tf  FunctionGraph 函数（含 reserved_instances 预热池）
#   apig.tf           API 网关实例与分组
#   outputs.tf        关键 ID / URL 输出
#
# 不引入子模块、不引入 for_each 模板，保持扁平结构以便逐层 review。
# ============================================================================

locals {
  # 统一资源标签：可打标签的资源均从此处取值，避免项目名在各层重复书写。
  common_tags = {
    project = var.project_name
  }
}
