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
