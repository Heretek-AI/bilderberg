#!/usr/bin/env bash
set -euo pipefail

TARGET_APP="${1:-}"

if [ -z "$TARGET_APP" ]; then
  echo "Error: Target application parameter missing."
  echo "Usage: $0 <target_app>"
  exit 1
fi

ROOT_DIR="$(pwd)"
PATCH_DIR="${ROOT_DIR}/patches/${TARGET_APP}"

if [ ! -d "$PATCH_DIR" ]; then
  echo "No patches directory found for ${TARGET_APP} at ${PATCH_DIR}. Skipping patch phase."
  exit 0
fi

echo "Initiating patch phase for target: ${TARGET_APP}"

TARGET_SUBMODULE="${ROOT_DIR}/submodules/${TARGET_APP}"
if [ -d "$TARGET_SUBMODULE" ]; then
  echo "Changing directory to submodule: ${TARGET_SUBMODULE}"
  cd "$TARGET_SUBMODULE"
else
  echo "Warning: Submodule directory ${TARGET_SUBMODULE} does not exist. Operating in root directory."
fi

shopt -s nullglob
patch_files=("${PATCH_DIR}"/*.patch)

if [ ${#patch_files[@]} -eq 0 ]; then
  echo "No .patch files found in ${PATCH_DIR}."
else
  for patch_file in "${patch_files[@]}"; do
    echo "Applying unified diff: ${patch_file}"
      
    if git apply --check "$patch_file" 2>/dev/null; then
      git apply "$patch_file"
      echo "Successfully applied ${patch_file} via direct patch."
    else
      echo "Warning: Direct patch application failed. Attempting 3-way merge fallback..."
      if git apply --3way "$patch_file"; then
        echo "3-way merge patch succeeded."
      else
        echo "Error: Unified diff ${patch_file} failed to apply. Escalating to AST/Regex transformers."
        if [ -f "${PATCH_DIR}/transform.js" ]; then
          echo "Executing AST transformation script: ${PATCH_DIR}/transform.js"
          node "${PATCH_DIR}/transform.js"
        else
          echo "Fatal: Patch application failed and no AST transformer script exists."
          exit 1
        fi
      fi
    fi
  done
fi

if [ -f "${PATCH_DIR}/transform.js" ] && [ ${#patch_files[@]} -eq 0 ]; then
  echo "Executing AST transformation script: ${PATCH_DIR}/transform.js"
  node "${PATCH_DIR}/transform.js"
fi

echo "Patch application phase completed successfully for ${TARGET_APP}."
