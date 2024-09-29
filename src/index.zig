const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const utils = @import("utils.zig");

pub const FileType = enum {
    Regular,
    Symlink,
    Directory,
    Other,
};

pub const IndexEntry = struct {
    path: []const u8,
    hash: []const u8,
    timestamp: i128,
    mode: fs.File.Mode,
    file_type: FileType,
};

pub fn readIndex(allocator: *Allocator) !ArrayList(IndexEntry) {
    var index = ArrayList(IndexEntry).init(allocator.*);
    const index_content = fs.cwd().readFileAlloc(allocator.*, utils.OOPS_INDEX, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return index,
        else => return err,
    };
    defer allocator.free(index_content);

    var lines = mem.split(u8, index_content, "\n");
    while (lines.next()) |line| {
        var fields = mem.split(u8, line, "\t");
        const path = try allocator.dupe(u8, fields.next() orelse continue);
        const hash = try allocator.dupe(u8, fields.next() orelse continue);
        const timestamp = try std.fmt.parseInt(i128, fields.next() orelse continue, 10);
        const mode = try std.fmt.parseInt(u32, fields.next() orelse continue, 8);
        const file_type = try std.meta.intToEnum(FileType, try std.fmt.parseInt(u8, fields.next() orelse continue, 10));
        try index.append(IndexEntry{
            .path = path,
            .hash = hash,
            .timestamp = timestamp,
            .mode = mode,
            .file_type = file_type,
        });
    }
    return index;
}

pub fn writeIndex(index: ArrayList(IndexEntry)) !void {
    const file = try fs.cwd().createFile(utils.OOPS_INDEX, .{});
    defer file.close();
    const writer = file.writer();
    for (index.items) |entry| {
        try writer.print("{s}\t{s}\t{d}\t{d}\t{d}\n", .{
            entry.path,
            entry.hash,
            entry.timestamp,
            entry.mode,
            @intFromEnum(entry.file_type),
        });
    }
}
