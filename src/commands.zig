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

// ---------------------------------------------------------------------------
// Uninstall
// ---------------------------------------------------------------------------

pub const UninstallOptions = struct {
    /// Skip the interactive confirmation prompt.
    yes: bool = false,
    /// Print what would be removed without changing anything.
    dry_run: bool = false,
    /// Keep the `cage` binary (useful when running from a source checkout).
    keep_binary: bool = false,
};

/// Reverses an install: deletes every sandbox and the `cage` Incus project,
/// the per-sandbox SSH keys, the managed `Host cage-*` blocks, the config
/// directory, and finally the `cage` binary itself.
pub fn uninstall(ctx: Context, opts: UninstallOptions) !void {
    if (!opts.yes and !opts.dry_run) {
        if (!try confirmUninstall(ctx, opts)) {
            try ctx.out.writeAll("Aborted.\n");
            return;
        }
    }

    try removeSandboxes(ctx, opts);
    try removeSshKeys(ctx, opts);
    try removeSshConfig(ctx, opts);
    try removeConfigDir(ctx, opts);
    if (!opts.keep_binary) try removeBinary(ctx, opts);

    if (opts.dry_run) {
        try ctx.out.writeAll("\nDry run: nothing was changed.\n");
    } else {
        try ctx.out.writeAll("\nUninstalled cage.\n");
    }
}

/// Prints a summary and reads a yes/no answer from stdin.
fn confirmUninstall(ctx: Context, opts: UninstallOptions) !bool {
    try ctx.out.writeAll(
        "This will permanently:\n" ++
            "  - delete all sandboxes in the Incus project 'cage', then the project\n" ++
            "  - remove ~/.ssh/cage_* keys\n" ++
            "  - remove 'Host cage-*' blocks from ~/.ssh/config\n" ++
            "  - remove the cage config directory\n",
    );
    if (!opts.keep_binary) try ctx.out.writeAll("  - delete the cage binary\n");
    try ctx.out.writeAll("\nContinue? [y/N] ");
    try ctx.out.flush();

    var buffer: [256]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(ctx.io, &buffer);
    const line = reader.interface.takeDelimiterInclusive('\n') catch "";
    const answer = std.mem.trim(u8, line, " \t\r\n");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

/// Deletes every sandbox in the `cage` project, then the project itself.
fn removeSandboxes(ctx: Context, opts: UninstallOptions) !void {
    const present = incus.projectExists(ctx.alloc, ctx.io) catch false;
    if (!present) {
        try ctx.out.writeAll("No Incus project 'cage' to remove.\n");
        return;
    }

    if (incus.list(ctx.alloc, ctx.io)) |instances| {
        for (instances) |inst| {
            if (opts.dry_run) {
                try ctx.out.print("Would remove sandbox '{s}'.\n", .{inst.name});
                continue;
            }
            incus.remove(ctx.alloc, ctx.io, inst.name) catch |err| {
                try ctx.err.print("cage: warning: could not delete '{s}' ({s})\n", .{ inst.name, @errorName(err) });
                continue;
            };
            try ctx.out.print("Removed sandbox '{s}'.\n", .{inst.name});
        }
    } else |err| {
        try ctx.err.print("cage: warning: could not list sandboxes ({s})\n", .{@errorName(err)});
    }

    if (opts.dry_run) {
        try ctx.out.writeAll("Would remove the Incus project 'cage'.\n");
        return;
    }
    incus.deleteProject(ctx.alloc, ctx.io) catch |err| {
        try ctx.err.print("cage: warning: could not delete the 'cage' project ({s})\n", .{@errorName(err)});
        return;
    };
    try ctx.out.writeAll("Removed the Incus project 'cage'.\n");
}

/// Deletes the per-sandbox host keys `~/.ssh/cage_*`.
fn removeSshKeys(ctx: Context, opts: UninstallOptions) !void {
    const home = homeDir(ctx) orelse return;
    const ssh_dir = try std.fs.path.join(ctx.alloc, &.{ home, ".ssh" });

    var dir = std.Io.Dir.cwd().openDir(ctx.io, ssh_dir, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);

    var keys: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |entry| {
        if (std.mem.startsWith(u8, entry.name, "cage_")) {
            try keys.append(ctx.alloc, try std.fs.path.join(ctx.alloc, &.{ ssh_dir, entry.name }));
        }
    }

    for (keys.items) |path| {
        if (opts.dry_run) {
            try ctx.out.print("Would remove SSH key {s}.\n", .{path});
            continue;
        }
        std.Io.Dir.cwd().deleteFile(ctx.io, path) catch |err| {
            try ctx.err.print("cage: warning: could not remove {s} ({s})\n", .{ path, @errorName(err) });
            continue;
        };
        try ctx.out.print("Removed SSH key {s}.\n", .{path});
    }
}

/// Strips the managed `Host cage-*` blocks from `~/.ssh/config`.
fn removeSshConfig(ctx: Context, opts: UninstallOptions) !void {
    const home = homeDir(ctx) orelse return;
    const cfg_path = try std.fs.path.join(ctx.alloc, &.{ home, ".ssh", "config" });

    const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, cfg_path, ctx.alloc, .limited(1024 * 1024)) catch return;
    const cleaned = try stripCageBlocks(ctx.alloc, text);
    if (std.mem.eql(u8, cleaned, text)) return;

    if (opts.dry_run) {
        try ctx.out.print("Would remove 'Host cage-*' blocks from {s}.\n", .{cfg_path});
        return;
    }
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = cfg_path, .data = cleaned });
    try ctx.out.print("Removed 'Host cage-*' blocks from {s}.\n", .{cfg_path});
}

