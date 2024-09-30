const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const utils = @import("utils.zig");

pub const Commit = struct {
    hash: []const u8,
    message: []const u8,
    parent: ?[]const u8,
    timestamp: i64,
    author: []const u8,
    metadata: std.StringHashMap([]const u8),
};

pub fn writeObject(allocator: *Allocator, data: []const u8) ![]u8 {
    const hash = try utils.hashObject(allocator, data);
    const path = try std.fs.path.join(allocator.*, &.{ utils.OOPS_OBJECTS, hash });
    defer allocator.free(path);
    const cwd = fs.cwd();
    try cwd.makePath(std.fs.path.dirname(path).?);
    const file = try cwd.createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
    return hash;
}

pub fn readObject(allocator: *Allocator, hash: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator.*, &.{ utils.OOPS_OBJECTS, hash });
    defer allocator.free(path);
    const cwd = fs.cwd();
    const file = try cwd.openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const data = try allocator.alloc(u8, stat.size);
    _ = try file.readAll(data);
    return data;
}

pub fn parseCommit(allocator: *Allocator, commit_hash: []const u8) !Commit {
    const commit_data = try readObject(allocator, commit_hash);
    var lines = mem.split(u8, commit_data, "\n");
    var parent: ?[]const u8 = null;
    var message = std.ArrayList(u8).init(allocator.*);
    defer message.deinit();
    var timestamp: ?i64 = null;
    var author: ?[]const u8 = null;
    var metadata = std.StringHashMap([]const u8).init(allocator.*);

    while (lines.next()) |line| {
        if (line.len == 0) break;

        if (mem.startsWith(u8, line, "parent: ")) {
            parent = try allocator.dupe(u8, line["parent: ".len..]);
        } else if (mem.startsWith(u8, line, "timestamp: ")) {
            timestamp = try std.fmt.parseInt(i64, line["timestamp: ".len..], 10);
        } else if (mem.startsWith(u8, line, "author: ")) {
            author = try allocator.dupe(u8, line["author: ".len..]);
        } else {
            const colon_index = mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = line[0..colon_index];
            const value = line[colon_index + 2 ..];
            try metadata.put(try allocator.dupe(u8, key), try allocator.dupe(u8, value));
        }
    }

    while (lines.next()) |line| {
        try message.appendSlice(line);
        try message.append('\n');
    }

    return Commit{
        .hash = try allocator.dupe(u8, commit_hash),
        .message = try message.toOwnedSlice(),
        .parent = if (mem.eql(u8, parent orelse "", "none")) null else parent,
        .timestamp = timestamp orelse return error.InvalidCommit,
        .author = author orelse return error.InvalidCommit,
        .metadata = metadata,
    };
}
