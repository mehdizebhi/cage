//! Command implementations for the Cage CLI.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const incus = @import("incus.zig");
const ssh = @import("ssh.zig");

pub const Context = struct {
    alloc: Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    environ: *const std.process.Environ.Map,
};

pub const CreateOptions = struct {
    name: []const u8,
    cpu: ?u32 = null,
    memory: ?[]const u8 = null,
    image: ?[]const u8 = null,
    ssh_enabled: bool = true,
};

/// Resolves effective config: file defaults + per-sandbox overrides.
fn resolveConfig(ctx: Context, opts: CreateOptions) !config.Config {
    var cfg: config.Config = .{};
    if (try config.resolvePath(ctx.alloc, ctx.environ)) |path| {
        cfg = try config.load(ctx.alloc, ctx.io, path);
    }
    if (opts.cpu) |cpu| {
        if (cpu == 0) return error.InvalidCpu;
        cfg.cpu = cpu;
    }
    if (opts.memory) |mem| cfg.memory_bytes = try config.parseMemory(mem);
    if (opts.image) |img| {
        if (img.len > 0) cfg.image = img;
    }
    return cfg;
}

fn ensureExists(ctx: Context, name: []const u8) !void {
    if (!try incus.exists(ctx.alloc, ctx.io, name)) return error.NotFound;
}

pub fn create(ctx: Context, opts: CreateOptions) !void {
    const cfg = try resolveConfig(ctx, opts);

    if (opts.name.len == 0) return error.InvalidName;

    try incus.ensureProject(ctx.alloc, ctx.io);

    if (try incus.exists(ctx.alloc, ctx.io, opts.name)) return error.AlreadyExists;

    const image = try incus.resolveImage(ctx.alloc, cfg.image);
    const gib = cfg.memory_bytes / (1024 * 1024 * 1024);
    try ctx.out.print(
        "Creating sandbox '{s}' ({s}, {d} vCPU, {d} GiB RAM)...\n",
        .{ opts.name, cfg.image, cfg.cpu, gib },
    );

    try incus.launch(ctx.alloc, ctx.io, opts.name, image, cfg.cpu, cfg.memory_bytes);

    incus.waitForAgent(ctx.alloc, ctx.io, opts.name, 120_000) catch |err| {
        try ctx.err.print("cage: warning: VM agent not ready ({s})\n", .{@errorName(err)});
    };

    provision(ctx, opts.name, cfg) catch |err| {
        try ctx.err.print("cage: warning: provisioning failed ({s})\n", .{@errorName(err)});
    };

    if (ctx.environ.get("GITHUB_TOKEN")) |token| {
        if (token.len > 0) {
            configureGithub(ctx, opts.name, token) catch |err| {
                try ctx.err.print("cage: warning: GitHub auth failed ({s})\n", .{@errorName(err)});
            };
        }
    }

    if (opts.ssh_enabled) {
        setupSsh(ctx, opts.name) catch |err| {
            try ctx.err.print("cage: warning: SSH setup failed ({s})\n", .{@errorName(err)});
        };
    }

    setupAcp(ctx, opts.name) catch |err| {
        try ctx.err.print("cage: warning: ACP setup failed ({s})\n", .{@errorName(err)});
    };

    try ctx.out.print("Sandbox '{s}' is ready.\n", .{opts.name});
    try ctx.out.print("  Terminal:  cage shell {s}\n", .{opts.name});
    if (opts.ssh_enabled) {
        try ctx.out.print("  SSH:       cage ssh {s}\n", .{opts.name});
        try ctx.out.print("  JetBrains: cage ssh-config {s}  (add the block to ~/.ssh/config)\n", .{opts.name});
    }
}

