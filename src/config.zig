//! Configuration model and loading for Cage.
//!
//! Cage reads a global config file (JSON) and applies it on top of built-in
//! defaults. Per-sandbox CLI flags override the resulting values.
//!
//! Example `~/.config/cage/config.json`:
//! ```json
//! {
//!   "image": "debian-13",
//!   "resources": { "cpu": 2, "memory": "4G" },
//!   "stacks": { "java": false, "node": false, "python": false, "go": false, "rust": false }
//! }
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const default_image = "debian-13";
pub const default_cpu: u32 = 2;
pub const default_memory: u64 = 4 * GiB;
const GiB: u64 = 1024 * 1024 * 1024;

/// Optional development stacks. The base image stays minimal; these can be
/// enabled per config or per sandbox.
pub const Stacks = struct {
    java: bool = false,
    node: bool = false,
    python: bool = false,
    go: bool = false,
    rust: bool = false,
};

/// Fully resolved configuration used to build a sandbox.
pub const Config = struct {
    image: []const u8 = default_image,
    cpu: u32 = default_cpu,
    memory_bytes: u64 = default_memory,
    stacks: Stacks = .{},
};

/// Partial config as parsed from the JSON file. Missing fields fall back to
/// defaults.
pub const FileConfig = struct {
    image: ?[]const u8 = null,
    resources: ?FileResources = null,
    stacks: ?Stacks = null,
};

pub const FileResources = struct {
    cpu: ?u32 = null,
    memory: ?[]const u8 = null,
};

pub const ParseMemoryError = error{InvalidMemory};

/// Parses a human-readable memory size such as `512M`, `4G`, `2048`.
/// Uses binary units (1G = 1024MiB) to match Incus expectations.
pub fn parseMemory(input: []const u8) ParseMemoryError!u64 {
    const trimmed = std.mem.trim(u8, input, " \t");
    if (trimmed.len == 0) return error.InvalidMemory;

    var digits_end: usize = 0;
    while (digits_end < trimmed.len and std.ascii.isDigit(trimmed[digits_end])) : (digits_end += 1) {}
    if (digits_end == 0) return error.InvalidMemory;

    const value = std.fmt.parseUnsigned(u64, trimmed[0..digits_end], 10) catch
        return error.InvalidMemory;

    const suffix = std.mem.trim(u8, trimmed[digits_end..], " \t");
    const mult: u64 = if (suffix.len == 0 or std.ascii.eqlIgnoreCase(suffix, "b"))
        1
    else if (std.ascii.eqlIgnoreCase(suffix, "k") or std.ascii.eqlIgnoreCase(suffix, "kb"))
        1024
    else if (std.ascii.eqlIgnoreCase(suffix, "m") or std.ascii.eqlIgnoreCase(suffix, "mb"))
        1024 * 1024
    else if (std.ascii.eqlIgnoreCase(suffix, "g") or std.ascii.eqlIgnoreCase(suffix, "gb"))
        1024 * 1024 * 1024
    else if (std.ascii.eqlIgnoreCase(suffix, "t") or std.ascii.eqlIgnoreCase(suffix, "tb"))
        1024 * 1024 * 1024 * 1024
    else
        return error.InvalidMemory;

    return std.math.mul(u64, value, mult) catch error.InvalidMemory;
}

/// Applies a parsed partial config on top of `base`.
pub fn apply(base: Config, partial: FileConfig) ParseMemoryError!Config {
    var out = base;
    if (partial.image) |img| {
        if (img.len > 0) out.image = img;
    }
    if (partial.resources) |res| {
        if (res.cpu) |cpu| {
            if (cpu == 0) return error.InvalidMemory;
            out.cpu = cpu;
        }
        if (res.memory) |mem| out.memory_bytes = try parseMemory(mem);
    }
    if (partial.stacks) |stacks| out.stacks = stacks;
    return out;
}

/// Parses JSON config text and applies it on top of the defaults.
pub fn parse(alloc: Allocator, text: []const u8) !Config {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{};
    const partial = try std.json.parseFromSliceLeaky(FileConfig, alloc, text, .{
        .ignore_unknown_fields = true,
    });
    return apply(.{}, partial);
}

/// Resolves the config file path, honouring `$CAGE_CONFIG` then
/// `$XDG_CONFIG_HOME/cage/config.json`, falling back to `~/.config/cage/config.json`.
pub fn resolvePath(alloc: Allocator, environ: *const std.Environ.Map) !?[]const u8 {
    if (environ.get("CAGE_CONFIG")) |p| {
        if (p.len > 0) return try alloc.dupe(u8, p);
    }
    if (environ.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0) return try std.fs.path.join(alloc, &.{ xdg, "cage", "config.json" });
    }
    if (environ.get("HOME")) |home| {
        if (home.len > 0) return try std.fs.path.join(alloc, &.{ home, ".config", "cage", "config.json" });
    }
    return null;
}

/// Loads config from `path`. Returns defaults when the file does not exist.
pub fn load(alloc: Allocator, io: Io, path: []const u8) !Config {
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(alloc, text);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseMemory handles units" {
    try std.testing.expectEqual(@as(u64, 4 * 1024 * 1024 * 1024), try parseMemory("4G"));
    try std.testing.expectEqual(@as(u64, 512 * 1024 * 1024), try parseMemory("512M"));
    try std.testing.expectEqual(@as(u64, 2048), try parseMemory("2048"));
    try std.testing.expectEqual(@as(u64, 1024), try parseMemory("1k"));
}

test "parseMemory rejects garbage" {
    try std.testing.expectError(error.InvalidMemory, parseMemory(""));
    try std.testing.expectError(error.InvalidMemory, parseMemory("abc"));
    try std.testing.expectError(error.InvalidMemory, parseMemory("4X"));
}

test "defaults" {
    const c = Config{};
    try std.testing.expectEqualStrings("debian-13", c.image);
    try std.testing.expectEqual(@as(u32, 2), c.cpu);
    try std.testing.expectEqual(default_memory, c.memory_bytes);
    try std.testing.expect(!c.stacks.node);
}

test "parse applies overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try parse(arena.allocator(),
        \\{"image":"debian-13","resources":{"cpu":4,"memory":"8G"},"stacks":{"node":true}}
    );
    try std.testing.expectEqual(@as(u32, 4), c.cpu);
    try std.testing.expectEqual(@as(u64, 8 * 1024 * 1024 * 1024), c.memory_bytes);
    try std.testing.expect(c.stacks.node);
    try std.testing.expect(!c.stacks.java);
}

test "parse empty text returns defaults" {
    const c = try parse(std.testing.allocator, "   \n");
    try std.testing.expectEqual(@as(u32, 2), c.cpu);
}
