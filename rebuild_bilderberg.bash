#!/usr/bin/env bash
# Self-contained installer for Bilderberg 2.0.
# Run from the root of your Heretek-AI/bilderberg git repository checkout:
#   bash rebuild_bilderberg.sh
set -euo pipefail

echo "==> Removing legacy submodules, workflows, patches, and docs..."
for sub in submodules/bifrost submodules/gdevelop submodules/litellm submodules/monsterinsights; do
  if [ -e "$sub" ]; then
    git submodule deinit -f "$sub" 2>/dev/null || true
    git rm -f "$sub" 2>/dev/null || rm -rf "$sub"
    rm -rf ".git/modules/$sub"
  fi
done

git rm -f --ignore-unmatch \
  .gitmodules \
  "Automated Meta Repo Build Roadmap.md" \
  .github/workflows/build-and-release.yml \
  .github/workflows/build-drop-tarball.yml \
  .github/workflows/build-ragflow-tarball.yml \
  .github/workflows/upstream-sync.yml \
  docs/drop-tarball-installation.md \
  docs/ragflow-tarball-installation.md 2>/dev/null || true

rm -rf \
  .gitmodules \
  "Automated Meta Repo Build Roadmap.md" \
  .github/workflows/build-and-release.yml \
  .github/workflows/build-drop-tarball.yml \
  .github/workflows/build-ragflow-tarball.yml \
  .github/workflows/upstream-sync.yml \
  patches/bifrost \
  patches/gdevelop \
  patches/litellm-gateway \
  patches/monsterinsights \
  submodules \
  docs

mkdir -p .github/workflows scripts state patches/memos

cat << 'EOF_GITIGNORE' > .gitignore
# Python & byte-compiled files
__pycache__/
*.py[cod]
*$py.class
.venv/
venv/
.pytest_cache/

# Build & CI transient artifacts
digests/
receipts/
upstream/
meta/
build/
dist/
*.tar.gz

# OS & editor files
.DS_Store
*.swp
EOF_GITIGNORE

cat << 'EOF_README' > README.md
# Bilderberg

Dynamic daily multi-architecture (`linux/amd64` + `linux/arm64`) container build system for upstream GitHub projects that ship `Dockerfile` definitions without publishing official pre-built images.

## How It Works

1. **Daily Upstream Commit Monitor (`scripts/resolve_matrix.py`)**: Runs every day at `06:00 UTC` (or on manual `workflow_dispatch`). Queries the GitHub REST API for each target in `targets.yaml`, compares the upstream branch SHA against `state/build-state.json`, and checks whether any non-ignored files changed.
2. **Hybrid Multi-Dockerfile Discovery**: Combines explicit `images:` definitions in `targets.yaml` with recursive Git Tree discovery (`auto_discover: true`) for `Dockerfile`, `Dockerfile.*`, and `*.Dockerfile` files. Automatically infers whether subdirectory Dockerfiles expect the repository root (`.`) or their parent folder as the build context by inspecting `COPY`/`ADD` instructions.
3. **Native Parallel `amd64` & `arm64` Builds (`.github/workflows/daily-docker-builds.yml`)**: Builds `linux/amd64` on `ubuntu-latest` and `linux/arm64` on `ubuntu-24.04-arm` in parallel, pushes per-architecture images by digest, and merges them into `ghcr.io/heretek-ai/<image>` with `:latest`, `:sha-<short_sha>`, and `:YYYY.MM.DD` tags.
4. **Per-Image State Lockfile (`state/build-state.json`)**: Commits updated SHAs via `scripts/update_state.py` only for images whose multi-arch manifest succeeded, so any failed image automatically retries on the next run.

## Configured Targets

