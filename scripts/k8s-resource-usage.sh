#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="${1:-${NAMESPACE:-lab8-spark}}"

python3 "${ROOT_DIR}/scripts/k8s_resource_usage.py" "${NAMESPACE}"
