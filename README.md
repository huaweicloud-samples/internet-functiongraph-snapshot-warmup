# internet-functiongraph-snapshot-warmup / FunctionGraph 进程级快照加速 Java 冷启动最佳实践

[![terraform ≥ 1.5](https://img.shields.io/badge/terraform-%E2%89%A51.5-623CE4)](https://www.terraform.io)
[![provider huaweicloud ~> 1.70](https://img.shields.io/badge/huaweicloud_provider-%7E%3E1.70-FF6A00)](https://registry.terraform.io/providers/huaweicloud/huaweicloud)
[![Java 11](https://img.shields.io/badge/Java-11-007396)](https://www.java.com)
[![License: MIT No Attribution](https://img.shields.io/badge/License-MIT_No_Attribution-blue)](./LICENSE)

## 1. 简介 / Overview

### 简介

> 华为云 **FunctionGraph + APIG + GeminiDB（DynamoDB 兼容）** 最佳实践，
> 演示 Java 进程级快照加速冷启动（平台层 `reserved_instances` 常驻实例池机制）。

本仓库是一份独立的华为云最佳实践，演示 FunctionGraph 上 Java 函数
通过进程级快照机制消除冷启动。实现核心业务逻辑（事务写入 API + 100 ms 模拟
+ 单实例 brokerId 注入），用 Terraform + huaweicloud Provider 搭建华为云原生架构。

**业务场景**：API 客户端通过 HTTPS POST `/transactions` 提交一笔股票事务，FGS 函数接收、
校验后写入 GeminiDB DynamoDB 兼容表，返回写入结果。

**核心机制**：FunctionGraph `reserved_instances` block（平台层常驻实例池），
跳过 JVM 启动、框架初始化、业务初始化，消除 Java 冷启动时延。

---

## 2. 目录

- [1. 简介 / Overview](#1-简介--overview)
- [2. 目录](#2-目录)
- [3. 架构图](#3-架构图)
- [4. 方案亮点](#4-方案亮点)
- [5. 涉及云服务](#5-涉及云服务)
- [6. 前置条件](#6-前置条件)
- [7. 快速开始](#7-快速开始)
- [8. 分步部署](#8-分步部署)
- [9. 使用方法 / 验证](#9-使用方法--验证)
- [10. 清理资源](#10-清理资源)
- [11. 详细说明](#11-详细说明)
- [12. 依赖](#12-依赖)
- [13. FAQ / 故障排除](#13-faq--故障排除)
- [14. 贡献指南](#14-贡献指南)
- [15. 许可证](#15-许可证)
- [16. 联系方式 / 维护者](#16-联系方式--维护者)

---

## 3. 架构图

```
   ┌────────┐        HTTPS POST /transactions
   │ Client │───────────────────────────────────►  APIG（专享版 BASIC）
   └────────┘                                          │
                                                       │ func_graph backend
                                                       ▼
                                             ┌──────────────────────┐
                                             │    FunctionGraph     │
                                             │      Java 11         │
                                             │   2048 MB / 200 s    │
                                             │  reserved_instances  │
                                             └────┬───────────┬─────┘
                                                  │           │
                     OBS 拉取 jar（agency） ◄─────┘           │
                                                              ▼
                                            GeminiDB（DynamoDB 兼容）
                                            lb_ip_address:80
                                            鉴权 = rwuser + 实例管理员密码
                                            （由 user_data 注入环境变量）
```

完整架构说明与决策树见 [`docs/architecture.md`](./docs/architecture.md)。

---

## 4. 方案亮点

| 亮点 | 说明 |
|------|------|
| 消除 Java 冷启动 | `reserved_instances` block 在函数版本上预热 N 个常驻实例，请求直接命中热实例 |
| 双模式一键切换 | `function_reserved_instance_count`：`0` = 冷启动模式，`≥1` = 热实例模式 |
| 数据库协议兼容 | GeminiDB 兼容宽表协议，使用标准协议客户端对接 |
| 无凭据落盘 | 数据库凭据经 `user_data` 注入环境变量，jar 内不写入代码或配置文件任何密钥 |
| 全资源 IaC 管理 | VPC / OBS / IAM / GeminiDB / FGS / APIG 全部由 Terraform 管理，可审计可回滚 |

---

## 5. 涉及云服务

| 服务 | 用途 |
|------|------|
| FunctionGraph（FGS） | Java 11 函数运行时，承载事务写入逻辑 |
| API 网关（APIG 专享版） | 暴露 HTTPS POST `/transactions` 入口 |
| GeminiDB（DynamoDB 兼容） | 事务表存储，客户端协议兼容 |
| 对象存储服务（OBS） | 托管函数代码 jar |
| 统一身份认证（IAM） | Agency 委托授权，函数从 OBS 拉取代码 |
| 虚拟私有云（VPC） | 网络隔离 + 安全组放通 |

> 清理资源提示：本实践的所有资源均可通过 `terraform destroy` 一键回收（见第 10 章），
> 无需人工逐项在控制台删除。

---

## 6. 前置条件

| 工具 / 资源 | 说明 | 验证命令 |
|------------|------|---------|
| Terraform ≥ 1.5 | 推荐 1.9.x；本地用 v1.15.8 校验通过 | `terraform version` |
| huaweicloud Provider | 通过 `terraform init` 安装 | `terraform providers` |
| 华为云账号 | 已开通目标区域 + FunctionGraph + APIG（专享版）+ GeminiDB（DynamoDB 兼容）+ IAM + OBS 权限 | 控制台右上角区域下拉 |
| AK / SK | 仅在本机环境变量使用，**严禁写入 tfvars 或 README** | `echo $HW_ACCESS_KEY` |
| Java 11 + Maven 3.9+ | 构建 FunctionGraph 函数 jar | `mvn -version` |
| FunctionGraph Java 运行时 SDK | `fss-java-sdk` jar，需手动下载放到 `lib/`（见第 8 章） | `ls src/functions/unicorn-stock-broker/lib/fss-java-sdk.jar` |
| Python 3.9+ | 运行 OBS 上传脚本 | `python --version` |
| Huawei Cloud SDK for Python v3 | 上传 OBS 依赖 | `pip show huaweicloud-sdk-python-v3` |

---

## 7. 快速开始

> 详细版见 [`docs/deployment-guide.md`](./docs/deployment-guide.md)。

```bash
# 0) 一次性准备：FunctionGraph Java 运行时 SDK
#    该 SDK 不在 Maven Central 发布，需从 FunctionGraph SDK 下载页获取
#    fss-java-sdk，解压后放置为：
#      src/functions/unicorn-stock-broker/lib/fss-java-sdk.jar

# 1) 准备变量
cd infra/
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars：region / domain_name / geminidb_password / geminidb_flavor

# 2) 构建并上传函数 jar
cd ../src/functions/unicorn-stock-broker
mvn -B clean package
HW_ACCESS_KEY=... HW_SECRET_KEY=... \
  BUCKET=$(grep function_code_bucket ../../infra/terraform.tfvars | cut -d'"' -f2) \
  REGION=$(grep '^region' ../../infra/terraform.tfvars | cut -d'"' -f2) \
  ./build_and_upload.sh
# 最后一行输出 OBS object URL

# 3) 部署
cd ../../infra
export HW_ACCESS_KEY=...
export HW_SECRET_KEY=...
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out tfplan
terraform apply tfplan
```

---

## 8. 分步部署

1. **准备运行时 SDK**：下载 `fss-java-sdk`，放置为
   `src/functions/unicorn-stock-broker/lib/fss-java-sdk.jar`。
2. **准备变量**：复制 `terraform.tfvars.example` 为 `terraform.tfvars`，
   填写 `region`（如 `cn-north-4`）、`domain_name`（租户名）、
   `geminidb_password`（8–32 位，大小写字母、数字、特殊字符至少两种）、
   `geminidb_flavor`（目标 region 在售的 DynamoDB 兼容实例规格码，必填）。
3. **构建函数 jar**：在 `src/functions/unicorn-stock-broker/` 下执行
   `mvn -B clean package`，产物为 `target/unicorn-stock-broker-1.0-fgs.jar`。
4. **上传到 OBS**：`build_and_upload.sh` 自动创建/复用桶并上传（也可用 `_tools/obs_upload.py`）。
5. **初始化 Terraform**：`terraform init` 下载 huaweicloud Provider；
   离线环境需配置 `dev_overrides` 指向本地 provider 镜像。
6. **预览与部署**：`terraform plan -out tfplan` → `terraform apply tfplan`。
   部署完成后读取输出：`terraform output -raw obs_function_code_url`。

每一步的预期输出与验收点见 [`docs/deployment-guide.md`](./docs/deployment-guide.md) §3–§5。

---

## 9. 使用方法 / 验证

部署完成后：

```bash
# 事务入口（APIG 专享版公网地址）
APIG_URL="https://<apig-ingress-address>/transactions"

# 提交一笔事务
curl -X POST "$APIG_URL" \
  -H "Content-Type: application/json" \
  -d '{"stockId":"UNCN","quantity":3}'
# 期望：200 OK
# body: "Broker xxxxxxxx successfully created transaction <uuid>"
```

**逐步验证指引**（请按序执行并核对）：
1. 控制台：函数工作流 → 函数 → `fgs-unicorn-broker` → 概览；
   应显示运行时 Java11 / 内存 2048 MB / 超时 200 s。
2. 控制台：对象存储服务 → `fgs-unicorn-artifacts` 桶
   → function-code/ → `unicorn-stock-broker-1.0-fgs.jar`；
   应可见 jar 文件，大小与 mvn 产物一致。
3. 控制台：云数据库 GeminiDB → `fgs-unicorn-gdb` → 数据管理 → 表；
   应可见 `TransactionsTable`（HASH key=transactionId, 4 列）。
4. 控制台：函数工作流 → 函数 → `fgs-unicorn-broker` → 日志；
   应可见最近一次 "PutItem response metadata: 200"。
5. 上面 curl 命令的输出截屏（或函数工作流的在线调试调用结果）。

> 部署完成后请按本节步骤自行验证，确认业务功能可用，方可视为交付完成。

---

## 10. 清理资源

> **安全约束**：本实践 destroy **仅限本任务创建的资源**。
> 不允许销毁共享 NAT 网关、共享 VPC，
> 以及同 AKSK 下其他任务创建的实例。

```bash
cd infra/
terraform destroy
# 检查 destroy 清单逐项确认无共享资源被选中
```

---

## 11. 详细说明

### 11.1 项目结构

```
.
├── LICENSE                                      # MIT No Attribution
├── README.md                                    # 本文件
├── README.en.md                                 # 英文版
├── docs/
│   ├── architecture.md                          # 架构说明
│   └── deployment-guide.md                      # 详细部署步骤
├── infra/                                       # Terraform + huaweicloud Provider
│   ├── main.tf                                  # 模块入口与公共标签
│   ├── providers.tf
│   ├── variables.tf
│   ├── network.tf                               # VPC + Subnet + SG
│   ├── obs.tf                                   # 函数代码 OBS 桶
│   ├── iam.tf                                   # IAM Agency
│   ├── geminidb.tf                              # GeminiDB DynamoDB 兼容实例
│   ├── functiongraph.tf                         # FGS 函数（含 reserved_instances）
│   ├── apig.tf                                  # APIG 实例 + 分组
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── src/functions/unicorn-stock-broker/          # FGS Java 函数源码
│   ├── pom.xml
│   ├── README.md
│   ├── build_and_upload.sh
│   ├── lib/                                     # 运行时 SDK jar（需手动下载）
│   └── src/main/java/com/unicorn/broker/
│       ├── FunctionGraphHandler.java
│       ├── core/
│       │   ├── UnicornStockBrokerHandler.java
│       │   └── TransactionService.java
│       ├── data/
│       │   └── TransactionRepository.java
│       └── model/
│           └── Transaction.java
└── _tools/                                      # 通用工具脚本
    └── obs_upload.py                            # 上传 jar 到 OBS
```

### 11.2 组件实现一览

| 组件                         | 实现方式                           | 风险等级 |
|----------------------------|------------------------------------|--------|
| Java11 函数运行时            | FunctionGraph (Java11, 2048MB)     | 🟡     |
| 进程级快照（冷启动加速）       | reserved_instances block           | 🟡     |
| HTTPS POST `/transactions`  | APIG（专享版 BASIC）                | 🟢     |
| 事务表（按请求量弹性扩展）      | GeminiDB（DynamoDB 兼容，集群）      | 🟢     |
| 函数代码桶                  | OBS bucket（仅函数代码托管）         | 🟢     |
| 函数执行权限                | IAM Agency（OBS OperateAccess）     | 🟢     |
| Java 函数入口               | `com.huawei.services.runtime` SDK  | 🟡     |
| APIG proxy 事件对象         | 直接接 `Map<String,Object>`          | 🟡     |
| 异步协议客户端               | 同步协议客户端 (Apache HTTP)         | 🟢     |
| CRaC 资源 hook             | 由平台常驻实例池机制替代             | 🟢     |

### 11.3 进程级快照加速

本实践演示的进程级快照加速通过 FunctionGraph 的 `reserved_instances` block 实现。
平台在函数发布版本上预热 N 个常驻实例，请求路由直接命中热实例，跳过 JVM 启动、
框架初始化、业务初始化。

| Terraform 字段 | 含义 |
|---------------|------|
| `count` | 预留实例数（≥1 即开启预热池） |
| `idle_mode = true` | 无流量时实例不释放（布尔值，不是字符串） |
| `qualifier_name = "latest"` | 绑定最新版本 |
| `qualifier_type = "version"` | 按版本限定 |

**切换**：

```bash
# 关闭预热池（冷启动模式）
terraform apply -var 'function_reserved_instance_count=0'

# 开启预热池（热实例模式）
terraform apply -var 'function_reserved_instance_count=1'
```

### 11.4 参数调优

| 参数 | 默认 | 调整建议 |
|------|------|---------|
| `function_memory_size` | 2048 | 调小可降低资源占用，调大可降低冷启动时延 |
| `function_timeout` | 200 | 按业务峰值 ×1.5 设置 |
| `function_reserved_instance_count` | 1 | 高 QPS 设 2–5；偶发流量设 0 |
| `geminidb.flavor.size` | 100 GB | 按事务量 ×6 个月估算 |
| `geminidb_flavor` | 占位符（必填） | 取目标 region 在售的 DynamoDB 兼容规格码 |

> `geminidb_flavor` 默认值会触发变量校验失败，必须改为实际规格码。规格码属于
> 「GeminiDB 兼容 DynamoDB 接口」规格族；其它 GeminiDB 引擎（Cassandra、Mongo、
> Influx、Redis）的规格码虽形似但不属于同一族，套用会在 apply 阶段被服务端拒绝。

### 11.5 设计决策

要点：
1. **进程级快照加速**：方案 A. `reserved_instances`（🟡 完全可回滚）
2. **校验文件桶**：方案 B. 不保留（🟢 完全可回滚）
3. **Java handler 路径**：方案 A. 独立函数（🟡 完全可回滚）
4. **Terraform 模块拆分**：方案 A. 扁平（🟢 完全可回滚）

其中 **GeminiDB 数据面鉴权模型**、**规格码族**、**运行时 SDK 获取方式**
三项分别展开在 §11.2 组件实现一览、§11.4 参数调优与第 8 章分步部署。

---

## 12. 依赖

| 依赖 | 版本 / 说明 |
|------|------------|
| `huaweicloud/huaweicloud` Provider | ~> 1.70（本地 v1.97.1 校验通过） |
| FunctionGraph Java 运行时 SDK | `fss-java-sdk`（官方下载包，非 Maven Central 发布） |
| DynamoDB Java SDK v2 | 作为线协议客户端对接 GeminiDB 兼容端点（见 `src/functions/unicorn-stock-broker/README.md`） |
| Maven / maven-shade-plugin | 构建可执行 jar |
| Huawei Cloud SDK for Python v3 | `_tools/obs_upload.py` 依赖 |

---

## 13. FAQ / 故障排除

### FAQ


| 问题 | 回答 |
|------|------|
| `terraform apply` 报 `ELB.8907` | APIG 公网入口规格配置错；检查 `apig.tf` `request_protocol="HTTPS"` |
| APIG 返回 500 | FGS 函数未正确启动；FGS 控制台 → 函数 → 日志 → 看是否有 `HANDLER ENTRY` |
| GeminiDB 写入失败（`auth failed`） | 数据面只认实例数据库账号：检查 `GEMINIDB_USER=rwuser`、`GEMINIDB_PASSWORD` 与 `geminidb_password` 一致 |
| GeminiDB 连不通 | 安全组未放行 VPC→8000；控制台：GeminiDB → 实例 → 安全组 → 放通 8000 from 10.0.0.0/16 |
| `geminidb_flavor` 校验失败 | 仍为占位符；用 `huaweicloud_geminidb_flavors` 查询目标 region 的 DynamoDB 兼容 `spec_code` |
| `mvn package` 报找不到 `com.huawei.services.runtime.Context` | 未放置 `lib/fss-java-sdk.jar`；该 SDK 需从 FunctionGraph SDK 下载页手动下载 |
| `terraform validate` 报 `no package for 'huaweicloud/huaweicloud' cached` | 沙箱无法访问 registry；使用 `dev_overrides` 本地 schema |
| 两种模式如何切换 | `terraform apply -var 'function_reserved_instance_count=0\|1'`，随时可逆 |

---

## 14. 贡献指南

1. Fork 本仓库并创建特性分支。
2. 修改后运行 `terraform fmt -recursive` + `terraform validate` 保证 IaC 合规。
3. 新增/修改函数代码时执行 `mvn -B clean package` 确保可构建。
4. 提交 PR 时附上部署验证截图（见第 9 章逐步验证指引）。
5. 部署前请按第 9 章步骤完成功能自检。

---

## 15. 许可证

MIT No Attribution。Copyright Huawei Cloud.

---

## 16. 联系方式 / 维护者
| 项 | 内容 |
|---|---|
| **创建者** | [dgc-git](https://github.com/dgc-git) |
| **维护者** | [dgc-git](https://github.com/dgc-git) |
| **联系方式** | GitHub Issues / PR（见[第 14 节](#14-贡献指南)） |