| Target ID | Upstream Repository | Default Image(s) | Architectures |
| :--- | :--- | :--- | :--- |
| `memos` | [`MemTensor/MemOS`](https://github.com/MemTensor/MemOS) | `ghcr.io/heretek-ai/memos`, `ghcr.io/heretek-ai/memos-docker` (+ auto-discovered Dockerfiles) | `linux/amd64`, `linux/arm64` |

## Adding a New Target

Add an entry under `targets:` in `targets.yaml`:

```yaml
  - id: example-project
    repo: Owner/ExampleRepo
    branch: main
    auto_discover: true
    images:
      - name: example-project
        dockerfile: Dockerfile
        context: .
```
EOF_README

cat << 'EOF_TARGETS' > targets.yaml
# targets.yaml
# Declarative registry of upstream repositories and Dockerfile build targets.
defaults:
  registry: ghcr.io
  namespace: heretek-ai
  branch: main
  platforms:
    - linux/amd64
    - linux/arm64
  auto_discover: true
  exclude_dockerfiles:
    - "tests/**"
    - "test/**"
    - "examples/**"
    - "docs/**"
    - "benchmark/**"
    - "evaluation/**"
    - "apps/**"
    - "**/e2e/**"
    - "*.krolik"
    - "**/*.krolik"

targets:
  # Target 1: MemTensor/MemOS
  # Official build instructions: https://github.com/MemTensor/MemOS
  - id: memos
    repo: MemTensor/MemOS
    branch: main
    description: "Self-evolving memory OS for LLM & AI Agents"
    auto_discover: false
    ignore_paths:
      - "docs/**"
      - "*.md"
      - "assets/**"
      - "evaluation/**"
      - "examples/**"
    images:
      # Root production Dockerfile (multi-stage python:3.11-slim -> uvicorn server_api)
      - name: memos
        dockerfile: Dockerfile
        context: .
        platforms:
          - linux/amd64
          - linux/arm64
        build_args:
          HF_ENDPOINT: "https://huggingface.co"

      # Secondary Dockerfile in docker/ directory (official dev compose setup)
      - name: memos-docker
        dockerfile: docker/Dockerfile
        context: .
        optional: true
        platforms:
          - linux/amd64
          - linux/arm64
EOF_TARGETS

if [ ! -f state/build-state.json ]; then
  echo "{}" > state/build-state.json
fi

cat << 'EOF_RESOLVE' > scripts/resolve_matrix.py
#!/usr/bin/env python3
"""
Hybrid Upstream Commit Monitor & Multi-Dockerfile Matrix Resolver.

1. Polls each target repository in `targets.yaml` for its latest branch commit SHA.
2. Uses the Hybrid Discovery model:
   - Loads explicit `images:` definitions from `targets.yaml` (preserving custom names,
     contexts, build_args, target stages, and platform lists).
   - When `auto_discover: true`, scans the upstream Git tree for any additional
     Dockerfiles (`Dockerfile`, `Dockerfile.*`, `*.Dockerfile`, `*.dockerfile`) not
     already listed in `images:` and automatically infers their build context (`.` vs
     parent directory) by checking `COPY`/`ADD` instructions against the repo tree.
3. Compares each resolved `(target_id, image_name)` against `state/build-state.json`
   and skips images whose upstream SHA has not changed (or where only ignored paths changed).
4. Outputs two JSON matrices for GitHub Actions:
   - `build_matrix`: Per-(image, platform) jobs mapped to native GitHub runners
     (`ubuntu-latest` for `linux/amd64`, `ubuntu-24.04-arm` for `linux/arm64`).
   - `image_matrix`: Per-image summary jobs to merge architecture digests into a
     multi-arch manifest (`ghcr.io/heretek-ai/<image>`) and record build state.
"""

import base64
import fnmatch
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path
import yaml

STATE_FILE = Path("state/build-state.json")
TARGETS_FILE = Path("targets.yaml")

RUNNER_MAP = {
    "linux/amd64": "ubuntu-latest",
    "linux/arm64": "ubuntu-24.04-arm",
}

COPY_ADD_RE = re.compile(r"^\s*(?:COPY|ADD)\s+(?:--\S+\s+)*([^\s]+)\s+", re.IGNORECASE | re.MULTILINE)


def gh_api_get(url: str):
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "bilderberg-dynamic-builder",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def get_upstream_commit(repo: str, branch: str) -> str:
    try:
        data = gh_api_get(f"https://api.github.com/repos/{repo}/commits/{branch}")
        return data["sha"]
    except Exception:
        out = subprocess.check_output(
            ["git", "ls-remote", f"https://github.com/{repo}.git", f"refs/heads/{branch}"],
            text=True,
        ).strip()
        return out.split()[0]


def get_upstream_tree_files(repo: str, sha: str) -> list[str]:
    try:
        data = gh_api_get(f"https://api.github.com/repos/{repo}/git/trees/{sha}?recursive=1")
        return [item["path"] for item in data.get("tree", []) if item.get("type") == "blob"]
    except Exception as exc:
        print(f"::warning::Could not fetch tree for {repo}@{sha}: {exc}", file=sys.stderr)
        return []


def infer_dockerfile_context(repo: str, sha: str, dockerfile_path: str, tree_files: list[str]) -> str:
    parent = str(Path(dockerfile_path).parent)
    if parent in (".", ""):
        return "."
    try:
        data = gh_api_get(f"https://api.github.com/repos/{repo}/contents/{dockerfile_path}?ref={sha}")
        raw = base64.b64decode(data.get("content", "")).decode("utf-8", errors="ignore")
    except Exception:
        return parent

    top_level_roots = {Path(p).parts[0] for p in tree_files if Path(p).parts}
    parent_files = {
        str(Path(p).relative_to(parent))
        for p in tree_files
        if p.startswith(parent + "/")
    }

    for match in COPY_ADD_RE.finditer(raw):
        src = match.group(1).strip('"').rstrip("/")
        if not src or src.startswith(("$", "/", "http://", "https://")):
            continue
        first_part = src.split("/")[0]
        if (src in tree_files or first_part in top_level_roots) and src not in parent_files:
            return "."
    return parent


def changed_files_all_ignored(repo: str, old_sha: str, new_sha: str, ignore_globs: list[str]) -> bool:
    if not old_sha or not ignore_globs:
        return False
    try:
        data = gh_api_get(f"https://api.github.com/repos/{repo}/compare/{old_sha}...{new_sha}")
        files = [f["filename"] for f in data.get("files", [])]
        if not files:
            return False
        for fname in files:
            if not any(fnmatch.fnmatch(fname, pat) for pat in ignore_globs):
                return False
        return True
    except Exception:
        return False


def derive_image_name(target_id: str, dockerfile_path: str) -> str:
    p = Path(dockerfile_path)
    parts = list(p.parts)
    if dockerfile_path == "Dockerfile":
        return target_id
    suffix_parts = [pt for pt in parts[:-1] if pt not in (".", "")]
    fname = p.name
    if fname.lower().startswith("dockerfile.") and len(fname) > len("dockerfile."):
        suffix_parts.append(fname.split(".", 1)[1])
    elif fname.lower().endswith(".dockerfile") and len(fname) > len(".dockerfile"):
        suffix_parts.append(fname[: -len(".dockerfile")])
    slug = "-".join(suffix_parts).lower().replace("_", "-")
    return f"{target_id}-{slug}" if slug else target_id


def is_dockerfile_blob(path: str) -> bool:
    basename = Path(path).name
    if basename.endswith((".md", ".txt", ".bak", ".example", ".swp")):
        return False
    return (
        basename == "Dockerfile"
        or basename.startswith("Dockerfile.")
        or basename.endswith(".Dockerfile")
        or basename.endswith(".dockerfile")
    )


def resolve_all(state_file: Path = STATE_FILE, targets_file: Path = TARGETS_FILE) -> dict:
    force_rebuild = os.environ.get("FORCE_REBUILD", "false").lower() == "true"
    filter_target = os.environ.get("TARGET_FILTER", "").strip()

    config = yaml.safe_load(targets_file.read_text(encoding="utf-8"))
    defaults = config.get("defaults", {})
    targets = config.get("targets", [])

    state = {}
    if state_file.exists():
        state = json.loads(state_file.read_text(encoding="utf-8"))

    build_matrix = []
    image_matrix = []

    for tgt in targets:
        target_id = tgt["id"]
        if filter_target and filter_target != target_id:
            continue

        repo = tgt["repo"]
        branch = tgt.get("branch", defaults.get("branch", "main"))
        registry = tgt.get("registry", defaults.get("registry", "ghcr.io"))
        namespace = tgt.get("namespace", defaults.get("namespace", "heretek-ai")).lower()
        default_platforms = tgt.get(
            "platforms",
            defaults.get("platforms", ["linux/amd64", "linux/arm64"]),
        )
        ignore_paths = tgt.get("ignore_paths", [])
        exclude_globs = tgt.get(
            "exclude_dockerfiles",
            defaults.get("exclude_dockerfiles", ["tests/**", "test/**", "examples/**"]),
        )

        latest_sha = get_upstream_commit(repo, branch)
        tree_files = get_upstream_tree_files(repo, latest_sha)
        tree_set = set(tree_files)

        # 1. Start with explicit Dockerfile definitions from targets.yaml
        resolved_images = {img["dockerfile"]: dict(img) for img in tgt.get("images", [])}

        # 2. Hybrid Auto-Discovery: scan upstream git tree for any other Dockerfiles
        if tgt.get("auto_discover", defaults.get("auto_discover", True)) and tree_files:
            for path in tree_files:
                if not is_dockerfile_blob(path):
                    continue
                if any(fnmatch.fnmatch(path, ex) for ex in exclude_globs):
                    continue
                if path not in resolved_images:
                    resolved_images[path] = {
                        "name": derive_image_name(target_id, path),
                        "dockerfile": path,
                        "context": "auto",
                        "platforms": default_platforms,
                    }

        for df_path, img_cfg in resolved_images.items():
            if tree_set and df_path not in tree_set:
                if img_cfg.get("optional", False):
                    print(f"[SKIP-OPTIONAL] {df_path} not present in {repo}@{latest_sha[:7]}")
                    continue
                print(f"::warning::Dockerfile {df_path} not found in {repo}@{latest_sha[:7]}")
                continue

            image_name = img_cfg["name"]
            state_key = f"{target_id}/{image_name}"
            last_built_sha = state.get(state_key, {}).get("sha")

            if not force_rebuild and last_built_sha == latest_sha:
                print(f"[UP-TO-DATE] {state_key} already built at {latest_sha[:7]}")
                continue

            if not force_rebuild and changed_files_all_ignored(repo, last_built_sha, latest_sha, ignore_paths):
                print(f"[IGNORED-DIFF] {state_key}: only ignored files changed ({last_built_sha[:7]}..{latest_sha[:7]})")
                continue

            ctx = img_cfg.get("context", "auto")
            if ctx == "auto":
                ctx = infer_dockerfile_context(repo, latest_sha, df_path, tree_files)

            platforms = img_cfg.get("platforms", default_platforms)
            build_args_dict = img_cfg.get("build_args", {})
            build_args_str = "\n".join(f"{k}={v}" for k, v in build_args_dict.items())
            full_image = f"{registry}/{namespace}/{image_name}"

            image_entry = {
                "target_id": target_id,
                "repo": repo,
                "branch": branch,
                "sha": latest_sha,
                "short_sha": latest_sha[:7],
                "image_name": image_name,
                "full_image": full_image,
                "dockerfile": df_path,
                "context": ctx,
                "platforms": ",".join(platforms),
                "state_key": state_key,
            }
            image_matrix.append(image_entry)

            for platform in platforms:
                arch_slug = platform.split("/")[-1]
                runner = RUNNER_MAP.get(platform, "ubuntu-latest")
                build_matrix.append({
                    **image_entry,
                    "platform": platform,
                    "arch_slug": arch_slug,
                    "runner": runner,
                    "build_args": build_args_str,
                    "target_stage": img_cfg.get("target_stage", ""),
                })

    has_builds = "true" if image_matrix else "false"
    return {
        "has_builds": has_builds,
        "build_matrix": {"include": build_matrix},
        "image_matrix": {"include": image_matrix},
    }


def main():
    res = resolve_all()
    print(
        f"Resolved {len(res['image_matrix']['include'])} image(s) "
        f"across {len(res['build_matrix']['include'])} platform job(s)."
    )
    gh_out = os.environ.get("GITHUB_OUTPUT")
    if gh_out:
        with open(gh_out, "a", encoding="utf-8") as f:
            f.write(f"has_builds={res['has_builds']}\n")
            f.write(f"build_matrix={json.dumps(res['build_matrix'])}\n")
            f.write(f"image_matrix={json.dumps(res['image_matrix'])}\n")
    else:
        print(json.dumps(res, indent=2))


if __name__ == "__main__":
    main()
EOF_RESOLVE
chmod +x scripts/resolve_matrix.py

cat << 'EOF_UPDATE' > scripts/update_state.py
#!/usr/bin/env python3
"""Merges verified multi-arch image build receipts into state/build-state.json."""

import json
from pathlib import Path

STATE_FILE = Path("state/build-state.json")
RECEIPTS_DIR = Path("receipts")


def merge_receipts(state_file: Path = STATE_FILE, receipts_dir: Path = RECEIPTS_DIR) -> int:
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state = {}
    if state_file.exists():
        state = json.loads(state_file.read_text(encoding="utf-8"))

    if not receipts_dir.exists():
        print("No receipts directory found; nothing to update.")
        return 0

    updated = 0
    for receipt_file in sorted(receipts_dir.glob("*.json")):
        data = json.loads(receipt_file.read_text(encoding="utf-8"))
        key = data.pop("state_key")
        state[key] = data
        updated += 1

    if updated:
        state_file.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"Updated {updated} entry/entries in {state_file}.")
    return updated


