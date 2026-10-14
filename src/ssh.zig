//! SSH helpers for connecting JetBrains (and humans) to a sandbox.
//!
//! Cage keeps a dedicated keypair per sandbox on the host and installs its
//! public half into the guest's `authorized_keys`. The guest exposes sshd on
//! port 22, which Cage relays to a stable host loopback port via an Incus
//! `proxy` device (so the connection survives the VM's DHCP address changing).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const KeyPair = struct {
    /// Absolute path to the private key on the host.
    private_path: []const u8,
    /// The public key contents (single line, no trailing newline).
    public_key: []const u8,
};

fn runQuiet(alloc: Allocator, io: Io, argv: []const []const u8) !std.process.Child.Term {
    const res = try std.process.run(alloc, io, .{ .argv = argv });
    alloc.free(res.stdout);
    alloc.free(res.stderr);
    return res.term;
}

/// Ensures an SSH keypair exists for `name` and returns it.
///
/// If `$CAGE_SSH_KEY` points to a private key, that key is reused (its `.pub`
/// must exist). Otherwise a dedicated key is generated at
/// `~/.ssh/cage_<name>`.
pub fn ensureKeyPair(
    alloc: Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) !KeyPair {
    if (environ.get("CAGE_SSH_KEY")) |configured| {
        if (configured.len > 0) {
            const priv = try alloc.dupe(u8, configured);
            const pub_path = try std.fmt.allocPrint(alloc, "{s}.pub", .{priv});
            const pub_key = std.Io.Dir.cwd().readFileAlloc(io, pub_path, alloc, .limited(64 * 1024)) catch
                return error.SshKeyNotFound;
            return .{ .private_path = priv, .public_key = std.mem.trimEnd(u8, pub_key, "\r\n") };
        }
    }

    const home = environ.get("HOME") orelse return error.NoHome;
    const ssh_dir = try std.fs.path.join(alloc, &.{ home, ".ssh" });
    std.Io.Dir.cwd().createDirPath(io, ssh_dir) catch return error.SshKeygenFailed;

    const key_name = try std.fmt.allocPrint(alloc, "cage_{s}", .{name});
    const priv = try std.fs.path.join(alloc, &.{ ssh_dir, key_name });
    const pub_path = try std.fmt.allocPrint(alloc, "{s}.pub", .{priv});

    const present = blk: {
        std.Io.Dir.cwd().access(io, pub_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (!present) {
        const comment = try std.fmt.allocPrint(alloc, "cage:{s}", .{name});
        const term = try runQuiet(alloc, io, &.{
            "ssh-keygen", "-t", "ed25519", "-N", "", "-C", comment, "-f", priv, "-q",
        });
        if (!term.success()) return error.SshKeygenFailed;
    }

    const pub_key = std.Io.Dir.cwd().readFileAlloc(io, pub_path, alloc, .limited(64 * 1024)) catch
        return error.SshKeyReadFailed;
    return .{ .private_path = priv, .public_key = std.mem.trimEnd(u8, pub_key, "\r\n") };
}

/// Opens an interactive SSH session to the sandbox at `host`.
pub fn connect(
    alloc: Allocator,
    io: Io,
    host: []const u8,
    key_path: []const u8,
) !std.process.Child.Term {
    const target = try std.fmt.allocPrint(alloc, "root@{s}", .{host});
    defer alloc.free(target);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{
        "ssh",
        "-i",
        key_path,
        "-o",
        "StrictHostKeyChecking=accept-new",
        target,
    });

    var child = try std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    return try child.wait(io);
}

/// Builds an `~/.ssh/config` block for use by JetBrains Remote Development.
pub fn configBlock(
    alloc: Allocator,
    name: []const u8,
    host: []const u8,
    key_path: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        alloc,
        "Host cage-{s}\n" ++
            "    HostName {s}\n" ++
            "    User root\n" ++
            "    IdentityFile {s}\n" ++
            "    IdentitiesOnly yes\n" ++
            "    StrictHostKeyChecking accept-new\n",
        .{ name, host, key_path },
    );
}

test "configBlock contains expected fields" {
    const a = std.testing.allocator;
    const block = try configBlock(a, "agent", "10.227.127.101", "/home/u/.ssh/cage_agent");
    defer a.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "Host cage-agent\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "HostName 10.227.127.101\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "User root\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "IdentityFile /home/u/.ssh/cage_agent\n") != null);
}
