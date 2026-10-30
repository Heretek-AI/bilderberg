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
