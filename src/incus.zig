//! Thin wrapper around the `incus` CLI.
//!
//! Cage intentionally shells out to `incus` rather than talking to the Incus
//! REST API directly. This keeps Cage a small orchestration layer.
//!
//! All cage-managed sandboxes live in the dedicated Incus project `cage`, so
//! they are naturally isolated from the user's other instances.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Dedicated Incus project that holds every sandbox managed by Cage.
pub const project = "cage";

pub const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    term: std.process.Child.Term,

    pub fn deinit(self: CommandResult, alloc: Allocator) void {
        alloc.free(self.stdout);
        alloc.free(self.stderr);
    }
};

/// A sandbox as reported by `incus list`.
pub const Instance = struct {
    name: []const u8,
    status: []const u8 = "",
    type: []const u8 = "",
};

fn buildArgv(alloc: Allocator, args: []const []const u8) !std.ArrayList([]const u8) {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.append(alloc, "incus");
    try argv.appendSlice(alloc, args);
    return argv;
}

/// Runs `incus <args...>` and captures stdout/stderr. Caller owns the result.
pub fn run(alloc: Allocator, io: Io, args: []const []const u8) !CommandResult {
    var argv = try buildArgv(alloc, args);
    defer argv.deinit(alloc);

    const res = try std.process.run(alloc, io, .{ .argv = argv.items });
    return .{ .stdout = res.stdout, .stderr = res.stderr, .term = res.term };
}

/// Runs `incus <args...>`, requiring a zero exit code, and returns stdout.
/// Stderr is released and discarded on success.
pub fn runOk(alloc: Allocator, io: Io, args: []const []const u8) ![]u8 {
    return runOkImpl(alloc, io, args, true);
}

/// Like `runOk` but does not log stderr on failure. Use for expected failures.
pub fn runOkQuiet(alloc: Allocator, io: Io, args: []const []const u8) ![]u8 {
    return runOkImpl(alloc, io, args, false);
}

fn runOkImpl(alloc: Allocator, io: Io, args: []const []const u8, log_errors: bool) ![]u8 {
    const res = try run(alloc, io, args);
    if (!res.term.success()) {
        if (log_errors) {
            std.log.err("incus {s} failed: {s}", .{ args[0], std.mem.trimEnd(u8, res.stderr, "\r\n") });
        }
        alloc.free(res.stdout);
        alloc.free(res.stderr);
        return error.IncusFailed;
    }
    alloc.free(res.stderr);
    return res.stdout;
}

/// Polls `incus exec` until the VM agent inside the sandbox responds.
pub fn waitForAgent(alloc: Allocator, io: Io, name: []const u8, timeout_ms: u64) !void {
    const interval_ms: u64 = 2000;
    const attempts = @max(@as(u64, 1), timeout_ms / interval_ms);
    var i: u64 = 0;
    while (i < attempts) : (i += 1) {
        const res = try run(alloc, io, &.{ "exec", "--project", project, name, "--", "true" });
        const ready = res.term.success();
        res.deinit(alloc);
        if (ready) return;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(interval_ms)), .awake) catch {};
    }
    return error.AgentTimeout;
}

/// Runs `incus <args...>` with inherited stdio (used for interactive shells).
pub fn runInteractive(alloc: Allocator, io: Io, args: []const []const u8) !std.process.Child.Term {
    var argv = try buildArgv(alloc, args);
    defer argv.deinit(alloc);

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return try child.wait(io);
}

/// Ensures the `cage` Incus project exists and that its default profile is
/// usable (root disk + network). New Incus projects start with an empty
/// default profile, so Cage wires up the devices from the host's first
/// storage pool and bridge network.
pub fn ensureProject(alloc: Allocator, io: Io) !void {
    const res = try run(alloc, io, &.{ "project", "show", project });
    defer res.deinit(alloc);

    if (!res.term.success()) {
        const created = runOk(alloc, io, &.{ "project", "create", project }) catch |err| switch (err) {
            error.IncusFailed => {
                // Created concurrently by another process; verify it now exists.
                const check = try run(alloc, io, &.{ "project", "show", project });
                defer check.deinit(alloc);
                if (check.term.success()) return ensureProfileDevices(alloc, io);
                return err;
            },
            else => return err,
        };
        alloc.free(created);
    }

    try ensureProfileDevices(alloc, io);
}

const StoragePool = struct { name: []const u8, driver: []const u8 = "" };
const Network = struct { name: []const u8, type: []const u8 = "" };