/// Removes the cage config directory (`$XDG_CONFIG_HOME/cage` or `~/.config/cage`).
fn removeConfigDir(ctx: Context, opts: UninstallOptions) !void {
    var path: ?[]const u8 = null;
    if (ctx.environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) path = try std.fs.path.join(ctx.alloc, &.{ xdg, "cage" });
    } else if (homeDir(ctx)) |home| {
        path = try std.fs.path.join(ctx.alloc, &.{ home, ".config", "cage" });
    }
    const dir_path = path orelse return;

    std.Io.Dir.cwd().access(ctx.io, dir_path, .{}) catch return;

    if (opts.dry_run) {
        try ctx.out.print("Would remove {s}.\n", .{dir_path});
        return;
    }
    std.Io.Dir.cwd().deleteTree(ctx.io, dir_path) catch |err| {
        try ctx.err.print("cage: warning: could not remove {s} ({s})\n", .{ dir_path, @errorName(err) });
        return;
    };
    try ctx.out.print("Removed {s}.\n", .{dir_path});
}

/// Deletes the running binary. On Linux the inode stays alive until exit.
fn removeBinary(ctx: Context, opts: UninstallOptions) !void {
    const exe = std.process.executablePathAlloc(ctx.io, ctx.alloc) catch return;

    if (opts.dry_run) {
        try ctx.out.print("Would remove the cage binary ({s}).\n", .{exe});
        return;
    }
    std.Io.Dir.deleteFileAbsolute(ctx.io, exe) catch |err| {
        try ctx.err.print("cage: warning: could not remove {s} ({s})\n", .{ exe, @errorName(err) });
        return;
    };
    try ctx.out.print("Removed the cage binary ({s}).\n", .{exe});
}

fn homeDir(ctx: Context) ?[]const u8 {
    const home = ctx.environ.get("HOME") orelse return null;
    return if (home.len > 0) home else null;
}

/// Returns a copy of `text` without any `Host cage-*` block.
fn stripCageBlocks(alloc: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var skipping = false;
    var i: usize = 0;
    while (i < text.len) {
        const newline = std.mem.indexOfScalarPos(u8, text, i, '\n');
        const end = newline orelse text.len;
        const line = text[i..end];

        if (isHostCageLine(line)) {
            skipping = true;
        } else if (skipping and isBlockBodyLine(line)) {
            // Still inside the managed block; drop the line.
        } else {
            skipping = false;
            try out.appendSlice(alloc, line);
            if (newline != null) try out.append(alloc, '\n');
        }

        i = end + 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Whether `line` is an indented/blank continuation of a preceding block.
fn isBlockBodyLine(line: []const u8) bool {
    return line.len == 0 or line[0] == ' ' or line[0] == '\t';
}

/// Whether `line` is a top-level `Host cage-*` declaration.
fn isHostCageLine(line: []const u8) bool {
    if (line.len <= 4 or line[0] == ' ' or line[0] == '\t') return false;
    if (!std.mem.startsWith(u8, line, "Host")) return false;

    const rest = line[4..];
    if (rest[0] != ' ' and rest[0] != '\t') return false;

    const pattern = std.mem.trim(u8, rest, " \t");
    return std.mem.startsWith(u8, pattern, "cage-");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stripCageBlocks removes managed host blocks" {
    const a = std.testing.allocator;
    const input =
        "Host example\n" ++
        "    HostName example.com\n" ++
        "\n" ++
        "Host cage-agent\n" ++
        "    HostName 10.0.0.1\n" ++
        "    User root\n" ++
        "    IdentityFile /home/u/.ssh/cage_agent\n" ++
        "    IdentitiesOnly yes\n" ++
        "    StrictHostKeyChecking accept-new\n" ++
        "\n" ++
        "Host other\n" ++
        "    HostName other.com\n";
    const cleaned = try stripCageBlocks(a, input);
    defer a.free(cleaned);

    try std.testing.expect(std.mem.indexOf(u8, cleaned, "cage-agent") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "Host example") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "Host other") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "HostName other.com") != null);
}

test "stripCageBlocks leaves unrelated config untouched" {
    const a = std.testing.allocator;
    const input = "Host a\n    HostName a\nHost b\n    HostName b\n";
    const cleaned = try stripCageBlocks(a, input);
    defer a.free(cleaned);
    try std.testing.expectEqualStrings(input, cleaned);
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
