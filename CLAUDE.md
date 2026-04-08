# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A CNPG-I (CloudNativePG Interoperability) plugin that automatically hibernates inactive PostgreSQL clusters. Two components:

- **Plugin** (`cmd/plugin/`) - GRPC server that implements the CNPG-I Lifecycle capability. Injects a sidecar container into PostgreSQL pods via lifecycle hooks.
- **Sidecar** (`cmd/sidecar/`) - Runs alongside PostgreSQL in the primary pod. Monitors database connections, hibernates the cluster after configurable inactivity, and pauses scheduled backups during hibernation. Replicas run the sidecar passively until promoted.

## Build Commands

```bash
make build              # Build plugin and sidecar binaries
make test               # Run tests: go test -timeout 10m -race -cover -failfast ./...
make lint               # golangci-lint v2.1.0
make build-images-dev   # Build both container images (nerdctl, k8s.io namespace)
make deploy-dev         # Build images + deploy dev manifest to current cluster
make manifest           # Generate production Kubernetes manifest
make manifest-dev       # Generate dev manifest (local images, debug logging)
```

Run a single test:
```bash
go test -timeout 10m -race -cover -failfast ./internal/sidecar -run TestScaleToZero
```

Local container builds use `nerdctl --namespace k8s.io` for Rancher Desktop compatibility.

## Architecture

```
cmd/plugin/plugin.go          Entry point: GRPC server via pluginhelper
cmd/sidecar/sidecar.go        Entry point: cobra CLI for sidecar process

internal/plugin/identity/      Identity service (plugin metadata, capabilities, readiness)
internal/plugin/lifecycle/     Lifecycle hook: intercepts Pod creation, injects sidecar container
internal/sidecar/              Core logic: activity monitoring, hibernation, switchover handling
internal/postgres/             Connection pooling and query utilities (pgx)
internal/config/               Plugin configuration with resource defaults

pkg/metadata/                  Version info injected via ldflags

kubernetes/base/               Kustomize base (production resources)
kubernetes/overlays/dev/       Dev overlay (local images, debug log level)
```

**Key flow**: CNPG operator creates a Pod -> lifecycle hook fires -> plugin patches the Pod spec to add sidecar container -> sidecar monitors `pg_stat_activity` -> after inactivity threshold, sets `cnpg.io/hibernation` annotation -> CNPG scales cluster to zero.

## Cluster Annotations

- `xata.io/scale-to-zero-enabled` - Enable/disable per cluster (default: false)
- `xata.io/scale-to-zero-inactivity-minutes` - Minutes before hibernation (default: 30)

## Linting Rules

- `fmt.Print*` is forbidden -- use structured logging (`log.FromContext`)
- Use `fmt.Errorf` with `%w` for error wrapping, not `pkg/errors`
- `gofumpt` formatter is enforced
- `goconst` numbers check is enabled (but disabled in test files)
- See `.golangci.yml` for the full linter set

## Key Dependencies

- `cnpg-i` / `cnpg-i-machinery` - CNPG plugin framework (GRPC, TLS, helpers)
- `cloudnative-pg` - CNPG API types
- `pgx/v5` - PostgreSQL driver for activity monitoring
- `controller-runtime` - Kubernetes client and manager
- `cobra` / `viper` - CLI and config

## Container Images

- Plugin: `ghcr.io/melderan/cnpg-i-scale-to-zero`
- Sidecar: `ghcr.io/melderan/cnpg-i-scale-to-zero-sidecar`
- Sidecar image is configurable via `SIDECAR_IMAGE` env var or `--sidecar-image` flag
