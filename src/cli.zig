//! Argument parsing and subcommand dispatch.

const std = @import("std");
const Io = std.Io;
const commands = @import("commands.zig");

pub const version = "0.2.1";

pub fn run(ctx: commands.Context, args: []const []const u8) !u8 {
    if (args.len < 2) {
        try printHelp(ctx.out);
        return 0;
    }

    const cmd = args[1];
    if (eq(cmd, "help") or eq(cmd, "--help") or eq(cmd, "-h")) {
        try printHelp(ctx.out);
        return 0;
    }
    if (eq(cmd, "version") or eq(cmd, "--version") or eq(cmd, "-v")) {
        try ctx.out.print("cage {s}\n", .{version});
        return 0;
    }
    if (eq(cmd, "create")) return createCmd(ctx, args[2..]);
    if (eq(cmd, "list") or eq(cmd, "ls")) return simpleCmd(ctx, commands.list);
    if (eq(cmd, "shell")) return namedCmd(ctx, args[2..], commands.shell, "shell");
    if (eq(cmd, "start")) return namedCmd(ctx, args[2..], commands.start, "start");
    if (eq(cmd, "stop")) return namedCmd(ctx, args[2..], commands.stop, "stop");
    if (eq(cmd, "remove") or eq(cmd, "rm")) return namedCmd(ctx, args[2..], commands.remove, "remove");

    try ctx.err.print("cage: unknown command '{s}'\n\n", .{cmd});
    try printHelp(ctx.err);
    return 2;
}

fn createCmd(ctx: commands.Context, rest: []const []const u8) !u8 {
    if (rest.len == 0) {
        try ctx.err.writeAll("cage: usage: cage create <name> [--cpu N] [--memory SIZE] [--image IMAGE]\n");
        return 2;
    }

    var opts = commands.CreateOptions{ .name = rest[0] };
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        const arg = rest[i];
        if (eq(arg, "--cpu")) {
            i += 1;
            if (i >= rest.len) return usageError(ctx, "--cpu requires a value");
            opts.cpu = std.fmt.parseUnsigned(u32, rest[i], 10) catch
                return usageError(ctx, "invalid --cpu value");
        } else if (eq(arg, "--memory")) {
            i += 1;
            if (i >= rest.len) return usageError(ctx, "--memory requires a value");
            opts.memory = rest[i];
        } else if (eq(arg, "--image")) {
            i += 1;
            if (i >= rest.len) return usageError(ctx, "--image requires a value");
            opts.image = rest[i];
        } else {
            try ctx.err.print("cage: unknown option '{s}'\n", .{arg});
            return 2;
        }
    }

    commands.create(ctx, opts) catch |err| return report(ctx, err, opts.name);
    return 0;
}

fn simpleCmd(ctx: commands.Context, comptime f: fn (commands.Context) anyerror!void) !u8 {
    f(ctx) catch |err| return report(ctx, err, null);
    return 0;
}

fn namedCmd(
    ctx: commands.Context,
    rest: []const []const u8,
    comptime f: fn (commands.Context, []const u8) anyerror!void,
    action: []const u8,
) !u8 {
    if (rest.len == 0) {
        try ctx.err.print("cage: usage: cage {s} <name>\n", .{action});
        return 2;
    }
    f(ctx, rest[0]) catch |err| return report(ctx, err, rest[0]);
    return 0;
}

fn report(ctx: commands.Context, err: anyerror, name: ?[]const u8) !u8 {
    switch (err) {
        error.NotFound => try ctx.err.print("cage: sandbox '{s}' not found\n", .{name orelse "?"}),
        error.AlreadyExists => try ctx.err.print("cage: sandbox '{s}' already exists\n", .{name orelse "?"}),
        error.InvalidName => try ctx.err.writeAll("cage: sandbox name is required\n"),
        error.InvalidCpu => try ctx.err.writeAll("cage: cpu must be greater than zero\n"),
        error.InvalidMemory => try ctx.err.writeAll("cage: invalid memory size (try 4G, 512M)\n"),
        error.IncusFailed => try ctx.err.writeAll("cage: incus command failed\n"),
        error.FileNotFound => try ctx.err.writeAll("cage: 'incus' executable not found in PATH\n"),
        else => try ctx.err.print("cage: {s}\n", .{@errorName(err)}),
    }
    return 1;
}

fn usageError(ctx: commands.Context, msg: []const u8) !u8 {
    try ctx.err.print("cage: {s}\n", .{msg});
    return 2;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn printHelp(w: *Io.Writer) !void {
    try w.writeAll(
        \\cage - manage Incus VM sandboxes for agentic development
        \\
        \\Usage:
        \\  cage <command> [options]
        \\
        \\Commands:
        \\  create <name>   Create a VM sandbox
        \\  list            List sandboxes
        \\  shell <name>    Open a shell in a sandbox
        \\  start <name>    Start a sandbox
        \\  stop <name>     Stop a sandbox
        \\  remove <name>   Remove a sandbox
        \\  version         Print version
        \\  help            Print this help
        \\
        \\Create options:
        \\  --cpu N         Number of vCPUs (default 2)
        \\  --memory SIZE   RAM, e.g. 4G (default 4G)
        \\  --image IMAGE   Base image (default debian-13)
        \\
    );
}
