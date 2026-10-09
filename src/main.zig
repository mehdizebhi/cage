const std = @import("std");
const Io = std.Io;

/// Cage version reported by `cage version`.
pub const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const rest = args[1..];
    if (rest.len == 0) {
        try printHelp(out);
    } else if (std.mem.eql(u8, rest[0], "version")) {
        try out.print("cage {s}\n", .{version});
    } else if (std.mem.eql(u8, rest[0], "help") or
        std.mem.eql(u8, rest[0], "--help") or
        std.mem.eql(u8, rest[0], "-h"))
    {
        try printHelp(out);
    } else {
        try out.print("cage: unknown command '{s}'\n\n", .{rest[0]});
        try printHelp(out);
    }

    try out.flush();
}

fn printHelp(w: *Io.Writer) !void {
    try w.writeAll(
        \\cage - manage Incus VM sandboxes for agentic development
        \\
        \\Usage:
        \\  cage <command> [options]
        \\
        \\Commands:
        \\  create <name>   Create a sandbox
        \\  list            List sandboxes
        \\  shell <name>    Open a shell in a sandbox
        \\  start <name>    Start a sandbox
        \\  stop <name>     Stop a sandbox
        \\  remove <name>   Remove a sandbox
        \\  version         Print version
        \\  help            Print this help
        \\
    );
}

test "version is not empty" {
    try std.testing.expect(version.len > 0);
}
