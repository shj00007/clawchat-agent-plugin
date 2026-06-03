#!/usr/bin/env bash
#
# Upload docs/install-dev.md to the Cloudflare R2 bucket under the clawchat/ prefix.
#
# Usage:
#   ./script/upload-install-dev.sh
#
# Requires:
#   - aws CLI (v2)
#   - script/.env.r2 holding R2 credentials + endpoint (see script/.env.r2.example)
#
set -euo pipefail

# Resolve repo root (this script lives in <root>/script/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${SCRIPT_DIR}/.env.r2"
SRC_FILE="${ROOT_DIR}/docs/install-dev.md"
DEST_KEY="clawchat/install-dev.md"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "error: ${ENV_FILE} not found" >&2
  exit 1
fi

if [[ ! -f "${SRC_FILE}" ]]; then
  echo "error: ${SRC_FILE} not found" >&2
  exit 1
fi

# Load R2 config. AWS_* vars are picked up by the aws CLI automatically.
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

: "${R2_ENDPOINT:?R2_ENDPOINT missing in .env.r2}"
: "${R2_BUCKET:?R2_BUCKET missing in .env.r2}"

echo "Uploading ${SRC_FILE}"
echo "      -> s3://${R2_BUCKET}/${DEST_KEY}"

aws s3 cp "${SRC_FILE}" "s3://${R2_BUCKET}/${DEST_KEY}" \
  --endpoint-url "${R2_ENDPOINT}" \
  --content-type "text/markdown; charset=utf-8"

echo "Done."