/// Adds root and eth0 devices to the cage project's default profile if they
/// are missing. Errors are ignored when the device already exists.
fn ensureProfileDevices(alloc: Allocator, io: Io) !void {
    if (try firstPoolName(alloc, io)) |pool| {
        const pool_arg = try std.fmt.allocPrint(alloc, "pool={s}", .{pool});
        defer alloc.free(pool_arg);
        _ = runOkQuiet(alloc, io, &.{
            "profile", "device", "add",       "default", "root", "disk",
            "path=/",  pool_arg, "--project", project,
        }) catch {};
    }

    if (try firstBridgeName(alloc, io)) |net| {
        const net_arg = try std.fmt.allocPrint(alloc, "network={s}", .{net});
        defer alloc.free(net_arg);
        _ = runOkQuiet(alloc, io, &.{
            "profile", "device",    "add",   "default", "eth0", "nic",
            net_arg,   "--project", project,
        }) catch {};
    }
}

fn firstPoolName(alloc: Allocator, io: Io) !?[]const u8 {
    const stdout = try runOk(alloc, io, &.{ "storage", "list", "--format", "json" });
    defer alloc.free(stdout);
    const pools = try std.json.parseFromSliceLeaky([]StoragePool, alloc, stdout, .{
        .ignore_unknown_fields = true,
    });
    if (pools.len == 0) return null;
    return try alloc.dupe(u8, pools[0].name);
}

fn firstBridgeName(alloc: Allocator, io: Io) !?[]const u8 {
    const stdout = try runOk(alloc, io, &.{ "network", "list", "--format", "json" });
    defer alloc.free(stdout);
    const nets = try std.json.parseFromSliceLeaky([]Network, alloc, stdout, .{
        .ignore_unknown_fields = true,
    });
    for (nets) |net| {
        if (std.mem.eql(u8, net.type, "bridge")) return try alloc.dupe(u8, net.name);
    }
    return null;
}

/// Lists all sandboxes in the `cage` project. Returned strings are owned by
/// `alloc`.
pub fn list(alloc: Allocator, io: Io) ![]Instance {
    const stdout = try runOk(alloc, io, &.{ "list", "--project", project, "--format", "json" });
    defer alloc.free(stdout);

    const parsed = try std.json.parseFromSliceLeaky([]Instance, alloc, stdout, .{
        .ignore_unknown_fields = true,
    });
    const out = try alloc.alloc(Instance, parsed.len);
    for (parsed, 0..) |inst, i| {
        out[i] = .{
            .name = try alloc.dupe(u8, inst.name),
            .status = try alloc.dupe(u8, inst.status),
            .type = try alloc.dupe(u8, inst.type),
        };
    }
    return out;
}

/// Whether a sandbox with `name` exists.
pub fn exists(alloc: Allocator, io: Io, name: []const u8) !bool {
    const res = try run(alloc, io, &.{ "info", "--project", project, name });
    defer res.deinit(alloc);
    return res.term.success();
}

/// Launches a new VM sandbox and applies resource limits.
pub fn launch(
    alloc: Allocator,
    io: Io,
    name: []const u8,
    image: []const u8,
    cpu: u32,
    memory_bytes: u64,
) !void {
    const cpu_kv = try std.fmt.allocPrint(alloc, "limits.cpu={d}", .{cpu});
    defer alloc.free(cpu_kv);
    const mem_value = try formatMemory(alloc, memory_bytes);
    defer alloc.free(mem_value);
    const mem_kv = try std.fmt.allocPrint(alloc, "limits.memory={s}", .{mem_value});
    defer alloc.free(mem_kv);

    _ = try runOk(alloc, io, &.{
        "launch", image,       name,
        "--vm",   "--project", project,
        "-c",     cpu_kv,      "-c",
        mem_kv,   "-c",        "user.cage=true",
    });
}

pub fn start(alloc: Allocator, io: Io, name: []const u8) !void {
    _ = try runOk(alloc, io, &.{ "start", "--project", project, name });
}

pub fn stop(alloc: Allocator, io: Io, name: []const u8) !void {
    _ = try runOk(alloc, io, &.{ "stop", "--project", project, name });
}

pub fn remove(alloc: Allocator, io: Io, name: []const u8) !void {
    _ = try runOk(alloc, io, &.{ "delete", "--project", project, name, "--force" });
}

