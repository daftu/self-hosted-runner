# Self-Hosted GitHub Actions Runner

Dockerized GitHub Actions self-hosted runners for Linux (x64) and macOS (ARM64). Deploy in minutes, scale with replicas, deregister cleanly on shutdown.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/youssefbrr/self-hosted-runner?style=social)](https://github.com/youssefbrr/self-hosted-runner/stargazers)

---

## Quick Start

```sh
git clone https://github.com/youssefbrr/self-hosted-runner.git
cd self-hosted-runner
cp .env.example .env        # fill in REPO, REG_TOKEN, NAME
```

**Linux (x64)**
```sh
docker-compose -f docker/linux/docker-compose.yml up -d
```

**macOS / ARM64**
```sh
docker-compose -f docker/mac/docker-compose.yml up -d
```

> **REG_TOKEN expires after 1 hour.** It is needed only for the first registration
> of each new replica. Existing replicas reconnect from their persistent local
> state, so an image rebuild does not require a fresh token.

---

## Arcane GitOps (Linux)

Use the Arcane-specific Compose file instead of the normal Linux file:

- **Compose path:** `docker/linux/docker-compose.arcane.yml`
- **Sync entire directory:** enabled
- **Image:** `self-hosted-runner:local`, built manually on the Docker host managed by Arcane

The initial Git Sync deliberately creates the project with `RUNNER_REPLICAS=0`.
It therefore passes Arcane's Compose validation without requiring a `.env` file
or storing a GitHub registration token in Git.

After that first sync succeeds, set these values in the GitOps project's managed
environment in Arcane:

```env
REPO=owner/repository
REG_TOKEN=github_registration_token
NAME=arcane-runner
LABELS=self-hosted,linux,x64
RUNNER_REPLICAS=2
```

Set `RUNNER_REPLICAS` to the desired number only after the required variables
are present. Every replica receives separate persistent Docker volumes, so later
image recreates reuse its GitHub registration state. Keep `REG_TOKEN` only in
Arcane; it is needed only when a new replica registers.

Arcane always disables the runner's in-container self-update. Rebuild the local
image and let Arcane recreate the containers when upgrading the runner version.

---

## Pre-built Image vs Local Build

Both variants support pre-built images from GHCR. By default, `docker-compose up` pulls the pre-built image — no build step required.

| Variant | Image | Tag |
|---------|-------|-----|
| **Linux (x64)** | `ghcr.io/youssefbrr/self-hosted-runner` | `latest` |
| **macOS / ARM64** | `ghcr.io/youssefbrr/self-hosted-runner` | `latest-arm64` |

| Mode | How | When to use |
|------|-----|-------------|
| **Pre-built** (default) | Just run `docker-compose up` | Quick setup, no customization needed |
| **Local build** | Uncomment `build: .` in the compose file | Custom Dockerfile changes, runner version overrides |

---

## Features

- **Zero-config start** — set 3 env vars and run
- **Persistent registration** — every replica keeps its own GitHub identity across image rebuilds
- **Scalable** — Linux defaults to 2 replicas; tune with `RUNNER_REPLICAS` or `--scale`
- **Isolated storage** — Docker gives every replica its own state, work, and diagnostic volumes
- **Docker-in-Docker** — macOS image mounts the Docker socket for nested builds
- **GitHub CLI** — `gh` pre-installed from official repos on both variants
- **Docker CLI** — official Docker CE CLI with buildx and compose plugins
- **Healthchecks** — built-in `pgrep run.sh` health monitoring on both variants

---

## Architecture

```
docker/
├── linux/          Ubuntu 24.04, x64, runner v2.331.0
│   ├── Dockerfile        user: docker, workdir: /home/docker/actions-runner
│   ├── docker-compose.yml  2 replicas · 0.5 CPU · 512M each
│   └── start.sh
└── mac/            Ubuntu 24.04, ARM64, runner v2.331.0
    ├── Dockerfile        user: runner, workdir: /home/runner/actions-runner
    ├── docker-compose.yml  1 replica · 1 CPU · 1G · Docker socket mounted
    └── start.sh
```

Both `start.sh` scripts: configure via `config.sh` only when their own persistent
state is empty, then execute `run.sh`. SIGINT/SIGTERM stops the listener without
removing the runner registration.

---

## Configuration

Copy `.env.example` to `.env` and set your values. The `.env` file is gitignored.

### Required

| Variable | Description |
|----------|-------------|
| `REPO` | `owner/repo` for repo-level or `owner` for org-level runners |
| `REG_TOKEN` | Registration token from GitHub Settings; only needed for a new replica (expires in 1 hour) |
| `NAME` | Base display name; a container ID suffix makes every replica unique |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `LABELS` | _(none)_ | Comma-separated labels, e.g. `self-hosted,linux,x64,gpu` |
| `RUNNER_GROUP` | _(default)_ | Runner group name — org/enterprise only |
| `WORK_DIR` | `_work` | Workspace directory inside the container |
| `EPHEMERAL` | `false` | Unsupported by persistent runner images; must remain `false` |
| `DISABLE_AUTO_UPDATE` | `true` | Defaults to `true`; rebuild the image to upgrade the runner |
| `RUNNER_REPLICAS` | Linux: `2`, macOS: `1` | Number of persistent replicas started by Compose |

### Override Runner Version

```sh
docker build --build-arg RUNNER_VERSION=2.332.0 -t custom-github-runner:latest ./docker/linux
```

---

## Registering to an Organization

Set `REPO` to just the org name:

```env
REPO=my-org
```

The runner will register at org level and be available to all repositories in that org.

---

## Workflows Example

Reference your runner in any workflow file:

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on self-hosted runner"
```

Use your custom labels to target specific runners:

```yaml
runs-on: [self-hosted, linux, gpu]
```

---

## Scaling

Set the desired replica count in `.env`, or override it for one launch. GitHub
will distribute jobs across all registered runners automatically.

```env
RUNNER_REPLICAS=4
```

```sh
RUNNER_REPLICAS=4 docker compose -f docker/linux/docker-compose.yml up -d --build
```

## Persistent replicas

Each runner image declares anonymous Docker volumes for its registration state,
workspace, and diagnostics. Docker Compose assigns a distinct set to every
replica, so `runner-1` and `runner-2` never share credentials or a GitHub runner
identity.

When `docker compose up -d --build` recreates containers after an image change,
Compose reattaches those volumes. Existing replicas therefore start directly with
`run.sh`; `REG_TOKEN` can be expired or absent after the first registration.

Use normal Compose updates to preserve state:

```sh
docker compose -f docker/linux/docker-compose.yml up -d --build
```

Do not use `--renew-anon-volumes` (`-V`) for an update: it intentionally creates
new volumes and every affected replica will need registration again. Likewise,
`docker compose down` is a teardown operation; Docker cannot automatically attach
anonymous volumes to the next `up`. If a runner must be permanently retired,
remove it in GitHub and then run `docker compose down -v` to delete its volumes.

`EPHEMERAL=true` is intentionally rejected by the persistent image because an
ephemeral runner deregisters after one job and cannot be safely restarted from
saved state.

---

## Publishing Images

GitHub Actions workflows automatically build and publish both images to GHCR on version tag pushes (`v*`).

```sh
git tag v1.0.0
git push origin v1.0.0
```

| Image | Tag | Platform |
|-------|-----|----------|
| `ghcr.io/<owner>/self-hosted-runner` | `latest` / `v1.0.0` | linux/amd64 |
| `ghcr.io/<owner>/self-hosted-runner` | `latest-arm64` / `v1.0.0-arm64` | linux/arm64 |

---

## Troubleshooting

**Runner doesn't appear in GitHub Settings**
- Check `REG_TOKEN` — it expires after 1 hour. Generate a new one.
- Verify `REPO` format: `owner/repo` (no leading slash, no trailing slash).

**Logs**
```sh
docker-compose -f docker/linux/docker-compose.yml logs -f
```

**Health status**
```sh
docker-compose -f docker/linux/docker-compose.yml ps
```

**Runner stuck / won't deregister**
```sh
docker-compose -f docker/linux/docker-compose.yml down
```
Normal shutdown leaves the runner registered as offline. To permanently remove
one, use GitHub → Settings → Actions → Runners → Remove (or Force remove if the
container is no longer available), then delete the corresponding Compose volumes.

---

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability reporting policy.

Key practices in this project:
- Runners execute as non-root users (`docker` on Linux, `runner` on ARM64)
- Secrets live in `.env` (gitignored) — never hardcoded in compose files
- `REG_TOKEN` is used only at initial registration; it is not stored in runner state
- Persistent state contains runner credentials and is isolated in a Docker volume per replica

---

## Contributing

Contributions welcome. Please:

1. Fork the repo and create a branch from `main`
2. Keep changes scoped — one feature or fix per PR
3. Test your change by actually spinning up the container
4. Open a pull request with a clear description of what and why

For bugs or feature requests, [open an issue](https://github.com/youssefbrr/self-hosted-runner/issues).

---

## License

[MIT](LICENSE) — use freely, attribution appreciated.
