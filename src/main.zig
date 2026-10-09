const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const commands = @import("commands.zig");

pub const version = cli.version;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);

    const ctx = commands.Context{
        .alloc = arena,
        .io = io,
        .out = &stdout_writer.interface,
        .err = &stderr_writer.interface,
        .environ = init.environ_map,
    };

    const code = cli.run(ctx, args) catch |err| {
        try ctx.err.print("cage: {s}\n", .{@errorName(err)});
        try ctx.err.flush();
        std.process.exit(1);
    };

    try ctx.out.flush();
    try ctx.err.flush();

    if (code != 0) std.process.exit(code);
}

test {
    _ = cli;
    _ = commands;
    _ = @import("config.zig");
    _ = @import("incus.zig");
}
