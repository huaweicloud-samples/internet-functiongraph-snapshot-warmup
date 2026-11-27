# unicorn-stock-broker — FunctionGraph function

This module is the FunctionGraph Java 11 jar that backs the `/transactions` API.
It is invoked by FGS through the `com.huawei.services.runtime` Java runtime SDK.

## Layout

```
src/main/java/com/unicorn/broker/
├── FunctionGraphHandler.java        # FGS entry: handleRequest(Map, Context)
├── core/
│   ├── UnicornStockBrokerHandler.java
│   └── TransactionService.java
├── data/
│   └── TransactionRepository.java   # DynamoDB client -> GeminiDB
└── model/
    └── Transaction.java
```

## Build

### One-time prerequisite: the FunctionGraph runtime SDK

The FunctionGraph Java **runtime** SDK (which supplies
`com.huawei.services.runtime.Context`) is **not published to Maven Central**.
Huawei Cloud distributes it only as the downloadable `fss-java-sdk` package
(verification file `fss-java-sdk-*.sha256`).

1. Download `fss-java-sdk` from the FunctionGraph SDK download page.
2. Place the jar at `src/functions/unicorn-stock-broker/lib/fss-java-sdk.jar`.

`pom.xml` references it with `<scope>system</scope>` and
`<systemPath>${project.basedir}/lib/fss-java-sdk.jar</systemPath>`.

It is intentionally **not** bundled into the shaded jar: the FunctionGraph
runtime already provides these classes on the execution classpath.

### Build command

```bash
cd src/functions/unicorn-stock-broker
mvn -B clean package
# -> target/unicorn-stock-broker-1.0-fgs.jar
```

The shaded jar is uploaded to the OBS bucket declared in `infra/`
(variable `function_code_bucket`, object key default
`function-code/unicorn-stock-broker-1.0-fgs.jar`).

## Runtime contract

* **Handler** (configured in `huaweicloud_fgs_function.handler`):
  `com.unicorn.broker.FunctionGraphHandler::handleRequest`
* **Runtime**: `Java11`
* **Memory**: 2048 MB
* **Timeout**: 200 s
* **Agency**: required **only** so FGS can pull the jar from OBS
  (`huaweicloud_identity_agency.functiongraph` in `infra/`, role
  `OBS OperateAccess`). It is *not* used to authenticate against GeminiDB.
* **Environment variables** (injected via `user_data`):
  * `TABLE_NAME` — GeminiDB DynamoDB-compatible table name
  * `GEMINIDB_ENDPOINT` — `http://<lb_ip_address>:8000` of the
    `huaweicloud_geminidb_instance` (its load-balancer address; the
    data-plane port is fixed at 8000 and cannot be changed)
  * `REGION` — `var.region` (e.g. `cn-north-4`); used only for SigV4 signing
  * `GEMINIDB_USER` — the fixed instance database account `rwuser`
  * `GEMINIDB_PASSWORD` — the instance administrator password

## Key technical notes

* The handler returns `Map<String,Object>` rather than a typed response class —
  FunctionGraph serialises it directly to the APIG proxy response envelope
  (`{"statusCode":..., "headers":..., "body":...}`).

* **Credential model (important).** GeminiDB's DynamoDB-compatible **data
  plane** authenticates against the *instance's own database account*:
  `rwuser` plus the instance administrator password. It does **not** accept
  Huawei Cloud IAM AK/SK, and it does **not** support a security token.

  Therefore the function reads `GEMINIDB_USER` / `GEMINIDB_PASSWORD` from the
  environment and builds a static credentials provider from them. The temporary
  credentials exposed by the runtime `Context` are deliberately unused — note
  that `Context.getAccessKey()` / `getSecretKey()` are also deprecated in the
  FunctionGraph runtime SDK and can no longer be relied on.

  No secret is embedded in the jar; values are injected by Terraform.

* The DynamoDB client is the DynamoDB Java SDK v2 (see `pom.xml`), retained
  purely as a wire-protocol client. It is configured with
  `endpointOverride = http://${lb_ip_address}:8000` so requests land on
  GeminiDB instead of a public DynamoDB endpoint. This is the documented way
  to reach a GeminiDB DynamoDB-compatible instance: the SDK speaks the
  DynamoDB wire protocol natively, and GeminiDB implements that protocol on its
  load-balancer address.
