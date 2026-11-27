# internet-functiongraph-snapshot-warmup

[![terraform ≥ 1.5](https://img.shields.io/badge/terraform-%E2%89%A51.5-623CE4)](https://www.terraform.io)
[![provider huaweicloud ~> 1.70](https://img.shields.io/badge/huaweicloud_provider-%7E%3E1.70-FF6A00)](https://registry.terraform.io/providers/huaweicloud/huaweicloud)
[![Java 11](https://img.shields.io/badge/Java-11-007396)](https://www.java.com)
[![License: MIT No Attribution](https://img.shields.io/badge/License-MIT_No_Attribution-blue)](./LICENSE)

## 1. Overview

### Overview

> A Huawei Cloud **FunctionGraph + APIG + GeminiDB (DynamoDB-compatible)** best practice, demonstrating process-level snapshot acceleration of Java cold starts (the platform-level `reserved_instances` resident instance pool mechanism).

This repository is a standalone Huawei Cloud best practice demonstrating how Java functions on FunctionGraph eliminate cold starts through a process-level snapshot mechanism. It implements the core business logic (transaction write API + 100 ms simulation + single-instance brokerId injection) and builds a Huawei Cloud native architecture with Terraform and the huaweicloud Provider.

**Business scenario**: an API client submits a stock transaction through HTTPS POST `/transactions`; the FGS function receives and validates it, writes it to a GeminiDB DynamoDB-compatible table, and returns the write result.

**Core mechanism**: the FunctionGraph `reserved_instances` block (a platform-level resident instance pool) skips JVM startup, framework initialization, and business initialization, eliminating Java cold start latency.

---

## 2. Table of Contents

- [1. Overview](#1-overview)
- [2. Table of Contents](#2-table-of-contents)
- [3. Architecture Diagram](#3-architecture-diagram)
- [4. Highlights](#4-highlights)
- [5. Cloud Services Used](#5-cloud-services-used)
- [6. Prerequisites](#6-prerequisites)
- [7. Quick Start](#7-quick-start)
- [8. Step-by-Step Deployment](#8-step-by-step-deployment)
- [9. Usage / Verification](#9-usage--verification)
- [10. Cleanup](#10-cleanup)
- [11. Detailed Explanation](#11-detailed-explanation)
- [12. Dependencies](#12-dependencies)
- [13. FAQ / Troubleshooting](#13-faq--troubleshooting)
- [14. Contributing](#14-contributing)
- [15. License](#15-license)
- [16. Contact / Maintainers](#16-contact--maintainers)

---

## 3. Architecture Diagram

```
   ┌────────┐        HTTPS POST /transactions
   │ Client │───────────────────────────────────►  APIG (Dedicated BASIC)
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
                     Pull jar from OBS (agency) ◄──┘           │
                                                              ▼
                                            GeminiDB (DynamoDB-compatible)
                                            lb_ip_address:80
                                            Auth = rwuser + instance admin password
                                            (provided via user_data as environment variables)
```

For the complete architecture description and decision tree, see [`docs/architecture.md`](./docs/architecture.md).

---

## 4. Highlights

| Highlight | Description |
|---|---|
| Eliminate Java cold starts | The `reserved_instances` block pre-warms N resident instances on the function version, so requests hit a warm instance directly |
| One-click switch between two modes | `function_reserved_instance_count`: `0` = cold start mode, `≥1` = warm instance mode |
| Database protocol compatibility | GeminiDB is compatible with the wide-column protocol; connect with a standard protocol client |
| No credentials on disk | Database credentials are supplied via `user_data` as environment variables; no secret is written into the jar's code or configuration files |
| All resources managed as IaC | VPC / OBS / IAM / GeminiDB / FGS / APIG are all managed by Terraform, auditable and rollback-capable |

---

## 5. Cloud Services Used

| Service | Purpose |
|---|---|
| FunctionGraph (FGS) | Java 11 function runtime, hosting the transaction write logic |
| API Gateway (APIG Dedicated) | Exposes the HTTPS POST `/transactions` entry point |
| GeminiDB (DynamoDB-compatible) | Transaction table storage, with a protocol-compatible client |
| Object Storage Service (OBS) | Hosts the function code jar |
| Identity and Access Management (IAM) | Agency delegation, allowing the function to pull code from OBS |
| Virtual Private Cloud (VPC) | Network isolation + security group access rules |

> Cleanup note: all resources of this practice can be reclaimed with one `terraform destroy` (see Section 10); there is no need to delete items one by one in the console.

---

## 6. Prerequisites

| Tool / Resource | Description | Verification command |
|---|---|---|
| Terraform ≥ 1.5 | 1.9.x recommended; validated locally with v1.15.8 | `terraform version` |
| huaweicloud Provider | Installed via `terraform init` | `terraform providers` |
| Huawei Cloud account | Target region enabled + FunctionGraph + APIG (Dedicated) + GeminiDB (DynamoDB-compatible) + IAM + OBS permissions | Region drop-down at the top right of the console |
| AK / SK | Used only in local environment variables, **never written into tfvars or README** | `echo $HW_ACCESS_KEY` |
| Java 11 + Maven 3.9+ | Build the FunctionGraph function jar | `mvn -version` |
| FunctionGraph Java runtime SDK | The `fss-java-sdk` jar must be downloaded manually and placed in `lib/` (see Section 8) | `ls src/functions/unicorn-stock-broker/lib/fss-java-sdk.jar` |
| Python 3.9+ | Run the OBS upload script | `python --version` |
| Huawei Cloud SDK for Python v3 | OBS upload dependency | `pip show huaweicloud-sdk-python-v3` |

---

## 7. Quick Start

> For the detailed version, see [`docs/deployment-guide.md`](./docs/deployment-guide.md).

```bash
# 0) One-time preparation: FunctionGraph Java runtime SDK
#    This SDK is not published on Maven Central; obtain it from the FunctionGraph SDK download page
#    Extract fss-java-sdk and place it at:
#      src/functions/unicorn-stock-broker/lib/fss-java-sdk.jar

# 1) Prepare variables
cd infra/
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: region / domain_name / geminidb_password / geminidb_flavor

# 2) Build and upload the function jar
cd ../src/functions/unicorn-stock-broker
mvn -B clean package
HW_ACCESS_KEY=... HW_SECRET_KEY=... \
  BUCKET=$(grep function_code_bucket ../../infra/terraform.tfvars | cut -d'"' -f2) \
  REGION=$(grep '^region' ../../infra/terraform.tfvars | cut -d'"' -f2) \
  ./build_and_upload.sh
# The last line outputs the OBS object URL

# 3) Deploy
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

## 8. Step-by-Step Deployment

1. **Prepare the runtime SDK**: download `fss-java-sdk` and place it at
   `src/functions/unicorn-stock-broker/lib/fss-java-sdk.jar`.
2. **Prepare variables**: copy `terraform.tfvars.example` to `terraform.tfvars` and fill in
   `region` (e.g. `cn-north-4`), `domain_name` (tenant name),
   `geminidb_password` (8–32 characters, at least two of uppercase letters, lowercase letters, digits, and special characters), and
   `geminidb_flavor` (the DynamoDB-compatible instance specification code available in the target region, required).
3. **Build the function jar**: in `src/functions/unicorn-stock-broker/`, run
   `mvn -B clean package`; the artifact is `target/unicorn-stock-broker-1.0-fgs.jar`.
4. **Upload to OBS**: `build_and_upload.sh` automatically creates/reuses the bucket and uploads (`_tools/obs_upload.py` is also available).
5. **Initialize Terraform**: `terraform init` downloads the huaweicloud Provider;
   in an offline environment, configure `dev_overrides` to point to a local provider mirror.
6. **Preview and deploy**: `terraform plan -out tfplan` → `terraform apply tfplan`.
   After deployment, read the output: `terraform output -raw obs_function_code_url`.

For the expected output and acceptance criteria of each step, see [`docs/deployment-guide.md`](./docs/deployment-guide.md) §3–§5.

---

## 9. Usage / Verification

After deployment:

```bash
# Transaction entry point (public address of the APIG Dedicated instance)
APIG_URL="https://<apig-ingress-address>/transactions"

# Submit a transaction
curl -X POST "$APIG_URL" \
  -H "Content-Type: application/json" \
  -d '{"stockId":"UNCN","quantity":3}'
# Expected: 200 OK
# body: "Broker xxxxxxxx successfully created transaction <uuid>"
```

**Step-by-step verification guide** (please execute and check in order):
1. Console: FunctionGraph → Functions → `fgs-unicorn-broker` → Overview;
   it should show runtime Java11 / memory 2048 MB / timeout 200 s.
2. Console: Object Storage Service → bucket `fgs-unicorn-artifacts`
   → function-code/ → `unicorn-stock-broker-1.0-fgs.jar`;
   the jar should be visible, with a size matching the mvn artifact.
3. Console: GeminiDB → `fgs-unicorn-gdb` → Data Management → Tables;
   `TransactionsTable` should be visible (HASH key=transactionId, 4 columns).
4. Console: FunctionGraph → Functions → `fgs-unicorn-broker` → Logs;
   the most recent "PutItem response metadata: 200" should be visible.
5. A screenshot of the curl command output above (or the online debug invocation result of the function).

After deployment, follow these steps to verify that the business functionality works before considering the delivery complete.

---

## 10. Cleanup

> **Safety constraint**: `destroy` in this practice is **limited to resources created by this task only**.
> It is not allowed to destroy the shared NAT gateway, the shared VPC,
> or instances created by other tasks under the same AK/SK.

```bash
cd infra/
terraform destroy
# Check the destroy list item by item to confirm no shared resource is selected
```

---

## 11. Detailed Explanation

### 11.1 Project structure

```
.
├── LICENSE                                      # MIT No Attribution
├── README.md                                    # This file
├── README.en.md                                 # English version
├── docs/
│   ├── architecture.md                          # Architecture description
│   └── deployment-guide.md                      # Detailed deployment steps
├── infra/                                       # Terraform + huaweicloud Provider
│   ├── main.tf                                  # Module entry and common tags
│   ├── providers.tf
│   ├── variables.tf
│   ├── network.tf                               # VPC + Subnet + SG
│   ├── obs.tf                                   # OBS bucket for function code
│   ├── iam.tf                                   # IAM Agency
│   ├── geminidb.tf                              # GeminiDB DynamoDB-compatible instance
│   ├── functiongraph.tf                         # FGS function (including reserved_instances)
│   ├── apig.tf                                  # APIG instance + group
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── src/functions/unicorn-stock-broker/          # FGS Java function source
│   ├── pom.xml
│   ├── README.md
│   ├── build_and_upload.sh
│   ├── lib/                                     # Runtime SDK jar (manual download required)
│   └── src/main/java/com/unicorn/broker/
│       ├── FunctionGraphHandler.java
│       ├── core/
│       │   ├── UnicornStockBrokerHandler.java
│       │   └── TransactionService.java
│       ├── data/
│       │   └── TransactionRepository.java
│       └── model/
│           └── Transaction.java
└── _tools/                                      # Common utility scripts
    └── obs_upload.py                            # Upload the jar to OBS
```

### 11.2 Component implementation overview

| Component | Implementation | Risk level |
|---|---|---|
| Java11 function runtime | FunctionGraph (Java11, 2048MB) | 🟡 |
| Process-level snapshot (cold start acceleration) | reserved_instances block | 🟡 |
| HTTPS POST `/transactions` | APIG (Dedicated BASIC) | 🟢 |
| Transaction table (elastically scalable by request volume) | GeminiDB (DynamoDB-compatible, cluster) | 🟢 |
| Function code bucket | OBS bucket (function code hosting only) | 🟢 |
| Function execution permissions | IAM Agency (OBS OperateAccess) | 🟢 |
| Java function entry point | `com.huawei.services.runtime` SDK | 🟡 |
| APIG proxy event object | Directly receives `Map<String,Object>` | 🟡 |
| Asynchronous protocol client | Synchronous protocol client (Apache HTTP) | 🟢 |
| CRaC resource hook | Replaced by the platform resident instance pool mechanism | 🟢 |

### 11.3 Process-level snapshot acceleration

The process-level snapshot acceleration demonstrated in this practice is implemented through the FunctionGraph `reserved_instances` block.
The platform pre-warms N resident instances on the published function version; requests are routed directly to a warm instance, skipping JVM startup,
framework initialization, and business initialization.

| Terraform field | Meaning |
|---|---|
| `count` | Number of reserved instances (≥1 enables the pre-warm pool) |
| `idle_mode = true` | Instances are not released when there is no traffic (a boolean, not a string) |
| `qualifier_name = "latest"` | Binds to the latest version |
| `qualifier_type = "version"` | Scoped by version |

**Switching**:

```bash
# Disable the pre-warm pool (cold start mode)
terraform apply -var 'function_reserved_instance_count=0'

# Enable the pre-warm pool (warm instance mode)
terraform apply -var 'function_reserved_instance_count=1'
```

### 11.4 Parameter tuning

| Parameter | Default | Adjustment advice |
|---|---|---|
| `function_memory_size` | 2048 | Lowering reduces resource usage; raising reduces cold start latency |
| `function_timeout` | 200 | Set to business peak ×1.5 |
| `function_reserved_instance_count` | 1 | Set 2–5 for high QPS; set 0 for sporadic traffic |
| `geminidb.flavor.size` | 100 GB | Estimate by transaction volume × 6 months |
| `geminidb_flavor` | Placeholder (required) | Use a DynamoDB-compatible specification code available in the target region |

> The default value of `geminidb_flavor` causes variable validation to fail; it must be changed to an actual specification code. A specification code belongs to the "GeminiDB compatible with DynamoDB interface" specification family; although specification codes for other GeminiDB engines (Cassandra, Mongo, Influx, Redis) look similar, they are not in the same family, and using one will be rejected by the server during apply.

### 11.5 Design decisions

Key points:
1. **Process-level snapshot acceleration**: option A. `reserved_instances` (🟡 fully rollback-capable)
2. **Validation file bucket**: option B. not retained (🟢 fully rollback-capable)
3. **Java handler path**: option A. standalone function (🟡 fully rollback-capable)
4. **Terraform module split**: option A. flat (🟢 fully rollback-capable)

Among these, the three items **GeminiDB data-plane authentication model**, **specification code family**, and **how to obtain the runtime SDK** are detailed in §11.2 Component implementation overview, §11.4 Parameter tuning, and Section 8 Step-by-Step Deployment, respectively.

---

## 12. Dependencies

| Dependency | Version / Description |
|---|---|
| `huaweicloud/huaweicloud` Provider | ~> 1.70 (validated locally with v1.97.1) |
| FunctionGraph Java runtime SDK | `fss-java-sdk` (official download package, not published on Maven Central) |
| DynamoDB Java SDK v2 | Used as a wire-protocol client to connect to the GeminiDB-compatible endpoint (see `src/functions/unicorn-stock-broker/README.md`) |
| Maven / maven-shade-plugin | Build the executable jar |
| Huawei Cloud SDK for Python v3 | Dependency of `_tools/obs_upload.py` |

---

## 13. FAQ / Troubleshooting

| Problem | Answer |
|---|---|
| `terraform apply` reports `ELB.8907` | The APIG public ingress specification is misconfigured; check `apig.tf` for `request_protocol="HTTPS"` |
| APIG returns 500 | The FGS function did not start correctly; FGS console → Functions → Logs → check for `HANDLER ENTRY` |
| GeminiDB write fails (`auth failed`) | The data plane only accepts the instance database account: check that `GEMINIDB_USER=rwuser` and `GEMINIDB_PASSWORD` match `geminidb_password` |
| GeminiDB is unreachable | The security group does not allow VPC→8000; console: GeminiDB → Instance → Security Group → allow 8000 from 10.0.0.0/16 |
| `geminidb_flavor` validation fails | It is still a placeholder; use `huaweicloud_geminidb_flavors` to query the DynamoDB-compatible `spec_code` for the target region |
| `mvn package` reports `com.huawei.services.runtime.Context` not found | `lib/fss-java-sdk.jar` is missing; this SDK must be downloaded manually from the FunctionGraph SDK download page |
| `terraform validate` reports `no package for 'huaweicloud/huaweicloud' cached` | The sandbox cannot reach the registry; use `dev_overrides` with the local schema |
| How to switch between the two modes | `terraform apply -var 'function_reserved_instance_count=0\|1'`, reversible at any time |

---

## 14. Contributing

1. Fork this repository and create a feature branch.
2. After making changes, run `terraform fmt -recursive` + `terraform validate` to ensure IaC compliance.
3. When adding or modifying function code, run `mvn -B clean package` to confirm it builds.
4. Attach deployment verification screenshots when submitting a PR (see the step-by-step verification guide in Section 9).
5. Complete the functional self-check following the steps in Section 9 before deployment.

---

## 15. License

MIT No Attribution. Copyright Huawei Cloud.

---

## 16. Contact / Maintainers
| Item | Content |
|---|---|
| **Creator** | [dgc-git](https://github.com/dgc-git) |
| **Maintainer** | [dgc-git](https://github.com/dgc-git) |
| **Contact** | GitHub Issues / PR (see [Section 14](#14-contributing)) |
