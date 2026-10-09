//! Command implementations for the Cage CLI.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const config = @import("config.zig");
const incus = @import("incus.zig");

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

    try ctx.out.print("Sandbox '{s}' is ready. Open it with `cage shell {s}`.\n", .{ opts.name, opts.name });
}

pub fn list(ctx: Context) !void {
    try incus.ensureProject(ctx.alloc, ctx.io);
    const instances = try incus.list(ctx.alloc, ctx.io);

    if (instances.len == 0) {
        try ctx.out.writeAll("No sandboxes found.\n");
        return;
    }

    try ctx.out.print("{s:<20} {s:<12} {s}\n", .{ "NAME", "STATUS", "TYPE" });
    for (instances) |inst| {
        try ctx.out.print("{s:<20} {s:<12} {s}\n", .{ inst.name, inst.status, inst.type });
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

/// Applies the base provisioning script inside the sandbox, if one is found.
/// The script is located via `$CAGE_BOOTSTRAP`, then `./provisioning/bootstrap.sh`.
fn provision(ctx: Context, name: []const u8, cfg: config.Config) !void {
    const script = try locateBootstrap(ctx);
    if (script == null) {
        try ctx.err.writeAll("cage: note: no bootstrap script found, skipping provisioning\n");
        return;
    }

    const remote = "/tmp/cage-bootstrap.sh";
    try incus.pushFile(ctx.alloc, ctx.io, name, script.?, remote);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(ctx.alloc);
    try args.appendSlice(ctx.alloc, &.{ "bash", remote });
    if (cfg.stacks.node) try args.append(ctx.alloc, "node");
    if (cfg.stacks.python) try args.append(ctx.alloc, "python");
    if (cfg.stacks.java) try args.append(ctx.alloc, "java");
    if (cfg.stacks.go) try args.append(ctx.alloc, "go");
    if (cfg.stacks.rust) try args.append(ctx.alloc, "rust");

    const out = try incus.exec(ctx.alloc, ctx.io, name, args.items);
    ctx.alloc.free(out);
}

fn locateBootstrap(ctx: Context) !?[]const u8 {
    if (ctx.environ.get("CAGE_BOOTSTRAP")) |p| {
        if (p.len > 0) return try ctx.alloc.dupe(u8, p);
    }
    const default = "provisioning/bootstrap.sh";
    std.Io.Dir.cwd().access(ctx.io, default, .{}) catch return null;
    return default;
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