pub fn list(ctx: Context) !void {
    try incus.ensureProject(ctx.alloc, ctx.io);
    const instances = try incus.list(ctx.alloc, ctx.io);

    if (instances.len == 0) {
        try ctx.out.writeAll("No sandboxes found.\n");
        return;
    }

    try ctx.out.print("{s:<20} {s:<12} {s:<18} {s}\n", .{ "NAME", "STATUS", "IPV4", "TYPE" });
    for (instances) |inst| {
        try ctx.out.print("{s:<20} {s:<12} {s:<18} {s}\n", .{
            inst.name,
            inst.status,
            inst.ipv4 orelse "-",
            inst.type,
        });
    }
}

pub fn shell(ctx: Context, name: []const u8) !void {
    try ensureExists(ctx, name);
    const term = try incus.shell(ctx.alloc, ctx.io, name);
    if (!term.success()) return error.ShellFailed;
}

pub fn start(ctx: Context, name: []const u8) !void {
    try ensureExists(ctx, name);
    try incus.start(ctx.alloc, ctx.io, name);
    try ctx.out.print("Started '{s}'.\n", .{name});
}

pub fn stop(ctx: Context, name: []const u8) !void {
    try ensureExists(ctx, name);
    try incus.stop(ctx.alloc, ctx.io, name);
    try ctx.out.print("Stopped '{s}'.\n", .{name});
}

pub fn remove(ctx: Context, name: []const u8) !void {
    try ensureExists(ctx, name);
    try incus.remove(ctx.alloc, ctx.io, name);
    try ctx.out.print("Removed '{s}'.\n", .{name});
}

/// The base provisioning script, embedded at build time so the installed
/// binary works regardless of the current directory. Override with
/// `$CAGE_BOOTSTRAP` to use a custom script.
const build_options = @import("build_options");
const bootstrap_script = build_options.bootstrap_script;

/// Applies the base provisioning script inside the sandbox. The script is fed
/// to `bash -s` on stdin, so nothing needs to be written to the guest disk.
fn provision(ctx: Context, name: []const u8, cfg: config.Config) !void {
    const script = try bootstrapScript(ctx);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(ctx.alloc);
    try args.appendSlice(ctx.alloc, &.{ "bash", "-s", "--" });
    if (cfg.stacks.node) try args.append(ctx.alloc, "node");
    if (cfg.stacks.python) try args.append(ctx.alloc, "python");
    if (cfg.stacks.java) try args.append(ctx.alloc, "java");
    if (cfg.stacks.go) try args.append(ctx.alloc, "go");
    if (cfg.stacks.rust) try args.append(ctx.alloc, "rust");

    const term = try incus.execInput(ctx.alloc, ctx.io, name, args.items, script);
    if (!term.success()) return error.ProvisionFailed;
}

/// Returns the provisioning script: `$CAGE_BOOTSTRAP` when set, otherwise the
/// embedded default.
fn bootstrapScript(ctx: Context) ![]const u8 {
    if (ctx.environ.get("CAGE_BOOTSTRAP")) |p| {
        if (p.len > 0) {
            return try std.Io.Dir.cwd().readFileAlloc(ctx.io, p, ctx.alloc, .limited(1024 * 1024));
        }
    }
    return bootstrap_script;
}

/// Configures `gh` inside the sandbox using a GitHub token. The token is fed
/// on stdin and never appears in argv, shell history, or `ps` output.
fn configureGithub(ctx: Context, name: []const u8, token: []const u8) !void {
    const payload = try std.fmt.allocPrint(ctx.alloc, "{s}\n", .{token});

    const login = try incus.execInput(
        ctx.alloc,
        ctx.io,
        name,
        &.{ "gh", "auth", "login", "--with-token" },
        payload,
    );
    if (!login.success()) return error.GithubAuthFailed;

    const setup = try incus.execInput(
        ctx.alloc,
        ctx.io,
        name,
        &.{ "gh", "auth", "setup-git" },
        "",
    );
    if (!setup.success()) return error.GithubSetupFailed;

    try ctx.out.writeAll("Configured GitHub authentication.\n");
}

// ---------------------------------------------------------------------------
// SSH + JetBrains integration
// ---------------------------------------------------------------------------

