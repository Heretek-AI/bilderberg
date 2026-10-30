#!/usr/bin/env bash
set -euo pipefail

TARGET_ID="${1:-}"
if [ -z "$TARGET_ID" ]; then
  echo "Usage: $0 <target_id>"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${SCRIPT_DIR}/../patches/${TARGET_ID}"

if [ ! -d "$PATCH_DIR" ]; then
  echo "No patches directory for ${TARGET_ID}; skipping."
  exit 0
fi

shopt -s nullglob
patch_files=("${PATCH_DIR}"/*.patch)

for patch_file in "${patch_files[@]}"; do
  echo "Applying patch: ${patch_file}"
  if git apply --check "$patch_file" 2>/dev/null; then
    git apply "$patch_file"
  elif git apply --3way "$patch_file" 2>/dev/null; then
    echo "Applied ${patch_file} via 3-way merge."
  elif [ -f "${PATCH_DIR}/transform.js" ]; then
    echo "Falling back to AST/Regex transform: ${PATCH_DIR}/transform.js"
    node "${PATCH_DIR}/transform.js"
  else
    echo "::error::Failed to apply patch ${patch_file}"
    exit 1
  fi
done
