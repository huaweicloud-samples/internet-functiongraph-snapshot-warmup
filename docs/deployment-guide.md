# 部署指南 — FunctionGraph 进程级快照加速实践

> 从零到部署完成的最短路径。**每一步均需先确认前置条件已满足**，
> 不要跳步——尤其是 `terraform.tfvars` 里的真实 AK/SK / 域名 / GeminiDB 密码
> （凭据绝不入仓）。

## 1. 前置条件

| 工具 / 资源 | 说明 | 验证 |
|------------|------|------|
| Terraform ≥ 1.5 | 推荐 1.9.x；本仓库本地用 v1.15.8 校验通过 | `terraform version` |
| huaweicloud provider | 已通过 `dev_overrides` 加载 v1.97.1（脱机校验）；生产请 `terraform init` | `terraform providers` |
| Huawei Cloud 账号 | 已开通 cn-north-4 + FunctionGraph + APIG + GeminiDB（DynamoDB 兼容） + IAM + OBS 权限 | 控制台右上角区域下拉 |
| AK/SK | 仅在本机环境变量使用，**严禁写入 tfvars 或 README** | `echo $HW_ACCESS_KEY \| wc -c` 应 > 0 |
| Java 11 + Maven 3.9+ | 构建 FunctionGraph jar | `mvn -version` |
| Python 3.9+ | 运行 `_tools/obs_upload.py` 上传 jar | `python --version` |
| Huawei Cloud SDK for Python v3 | 上传 OBS 依赖 | `pip show huaweicloud-sdk-python-v3` |
| FunctionGraph Java 运行时 SDK | `fss-java-sdk` jar，需手动下载（见 §3.1） | `ls lib/fss-java-sdk.jar` |

> 部署链路**不允许**走公网 NAT / EIP——本实践全部走 VPC 内网（APIG 入口除外）。

## 2. 配置 Terraform 变量

```bash
cd infra/
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars：
#   - region 改为目标 region（默认 cn-north-4）
#   - domain_name 改为真实账号域名（控制台右上角 → 我的凭证 → 账号名）
#   - geminidb_password 改为强密码（**不要**写入 VCS）
#   - geminidb_flavor 改为目标 region 在售的 DynamoDB 兼容实例规格码
#   - function_reserved_instance_count 改为 0 或 1（后者开启预热池）
```

> **geminidb_flavor 必填**：默认值是占位符，变量校验会直接失败。
> 规格码必须属于「GeminiDB 兼容 DynamoDB 接口」规格族——其它 GeminiDB 引擎
> （Cassandra、Mongo、Influx、Redis）的规格码虽形似但不属于同一族，会被服务端拒绝。
> 用 `huaweicloud_geminidb_flavors` 数据源查询目标 region 的 `spec_code`。

> **凭据检查**：执行 `git status` 确认 `terraform.tfvars` 不在 git 跟踪列表内；
> 如果之前误入了，用 `git rm --cached terraform.tfvars` 移除。

## 3. 构建 + 上传函数 jar

### 3.1 一次性准备：FunctionGraph Java 运行时 SDK

FunctionGraph 的 Java **运行时** SDK（提供 `com.huawei.services.runtime.Context`）
**不在 Maven Central 发布**，华为云只以可下载的 `fss-java-sdk` 软件包形式提供
（校验文件 `fss-java-sdk-*.sha256`）。

```bash
cd src/functions/unicorn-stock-broker
mkdir -p lib
# 从 FunctionGraph 的 SDK 下载页下载 fss-java-sdk，解压后放置为：
#   lib/fss-java-sdk.jar
```

该 jar 以 `system` scope 参与编译，**不会**被打进 shaded jar——FunctionGraph
运行时的 classpath 已自带这些类。

### 3.2 构建并上传

```bash
cd src/functions/unicorn-stock-broker
mvn -B clean package            # -> target/unicorn-stock-broker-1.0-fgs.jar

# 上传到 OBS（bucket 必须与 terraform.tfvars 中的 function_code_bucket 一致）
HW_ACCESS_KEY=... HW_SECRET_KEY=... \
  BUCKET=$(grep function_code_bucket ../infra/terraform.tfvars | cut -d'"' -f2) \
  REGION=$(grep '^region' ../infra/terraform.tfvars | cut -d'"' -f2) \
  ./build_and_upload.sh
# 打印最后一行：OBS object URL —— Terraform 通过 var.function_code_object_key 找到该对象
```

