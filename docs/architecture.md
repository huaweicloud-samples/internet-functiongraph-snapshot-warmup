# 架构说明 — FunctionGraph 进程级快照加速实践

## 1. 总览

本实践由 APIG + FunctionGraph + GeminiDB（DynamoDB 兼容）+ OBS + IAM Agency 五个核心组件构成。
Java 业务逻辑实现交易写入 API：客户端 HTTPS POST `/transactions`，FGS 函数
接收、校验后写入 GeminiDB DynamoDB 兼容表，返回写入结果。

```
┌────────┐    HTTPS POST /transactions    ┌──────────┐
│ Client │ ──────────────────────────────► │  APIG    │
└────────┘                                 └────┬─────┘
                                                │ func_graph backend
                                                ▼
                                       ┌────────────────┐
                                       │ FunctionGraph  │
                                       │  (Java11)      │
                                       │  2048MB/200s   │
                                       └──┬──────────┬──┘
                                          │          │
                  OBS code jar  ◄────────┤          ├────► GeminiDB
                  (function-code/)       │          │      DynamoDB 兼容
                                          │          │      (load-balancer
                                          │          │       :8000)
                                          ▼          ▼
                                  OBS 读取（agency）  GeminiDB 鉴权 =
                                                      实例数据库账号 rwuser
                                                      + 实例管理员密码
                                                      （user_data 注入）
```

> GeminiDB 的 DynamoDB 兼容**数据面**只认实例自带的数据库账号，
> 不接受 IAM 委托凭据，也不支持 securityToken，因此函数运行期
> `Context` 暴露的临时凭据不能用于数据库鉴权。

## 2. 组件清单

| 组件 | 用途 | 风险码 |
|------|------|--------|
| FunctionGraph（Java11, 2048MB, 200s） | 事务写入 API 的运行时 | 🟡 |
| APIG（专享版，BASIC edition） | HTTPS 接入 + 后端 Function 转发 | 🟢 |
| GeminiDB（DynamoDB 兼容，集群模式） | 事务表持久化；协议兼容 SDK 直接访问 | 🟢 |
| OBS（function-code 桶） | 仅做函数代码托管（详见 §4） | 🟢 |
| IAM Agency | 函数执行权限（从 OBS 拉取函数代码） | 🟢 |

## 3. 进程级快照加速（核心机制）

Java 函数冷启动时延通常在 1 分钟量级（JVM 启动 + 框架初始化 + 业务初始化）。
FunctionGraph 通过 `reserved_instances` block 在平台层预留 N 个常驻实例，
idle_mode=true 时 APIG 请求直接命中热实例，跳过 JVM 启动、框架初始化、业务初始化，
将冷启动时延压到亚秒级。

| 机制 | 描述 | 适用 |
|------|------|------|
| `reserved_instances` block（count=1+） | 预留 N 个常驻实例，idle_mode=true，APIG 请求直接命中热实例 | 7×24 流量场景 |
| 函数镜像预加载（`image_acceleration` / 函数预热） | 平台级预热 + 镜像缓存，缩短冷启动 | 偶发流量场景；通过 `huaweicloud_fgs_function_versions` block + 流量预测配置 |
| Java 进程级快照（CRaC 风格） | FGS 内部支持 SpringBoot/CRaC 风格的快照加速 | 跟随平台更新；当前不在 FGS 公共 API 暴露 |

**本仓库采用的策略**：在 Terraform 中暴露 `var.function_reserved_instance_count`，
默认 `1`（开启预热池）；设为 `0` 即关闭预热、回到冷启动模式。

> Java 业务逻辑、API 契约与数据库表结构完整实现；
> 冷启动时延一项通过平台侧的常驻实例池机制达成。

## 4. 函数代码桶的用途收敛

本实践**只保留 OBS 桶作为函数代码托管**，不另造空桶。理由：

1. handler 内不涉及校验文件读取——`BUCKET_NAME` 不会注入到 `TransactionRepository`；
2. `TransactionRepository` 仅写 GeminiDB，无 OBS 业务调用；
3. 凭空增加空桶没有业务价值。

## 5. 网络与安全

* 单 VPC / 单子网 / 单安全组（SG 默认放行 egress + 入向 443 from 0.0.0.0/0 + 入向 8000 from VPC CIDR 给 GeminiDB）；
* GeminiDB 不暴露公网；FGS 通过 VPC 内网访问其 lb_ip_address；
* APIG 自动获得公网入口（`ingress_address`），客户端走 HTTPS；
* IAM Agency 仅授予项目内 OBS OperateAccess（函数拉取代码），不扩散到 IAM 域权限；
  GeminiDB 数据面使用实例数据库账号鉴权，不经过 IAM。

## 6. Terraform 模块布局

```
infra/
├── providers.tf          # Provider + 后端（local）
├── variables.tf          # 输入变量
├── network.tf            # VPC + Subnet + SG
├── obs.tf                # 函数代码 OBS 桶
├── iam.tf                # FGS IAM Agency
├── geminidb.tf           # GeminiDB DynamoDB 兼容实例
├── functiongraph.tf      # FGS 函数（含 reserved_instances 动态块）
├── apig.tf               # APIG 实例 + 分组 + /transactions API
├── outputs.tf            # 关键 ID / URL
└── terraform.tfvars.example
```

每个 `.tf` 文件对应一个资源层，跨文件依赖通过资源引用完成；
不引入子模块、不引入 `for_each` 模板，保持扁平结构以便 code review。

## 7. Java 代码布局

```
src/functions/unicorn-stock-broker/
├── pom.xml               # Maven：FGS SDK + DynamoDB Java SDK + Jackson
├── build_and_upload.sh   # 打包 + 上传 OBS
└── src/main/java/com/unicorn/broker/
    ├── FunctionGraphHandler.java          # FGS 入口（handleRequest(Map, Context)）
    ├── core/UnicornStockBrokerHandler.java  # 业务处理（Map → Map）
    ├── core/TransactionService.java        # 100 ms 模拟 + brokerId 注入
    ├── data/TransactionRepository.java     # DynamoDB 客户端 → GeminiDB
    └── model/Transaction.java              # 数据模型
```

无 `application.java` 启动类——FGS 不是 Spring Boot Web 容器，handler
直接由 `FunctionGraphHandler::handleRequest` 反射调用。