def main():
    merge_receipts()


if __name__ == "__main__":
    main()
EOF_UPDATE
chmod +x scripts/update_state.py

cat << 'EOF_PATCHES' > scripts/apply-patches.sh
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
EOF_PATCHES
chmod +x scripts/apply-patches.sh

cat << 'EOF_WORKFLOW' > .github/workflows/daily-docker-builds.yml
name: Daily Dynamic Upstream Docker Builds

on:
  schedule:
    # Runs every day at 06:00 UTC
    - cron: '0 6 * * *'
  workflow_dispatch:
    inputs:
      target_filter:
        description: 'Optional target ID to build (e.g., memos). Leave blank for all.'
        required: false
        default: ''
      force_rebuild:
        description: 'Force rebuild even if upstream commit SHA has not changed'
        required: false
        default: false
        type: boolean

permissions:
  contents: write
  packages: write

jobs:
  monitor:
    name: Check Upstream Commits & Resolve Build Matrix
    runs-on: ubuntu-latest
    outputs:
      has_builds: ${{ steps.resolve.outputs.has_builds }}
      build_matrix: ${{ steps.resolve.outputs.build_matrix }}
      image_matrix: ${{ steps.resolve.outputs.image_matrix }}
    steps:
      - name: Checkout Bilderberg Repository
        uses: actions/checkout@v4

      - name: Set up Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'

      - name: Install PyYAML
        run: pip install pyyaml

      - name: Resolve Changed Upstreams & Dockerfiles
        id: resolve
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          FORCE_REBUILD: ${{ inputs.force_rebuild || 'false' }}
          TARGET_FILTER: ${{ inputs.target_filter || '' }}
        run: python3 scripts/resolve_matrix.py

  build-arch:
    name: Build ${{ matrix.image_name }} (${{ matrix.arch_slug }} @ ${{ matrix.short_sha }})
    needs: monitor
    if: needs.monitor.outputs.has_builds == 'true'
    runs-on: ${{ matrix.runner }}
    strategy:
      fail-fast: false
      matrix: ${{ fromJson(needs.monitor.outputs.build_matrix) }}
    steps:
      - name: Checkout Bilderberg Repository (Patches & Scripts)
        uses: actions/checkout@v4
        with:
          path: meta

      - name: Checkout Upstream (${{ matrix.repo }}@${{ matrix.short_sha }})
        uses: actions/checkout@v4
        with:
          repository: ${{ matrix.repo }}
          ref: ${{ matrix.sha }}
          path: upstream
          submodules: recursive

      - name: Apply Optional Target Patches
        run: |
          if [ -d "meta/patches/${{ matrix.target_id }}" ]; then
            chmod +x meta/scripts/apply-patches.sh
            cd upstream
            ../meta/scripts/apply-patches.sh "${{ matrix.target_id }}"
          fi

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and Push Architecture Image by Digest
        id: build
        uses: docker/build-push-action@v6
        with:
          context: upstream/${{ matrix.context }}
          file: upstream/${{ matrix.dockerfile }}
          platforms: ${{ matrix.platform }}
          build-args: ${{ matrix.build_args }}
          target: ${{ matrix.target_stage }}
          labels: |
            org.opencontainers.image.source=https://github.com/${{ matrix.repo }}
            org.opencontainers.image.revision=${{ matrix.sha }}
          outputs: type=image,name=${{ matrix.full_image }},push-by-digest=true,name-canonical=true,push=true
          cache-from: type=gha,scope=${{ matrix.image_name }}-${{ matrix.arch_slug }}
          cache-to: type=gha,mode=max,scope=${{ matrix.image_name }}-${{ matrix.arch_slug }}

      - name: Export Digest Artifact
        run: |
          mkdir -p digests
          digest="${{ steps.build.outputs.digest }}"
          touch "digests/${digest#sha256:}"

      - name: Upload Digest Artifact
        uses: actions/upload-artifact@v4
        with:
          name: digests-${{ matrix.image_name }}-${{ matrix.arch_slug }}
          path: digests/*
          if-no-files-found: error
          retention-days: 1

  merge-manifests:
    name: Publish Multi-Arch ${{ matrix.image_name }} (${{ matrix.short_sha }})
    needs: [monitor, build-arch]
    if: always() && needs.monitor.outputs.has_builds == 'true' && needs.build-arch.result != 'cancelled'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix: ${{ fromJson(needs.monitor.outputs.image_matrix) }}
    steps:
      - name: Download Architecture Digests for ${{ matrix.image_name }}
        uses: actions/download-artifact@v4
        with:
          pattern: digests-${{ matrix.image_name }}-*
          path: digests
          merge-multiple: true
        continue-on-error: true

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to GitHub Container Registry
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Extract Docker Metadata & Tags
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ matrix.full_image }}
          tags: |
            type=raw,value=latest
            type=raw,value=sha-${{ matrix.short_sha }}
            type=raw,value={{date 'YYYY.MM.DD'}}
          labels: |
            org.opencontainers.image.source=https://github.com/${{ matrix.repo }}
            org.opencontainers.image.revision=${{ matrix.sha }}

      - name: Verify All Expected Architecture Digests & Create Multi-Arch Manifest
        run: |
          mkdir -p digests
          cd digests
          expected_count=$(echo "${{ matrix.platforms }}" | tr ',' '\n' | wc -l)
          actual_count=$(ls -1 2>/dev/null | wc -l)
          if [ "$actual_count" -lt "$expected_count" ]; then
            echo "::error::Expected $expected_count platform digests for ${{ matrix.image_name }}, found $actual_count. Architecture builds may have failed."
            exit 1
          fi
          docker buildx imagetools create $(jq -cr '.tags | map("-t " + .) | join(" ")' <<< "$DOCKER_METADATA_OUTPUT_JSON") \
            $(jq -cr '.labels | to_entries | map("--annotation " + "index:" + .key + "=" + .value) | join(" ")' <<< "$DOCKER_METADATA_OUTPUT_JSON") \
            $(printf '${{ matrix.full_image }}@sha256:%s ' *)

      - name: Inspect Published Multi-Arch Image
        run: docker buildx imagetools inspect ${{ matrix.full_image }}:sha-${{ matrix.short_sha }}

      - name: Write Verified Build Receipt
        run: |
          mkdir -p receipts
          cat <<EOF > "receipts/${{ matrix.target_id }}__${{ matrix.image_name }}.json"
          {
            "state_key": "${{ matrix.state_key }}",
            "repo": "${{ matrix.repo }}",
            "dockerfile": "${{ matrix.dockerfile }}",
            "context": "${{ matrix.context }}",
            "platforms": "${{ matrix.platforms }}",
            "sha": "${{ matrix.sha }}",
            "image": "${{ matrix.full_image }}:sha-${{ matrix.short_sha }}",
            "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          }
          EOF

      - name: Upload Verified Build Receipt
        uses: actions/upload-artifact@v4
        with:
          name: receipt-${{ matrix.target_id }}-${{ matrix.image_name }}
          path: receipts/*.json
          retention-days: 3

  record-state:
    name: Commit Updated state/build-state.json
    needs: [monitor, merge-manifests]
    if: always() && needs.monitor.outputs.has_builds == 'true'
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Bilderberg Repository
        uses: actions/checkout@v4

      - name: Download Verified Build Receipts
        uses: actions/download-artifact@v4
        with:
          pattern: receipt-*
          path: receipts
          merge-multiple: true
        continue-on-error: true

      - name: Merge Receipts & Commit State
        run: |
          python3 scripts/update_state.py
          if ! git diff --quiet state/build-state.json; then
            git config user.name "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
            git add state/build-state.json
            git commit -m "chore(state): record built upstream container SHAs [skip ci]"
            git pull --rebase origin main
            git push origin main
          fi
EOF_WORKFLOW

touch patches/memos/.gitkeep

echo "==> Bilderberg 2.0 files written successfully!"