/// Executes a command inside the sandbox, returning stdout.
pub fn exec(alloc: Allocator, io: Io, name: []const u8, argv: []const []const u8) ![]u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(alloc);
    try args.appendSlice(alloc, &.{ "exec", "--project", project, name, "--" });
    try args.appendSlice(alloc, argv);
    return runOk(alloc, io, args.items);
}

/// Opens an interactive shell inside the sandbox.
pub fn shell(alloc: Allocator, io: Io, name: []const u8) !std.process.Child.Term {
    return runInteractive(alloc, io, &.{ "exec", "--project", project, name, "--", "bash", "-l" });
}

/// Runs a command inside the sandbox, feeding `input` on stdin. Stdout/stderr
/// are inherited. Used to pass secrets (e.g. a GitHub token) without exposing
/// them in argv or process listings.
pub fn execInput(
    alloc: Allocator,
    io: Io,
    name: []const u8,
    argv: []const []const u8,
    input: []const u8,
) !std.process.Child.Term {
    var inner: std.ArrayList([]const u8) = .empty;
    defer inner.deinit(alloc);
    try inner.appendSlice(alloc, &.{ "exec", "--project", project, name, "--" });
    try inner.appendSlice(alloc, argv);

    var args = try buildArgv(alloc, inner.items);
    defer args.deinit(alloc);

    var child = try std.process.spawn(io, .{
        .argv = args.items,
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    });

    var buffer: [4096]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &buffer);
    try writer.interface.writeAll(input);
    try writer.interface.flush();

    // Send EOF so the child stops reading.
    child.stdin.?.close(io);
    child.stdin = null;

    return try child.wait(io);
}

/// Copies a host file into the sandbox. `dst` is absolute inside the instance.
pub fn pushFile(alloc: Allocator, io: Io, name: []const u8, src: []const u8, dst: []const u8) !void {
    const target = try std.fmt.allocPrint(alloc, "{s}{s}", .{ name, dst });
    defer alloc.free(target);
    _ = try runOk(alloc, io, &.{ "file", "push", src, target, "--project", project });
}

/// Maps a config image name to an Incus image reference.
/// `debian-13` becomes `images:debian/13`; fully qualified refs pass through.
pub fn resolveImage(alloc: Allocator, image: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, image, ':') != null) {
        return alloc.dupe(u8, image);
    }
    if (std.mem.indexOfScalar(u8, image, '-')) |dash| {
        return std.fmt.allocPrint(alloc, "images:{s}/{s}", .{ image[0..dash], image[dash + 1 ..] });
    }
    return alloc.dupe(u8, image);
}

/// Formats bytes as an Incus memory string, preferring whole GiB then MiB.
pub fn formatMemory(alloc: Allocator, bytes: u64) ![]const u8 {
    const gib = 1024 * 1024 * 1024;
    const mib = 1024 * 1024;
    if (bytes % gib == 0) {
        return std.fmt.allocPrint(alloc, "{d}GiB", .{bytes / gib});
    }
    if (bytes % mib == 0) {
        return std.fmt.allocPrint(alloc, "{d}MiB", .{bytes / mib});
    }
    return std.fmt.allocPrint(alloc, "{d}", .{bytes});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolveImage maps short names" {
    const a = std.testing.allocator;
    {
        const got = try resolveImage(a, "debian-13");
        defer a.free(got);
        try std.testing.expectEqualStrings("images:debian/13", got);
    }
    {
        const got = try resolveImage(a, "images:ubuntu/24.04");
        defer a.free(got);
        try std.testing.expectEqualStrings("images:ubuntu/24.04", got);
    }
    {
        const got = try resolveImage(a, "debian");
        defer a.free(got);
        try std.testing.expectEqualStrings("debian", got);
    }
}

test "formatMemory" {
    const a = std.testing.allocator;
    {
        const got = try formatMemory(a, 4 * 1024 * 1024 * 1024);
        defer a.free(got);
        try std.testing.expectEqualStrings("4GiB", got);
    }
    {
        const got = try formatMemory(a, 512 * 1024 * 1024);
        defer a.free(got);
        try std.testing.expectEqualStrings("512MiB", got);
    }
}

test "parse list json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSliceLeaky([]Instance, arena.allocator(),
        \\[{"name":"my-agent","status":"Running","type":"virtual-machine"},{"name":"idle","status":"Stopped","type":"virtual-machine"}]
    , .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("my-agent", parsed[0].name);
    try std.testing.expectEqualStrings("Stopped", parsed[1].status);
}
