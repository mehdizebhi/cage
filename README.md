# Cage

A developer-friendly **Zig CLI** for creating and managing isolated **Incus VM**
sandboxes for agentic software development.

Cage is a thin orchestration layer around [Incus](https://linuxcontainers.org/incus/).
Each sandbox is a full VM in a dedicated Incus project named `cage`.

## Status

Early scaffold. Implemented: `create`, `list`, `shell`, `start`, `stop`,
`remove`, base provisioning, and GitHub authentication. See `src/` for details.

## Requirements

- Zig **0.17.0** (the code uses the new `std.Io` / `std.process.Init` APIs)
- Incus with the QEMU driver (`incus`, `qemu-system-x86_64`, `edk2-ovmf`)
- Membership in the `incus-admin` group

## Build

```bash
zig build              # produces zig-out/bin/cage
zig build test         # run unit tests
zig build run -- list  # run without installing
```

## Usage

```bash
# Create a sandbox with defaults (2 vCPU, 4 GiB RAM, debian-13)
cage create my-agent

# Custom resources
cage create my-agent --cpu 4 --memory 8G

# Manage
cage list
cage shell my-agent
cage start my-agent
cage stop my-agent
cage remove my-agent
```

## Configuration

Cage reads a global config file, then applies per-sandbox CLI flags on top.

Search order:

1. `$CAGE_CONFIG`
2. `$XDG_CONFIG_HOME/cage/config.json`
3. `~/.config/cage/config.json`

Missing file means built-in defaults. See `config.example.json`.

```json
{
  "image": "debian-13",
  "resources": { "cpu": 2, "memory": "4G" },
  "stacks": { "java": false, "node": false, "python": false, "go": false, "rust": false }
}
```

Short image names are mapped for the Incus `images:` remote: `debian-13` becomes
`images:debian/13`.

## Provisioning

On create, Cage pushes `provisioning/bootstrap.sh` into the VM and runs it. The
script installs the base tooling (git, gh, curl, jq, ...) and OpenCode, then any
enabled development stacks.

Override the script with `CAGE_BOOTSTRAP=/path/to/script.sh`.

## GitHub authentication

Export a token before creating a sandbox:

```bash
export GITHUB_TOKEN=ghp_...
cage create my-agent
```

Cage runs `gh auth login --with-token` inside the VM, feeding the token on
**stdin**. The token never appears in argv, shell history, VM configuration, or
process listings.

## How it works

```
cage (Zig CLI)
   config  ·  lifecycle  ·  auth
              │
              ▼
            incus CLI
              │
              ▼
        Debian 13 VM (project: cage)
```

Cage shells out to `incus` and parses `--format json` output. It does not
implement its own virtualization or provisioning system.

## Project layout

```
build.zig            build + test steps
src/main.zig         entry point, wiring
src/cli.zig          argument parsing and dispatch
src/commands.zig     lifecycle command implementations
src/config.zig       config model and loader
src/incus.zig        incus CLI wrapper
provisioning/        in-VM bootstrap script
```