> 如果 `obs_upload.py` 提示 `huaweicloud-sdk-python-v3` 未装，执行
> `pip install huaweicloud-sdk-python-v3`（建议使用 venv，避免污染全局 Python 环境）。

## 4. Terraform plan + apply

```bash
cd infra

export HW_ACCESS_KEY=...
export HW_SECRET_KEY=...

terraform init                      # 联网情况下从 registry 下载 provider；脱机情况下用 dev_overrides（参考 docs/12）
terraform fmt -recursive            # 格式化
terraform validate                  # 静态校验
terraform plan -out tfplan          # 预览：列出将创建的资源与配置

# ==== 成本闸门 ====
# 资源规格与数量清单须在 apply 前逐项确认；
# 合计高于约定阈值时必须先经用户明确同意。

terraform apply tfplan              # 真正部署
```

## 5. 部署后必做（每一步都要看到具体状态）

> 以下操作必须**实际执行**，不能凭文档推断已成功。

### 5.1 验证 OBS jar 已就位
```bash
# 控制台路径：对象存储服务 → fgs-unicorn-artifacts → function-code/
# 应可见 unicorn-stock-broker-1.0-fgs.jar，大小与 mvn 产物一致
```

### 5.2 验证 FGS 函数已发布
```bash
# 控制台：函数工作流 → 函数 → fgs-unicorn-broker
# - 运行时 Java11
# - 内存 2048 MB
# - 超时 200 s
# - 执行入口 com.unicorn.broker.FunctionGraphHandler::handleRequest
# - 委托 fgs-unicorn-fgs-agency
# - 环境变量以下 5 个均非空：
#     TABLE_NAME / GEMINIDB_ENDPOINT / REGION / GEMINIDB_USER / GEMINIDB_PASSWORD
# - GEMINIDB_USER 的值应为 rwuser
```

### 5.3 验证业务调用可达

两个入口二选一，任选其一都必须**真实执行**并留存输出与截图：

```bash
# 入口 A：APIG 公网地址（需 APIG API 已纳管并上线）
APIG_URL="https://<apig-ingress-address>/transactions"

curl -X POST "$APIG_URL" \
  -H "Content-Type: application/json" \
  -d '{"stockId":"UNCN","quantity":3}'
# 期望：200 OK + body "Broker xxxxxxxx successfully created transaction <uuid>"

# 入口 B：函数工作流 → 函数 fgs-unicorn-broker → 在线调试，
#         测试事件填 {"stockId":"UNCN","quantity":3}，读取返回体与执行日志
```

### 5.4 验证 GeminiDB 表已创建
```bash
# 控制台：云数据库 GeminiDB → fgs-unicorn-gdb → 数据管理 → 表
# 应可见 TransactionsTable（由 SDK 自动建表）
# 关键 schema：
#   transactionId (S, HASH key)
#   stock          (S)
#   quantity       (N)
#   broker_id      (S)
```

### 5.5 验证日志
```bash
# 控制台：函数工作流 → 函数 → fgs-unicorn-broker → 日志
# 应看到 "PutItem response metadata: 200" 等请求日志
```

> 若写入返回鉴权失败（如 `AccessDeniedException: auth failed`），
> 优先检查 `GEMINIDB_USER` 是否为 `rwuser`、`GEMINIDB_PASSWORD` 是否与
> `geminidb_password` 一致——数据面只认实例数据库账号，不认 IAM 委托凭据。

## 6. 切换冷启动 / 热实例模式

```bash
# 冷启动模式（默认关闭预热池）
terraform apply -var 'function_reserved_instance_count=0'

# 热实例模式（保留 1 个热实例，跳过 JVM 启动）
terraform apply -var 'function_reserved_instance_count=1'
```

> **重新校验**：切换后 §5.3 的 curl 调用必须仍然返回 200；如果首次
> 调用出现 ~3s 延迟（冷启动），说明 reserved_instances 没生效——检查
> terraform plan 输出是否包含 `reserved_instances` block。

## 7. destroy（仅清自身资源）

> **安全约束**：本实践 destroy **仅限本任务创建的资源**。
> 不允许销毁：

* 任何 AKSK 下其他任务创建的实例（auto-damage、spf、safeguarding-payments-fraud-detection 等）
* 共享 NAT 网关 `devops-agent-5g-nat` (3631191e-9eae-4aea-aa46-1a9eac3e72f9)
* 共享 VPC `devops-agent-5g-vpc` (10.0.0.0/16)

```bash
terraform destroy
# 检查 destroy 清单逐项确认无上述共享资源
```
