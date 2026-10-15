# Cage

A developer-friendly **Zig CLI** for creating and managing isolated **Incus VM**
sandboxes for agentic software development.

Cage is a thin orchestration layer around [Incus](https://linuxcontainers.org/incus/).
Each sandbox is a full VM in a dedicated Incus project named `cage`.

## Status

Working. Implemented: `create`, `list`, `shell`, `ssh`, `ssh-config`, `start`,
`stop`, `remove`, `uninstall`, base provisioning (including OpenCode), GitHub
authentication, and JetBrains/ACP setup. See `src/` for details.

## Requirements

- Incus with the QEMU driver (`incus`, `qemu-system-x86_64`, `edk2-ovmf`)
- Membership in the `incus-admin` group
- Zig **0.17.0** — only needed to build from source (see below)

## Install

### Prebuilt binary (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mehdizebhi/cage/main/install.sh | sh
```

The installer detects your OS/architecture, downloads the matching release,
verifies its checksum, and installs `cage` to `~/.local/bin`.

Options:

```bash
./install.sh --version v0.1.0     # install a specific tag
./install.sh --dir /usr/local/bin # custom install directory
./install.sh --help
```

Environment equivalents: `CAGE_VERSION`, `CAGE_INSTALL_DIR`.

Supported: Linux on `x86_64` and `aarch64`.

### From source

```bash
git clone https://github.com/mehdizebhi/cage.git
cd cage
zig build              # produces zig-out/bin/cage
zig build test         # run unit tests
zig build run -- list  # run without installing
```

## Releasing

Releases are built by GitHub Actions (`.github/workflows/release.yml`). Pushing
a `v*` tag builds Linux `x86_64` and `aarch64` binaries, generates checksums,
and publishes a GitHub Release.

```bash
git tag v0.1.0
git push origin v0.1.0
```

The tag must match `cage version` output (`src/cli.zig`).

## Usage

```bash
# Create a sandbox with defaults (4 vCPU, 8 GiB RAM, debian-13)
cage create my-agent

# Custom resources / disable the SSH + JetBrains setup
cage create my-agent --cpu 4 --memory 8G
cage create my-agent --no-ssh

# Manage
cage list
cage shell my-agent
cage ssh my-agent
cage start my-agent
cage stop my-agent
cage remove my-agent
```

## Uninstall

`cage uninstall` reverses the installation. It deletes every sandbox in the
`cage` project and the project itself, the `~/.ssh/cage_*` keys, the managed
`Host cage-*` blocks in `~/.ssh/config`, the cage config directory, and finally
the `cage` binary.

```bash
cage uninstall          # asks for confirmation first
cage uninstall --yes    # no prompt
cage uninstall --dry-run        # print what would be removed
cage uninstall --keep-binary    # leave the cage binary in place
```

It does not touch Incus itself, your storage pools, or the default bridge
network.

## JetBrains Remote Development

Cage provisions each sandbox for IntelliJ: it installs `openssh-server`, adds a
per-sandbox SSH key, and seeds `~/.jetbrains/acp.json` so JetBrains AI Assistant
can drive OpenCode over the Agent Client Protocol — with the **integrated
IntelliJ MCP server** enabled for Java/Kotlin code intelligence.

1. **Add the SSH host.** Print a ready-to-use block and append it to
   `~/.ssh/config`:

   ```bash
   cage ssh-config my-agent   # -> Host cage-my-agent ...
   ```

   Verify with `cage ssh my-agent`.

2. **Connect JetBrains Gateway.** *Remote Development → SSH → New Connection*,
   choose the `cage-my-agent` host, pick a project directory, and connect. The
   headless IDE backend runs inside the VM.

3. **Install ACP agents on the Host.** In the connected window:
   *Settings → Plugins (Host)* — install **AI Assistant** (and JetBrains Air).
   ACP agents need no JetBrains AI subscription.

4. **Use OpenCode as an agent.** AI Assistant reads `~/.jetbrains/acp.json` on
   the backend host (the VM). Cage already wrote:

   ```json
   {
     "default_mcp_settings": { "use_custom_mcp": true, "use_idea_mcp": true },
     "agent_servers": {
       "OpenCode (Sandbox)": {
         "command": "/usr/local/bin/opencode",
         "args": ["acp"],
         "env": {}
       }
     }
   }
   ```

   Select **OpenCode (Sandbox)** in AI Chat. Authenticate the agent once by
   running `opencode auth login` inside the sandbox (`cage ssh my-agent`).

   If `GEMINI_API_KEY` is set on the host when you run `cage create`, Cage
   injects it into the ACP config's `env` (the file lives inside the VM).

> Note: JetBrains connects to the sandbox's bridge IP, which Incus assigns via
> DHCP. If a restarted sandbox gets a new address, rerun `cage ssh-config`.

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
  "resources": { "cpu": 4, "memory": "8G" },
  "stacks": { "java": false, "node": false, "python": false, "go": false, "rust": false }
}
```

Short image names are mapped for the Incus `images:` remote: `debian-13` becomes
`images:debian/13`.

## Provisioning

On create, Cage runs `provisioning/bootstrap.sh` inside the VM. The script is
**embedded into the binary** at build time, so it works no matter where `cage`
is installed. It installs the base tooling (git, gh, curl, jq, openssh-server,
...), OpenCode, and any enabled development stacks.

OpenCode v2 is installed from the npm registry (`@opencode/cli-linux-*`), which
is more reliable than the `opencode.ai` endpoint on restricted networks.

Override the script with `CAGE_BOOTSTRAP=/path/to/script.sh`.

### Environment variables

| Variable | Effect |
|---|---|
| `GITHUB_TOKEN` | Configures `gh` inside the sandbox (via stdin) |
| `GEMINI_API_KEY` | Injected into the sandbox's `~/.jetbrains/acp.json` |
| `CAGE_SSH_KEY` | Reuse an existing private key instead of generating `~/.ssh/cage_<name>` |
| `CAGE_BOOTSTRAP` | Use a custom provisioning script |
| `CAGE_CONFIG` | Path to the config file |

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
install.sh           release installer
src/main.zig         entry point, wiring
src/cli.zig          argument parsing and dispatch
src/commands.zig     lifecycle command implementations
src/config.zig       config model and loader
src/incus.zig        incus CLI wrapper
src/ssh.zig          SSH keys, connections, and ssh-config blocks
provisioning/        in-VM bootstrap script (embedded at build time)
.github/workflows/   CI + release automation
```
