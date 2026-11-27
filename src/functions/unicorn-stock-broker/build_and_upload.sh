#!/usr/bin/env bash
# ----------------------------------------------------------------------------
# build_and_upload.sh — produce the FGS jar and push it to OBS
# ----------------------------------------------------------------------------
# Usage:
#   HW_ACCESS_KEY=... HW_SECRET_KEY=... REGION=cn-north-4 \
#     BUCKET=fgs-unicorn-artifacts \
#     ./build_and_upload.sh
#
# Result:
#   - target/unicorn-stock-broker-1.0-fgs.jar
#   - uploaded to obs://$BUCKET/function-code/unicorn-stock-broker-1.0-fgs.jar
#   - prints the OBS object URL on stdout for Terraform to consume
# ----------------------------------------------------------------------------
set -euo pipefail

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${MODULE_DIR}"

: "${HW_ACCESS_KEY:?HW_ACCESS_KEY not set}"
: "${HW_SECRET_KEY:?HW_SECRET_KEY not set}"
: "${REGION:=cn-north-4}"
: "${BUCKET:?BUCKET not set}"
: "${OBJECT_KEY:=function-code/unicorn-stock-broker-1.0-fgs.jar}"

echo "==> Building unicorn-stock-broker-1.0-fgs.jar"
mvn -B clean package -DskipTests

JAR="${MODULE_DIR}/target/unicorn-stock-broker-1.0-fgs.jar"
test -f "${JAR}" || { echo "ERROR: jar not produced: ${JAR}"; exit 2; }

echo "==> Uploading to obs://${BUCKET}/${OBJECT_KEY}"
python3 "${MODULE_DIR}/../../_tools/obs_upload.py" \
  --region "${REGION}" \
  --bucket "${BUCKET}" \
  --key "${OBJECT_KEY}" \
  --file "${JAR}"

echo "==> DONE. Object URL:"
echo "https://${BUCKET}.obs.${REGION}.myhuaweicloud.com/${OBJECT_KEY}"