/// Installs the sandbox's SSH public key so key-based root login works.
/// IntelliJ/JetBrains connect over SSH to the sandbox's bridge IP.
fn setupSsh(ctx: Context, name: []const u8) !void {
    const key = try ssh.ensureKeyPair(ctx.alloc, ctx.io, ctx.environ, name);

    const authorized = try std.fmt.allocPrint(ctx.alloc, "{s}\n", .{key.public_key});
    const inject = try incus.execInput(ctx.alloc, ctx.io, name, &.{
        "bash",                                                                                                     "-c",
        "install -d -m 700 /root/.ssh && cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys",
    }, authorized);
    if (!inject.success()) return error.SshSetupFailed;

    try ctx.out.print("Configured SSH key ({s}).\n", .{key.private_path});
}

/// Seeds `~/.jetbrains/acp.json` in the sandbox so JetBrains AI Assistant can
/// launch OpenCode over the Agent Client Protocol, with the IntelliJ MCP server
/// exposed so the agent gets Java/Kotlin code intelligence.
fn setupAcp(ctx: Context, name: []const u8) !void {
    const json = try acpJson(ctx);
    const term = try incus.execInput(ctx.alloc, ctx.io, name, &.{
        "bash",                                                                                                         "-c",
        "install -d -m 700 /root/.jetbrains && cat > /root/.jetbrains/acp.json && chmod 600 /root/.jetbrains/acp.json",
    }, json);
    if (!term.success()) return error.AcpSetupFailed;

    try ctx.out.writeAll("Seeded JetBrains ACP config (/root/.jetbrains/acp.json).\n");
}

const acp_template =
    "{{\n" ++
    "  \"default_mcp_settings\": {{ \"use_custom_mcp\": true, \"use_idea_mcp\": true }},\n" ++
    "  \"agent_servers\": {{\n" ++
    "    \"OpenCode (Sandbox)\": {{\n" ++
    "      \"command\": \"/usr/local/bin/opencode\",\n" ++
    "      \"args\": [\"acp\"],\n" ++
    "      \"env\": {s}\n" ++
    "    }}\n" ++
    "  }}\n" ++
    "}}\n";

fn acpJson(ctx: Context) ![]const u8 {
    if (ctx.environ.get("GEMINI_API_KEY")) |key| {
        if (key.len > 0) {
            const env_field = try std.fmt.allocPrint(ctx.alloc, "{{ \"GEMINI_API_KEY\": \"{s}\" }}", .{key});
            return std.fmt.allocPrint(ctx.alloc, acp_template, .{env_field});
        }
    }
    return std.fmt.allocPrint(ctx.alloc, acp_template, .{"{}"});
}

/// Opens an interactive SSH session to the sandbox.
pub fn sshConnect(ctx: Context, name: []const u8) !void {
    try ensureExists(ctx, name);
    const host = (try incus.getIPv4(ctx.alloc, ctx.io, name)) orelse
        return error.SshNotConfigured;
    const key = try ssh.ensureKeyPair(ctx.alloc, ctx.io, ctx.environ, name);
    const term = try ssh.connect(ctx.alloc, ctx.io, host, key.private_path);
    if (!term.success()) return error.ShellFailed;
}

/// Prints an `~/.ssh/config` block for connecting JetBrains Remote Development
/// to the sandbox.
pub fn sshConfig(ctx: Context, name: []const u8) !void {
    try ensureExists(ctx, name);
    const host = (try incus.getIPv4(ctx.alloc, ctx.io, name)) orelse
        return error.SshNotConfigured;
    const key = try ssh.ensureKeyPair(ctx.alloc, ctx.io, ctx.environ, name);

    const block = try ssh.configBlock(ctx.alloc, name, host, key.private_path);
    try ctx.out.writeAll(block);
    try ctx.out.print(
        "\nAdd the block above to ~/.ssh/config, then in JetBrains Gateway choose\n" ++
            "SSH and select the 'cage-{s}' host. The IDE backend and any ACP agent\n" ++
            "run inside the sandbox.\n",
        .{name},
    );
}
