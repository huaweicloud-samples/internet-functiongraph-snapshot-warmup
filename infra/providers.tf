# ============================================================================
# 华为云实践：函数计算 + API 网关 + 多模 NoSQL 数据库
# 通过 Terraform + huaweicloud Provider 搭建典型无服务器架构
# ============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    huaweicloud = {
      source  = "huaweicloud/huaweicloud"
      version = "~> 1.70"
    }
  }

  backend "local" {
    # 生产环境建议改为 OBS 对象存储后端存放 state。
  }
}

provider "huaweicloud" {
  region = var.region
  # AK/SK 从环境变量读取，禁止硬编码：
  # export HW_ACCESS_KEY="<AK>"
  # export HW_SECRET_KEY="<SK>"
}
