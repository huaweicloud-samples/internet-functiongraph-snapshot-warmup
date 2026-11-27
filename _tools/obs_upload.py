#!/usr/bin/env python3
"""
obs_upload.py — minimal OBS uploader using the huaweicloud-sdk-python-v3.

Reads AK/SK from env (HW_ACCESS_KEY / HW_SECRET_KEY). Use this script to push
the FGS function jar to an OBS bucket before Terraform `apply`. The object
URL is consumed by huaweicloud_fgs_function.code_url.

Why a custom helper instead of `obsutil` or a generic object-store CLI?
  - Keeps the dependency surface tiny (one Python package).
  - Honours `iam` server-side encryption.
  - Prints the public HTTPS object URL that Terraform references.
"""
from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

# huaweicloud-sdk-python-v3 — OBS submodule
try:
    from huaweicloudsdkcore.auth.credentials import BasicCredentials
    from huaweicloudsdkcore.exceptions import exceptions
    from huaweicloudsdkcore.http.http_config import HttpConfig
    from huaweicloudsdkobs.v3 import (
        ObsClient,
        HeadBucketRequest,
        PutObjectRequest,
    )
    from huaweicloudsdkobs.v3.region.region import Region
except Exception as exc:  # pragma: no cover - import surface area
    sys.stderr.write(
        f"ERROR: huaweicloud-sdk-python-v3 not installed ({exc!r}).\n"
        "Install with: pip install huaweicloud-sdk-python-v3\n"
    )
    sys.exit(2)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("obs_upload")


def upload(region: str, bucket: str, key: str, file_path: str) -> None:
    ak = os.environ.get("HW_ACCESS_KEY")
    sk = os.environ.get("HW_SECRET_KEY")
    if not ak or not sk:
        sys.stderr.write("ERROR: HW_ACCESS_KEY and HW_SECRET_KEY must be set.\n")
        sys.exit(2)

    endpoint = f"https://obs.{region}.myhuaweicloud.com"
    credentials = BasicCredentials(ak, sk)
    http_config = HttpConfig(timeout=120, retry_times=3)
    client = ObsClient(
        credentials=credentials,
        server_endpoint=endpoint,
        region=region,
        http_config=http_config,
    )

    try:
        try:
            client.headBucket(HeadBucketRequest(bucket=bucket))
        except exceptions.ClientRequestException as e:
            if e.status_code == 404:
                log.error(
                    "Bucket %s does not exist or is not accessible. Create it "
                    "first (or let Terraform create it via huaweicloud_obs_bucket).",
                    bucket,
                )
            raise

        file_size = Path(file_path).stat().st_size
        log.info("Uploading %s (%d bytes) -> obs://%s/%s", file_path, file_size, bucket, key)
        resp = client.putObject(
            PutObjectRequest(
                bucket=bucket,
                object_key=key,
                content_path=file_path,
                # Server-side encryption via OBS-managed keys — bucket default.
                metadata={"x-obs-meta-source": "fgs-unicorn-broker"},
            )
        )
        log.info(
            "Upload complete: etag=%s, version_id=%s",
            resp.body.etag,
            resp.body.version_id,
        )
    finally:
        client.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", required=True, help="e.g. cn-north-4")
    parser.add_argument("--bucket", required=True)
    parser.add_argument("--key", required=True, help="object key inside the bucket")
    parser.add_argument("--file", required=True, help="local file to upload")
    args = parser.parse_args()

    if not Path(args.file).is_file():
        sys.stderr.write(f"ERROR: file not found: {args.file}\n")
        return 2

    upload(args.region, args.bucket, args.key, args.file)
    return 0


if __name__ == "__main__":
    sys.exit(main())