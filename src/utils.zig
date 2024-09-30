const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const index = @import("index.zig");

pub const OOPS_DIR = ".oops";
pub const OOPS_OBJECTS = OOPS_DIR ++ "/objects";
pub const OOPS_REFS = OOPS_DIR ++ "/refs";
pub const OOPS_INDEX = OOPS_DIR ++ "/index";
pub const OOPS_IGNORE = ".oopsignore";

pub const FileStatus = enum {
    Unmodified,
    Modified,
    Added,
    Deleted,
    Renamed,
    Copied,
    Untracked,
    Directory,
};

pub fn getUsername(allocator: *Allocator) ![]const u8 {
    if (@import("builtin").os.tag == .windows) {
        const username = try std.process.getEnvVarOwned(allocator.*, "USERNAME");
        return username;
    } else {
        const username = try std.process.getEnvVarOwned(allocator.*, "USER");
        return username;
    }
}

pub fn hashObject(allocator: *Allocator, data: []const u8) ![]u8 {
    var hash = std.crypto.hash.Sha1.init(.{});
    hash.update(data);
    var result: [20]u8 = undefined;
    hash.final(&result);
    return try std.fmt.allocPrint(allocator.*, "{s}", .{std.fmt.fmtSliceHexLower(&result)});
}

pub fn readIgnorePatterns(allocator: *Allocator) !ArrayList([]const u8) {
    var patterns = ArrayList([]const u8).init(allocator.*);
    try patterns.append(try allocator.dupe(u8, ".oops"));

    const ignore_content = fs.cwd().readFileAlloc(allocator.*, OOPS_IGNORE, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return patterns,
        else => return err,
    };
    defer allocator.free(ignore_content);

    var lines = mem.split(u8, ignore_content, "\n");
    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t");
        if (trimmed.len > 0 and !mem.startsWith(u8, trimmed, "#")) {
            try patterns.append(try allocator.dupe(u8, trimmed));
        }
    }
    return patterns;
}

pub fn isIgnored(path: []const u8, ignore_patterns: std.ArrayListAligned([]const u8, null)) bool {
    for (ignore_patterns.items) |pattern| {
        if (matchIgnorePattern(path, pattern)) {
            return true;
        }
    }
    return false;
}

fn matchIgnorePattern(path: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOfScalar(u8, pattern, '/') == null) {
        var path_components = std.mem.split(u8, path, "/");
        while (path_components.next()) |component| {
            if (std.mem.eql(u8, component, pattern)) {
                return true;
            }
        }
        return false;
    }

    if (pattern[0] == '/') {
        return std.mem.startsWith(u8, path, pattern[1..]);
    }

    var path_components = std.mem.split(u8, path, "/");
    const pattern_components = std.mem.split(u8, pattern, "/");

    while (path_components.next()) |path_component| {
        var temp_pattern_components = pattern_components;
        var matches = true;
        const pattern_component = temp_pattern_components.next() orelse break;

        if (!std.mem.eql(u8, path_component, pattern_component)) {
            continue;
        }

        while (temp_pattern_components.next()) |next_pattern_component| {
            const next_path_component = path_components.next() orelse {
                matches = false;
                break;
            };
            if (!std.mem.eql(u8, next_path_component, next_pattern_component)) {
                matches = false;
                break;
            }
        }

        if (matches) {
            return true;
        }
    }

    return false;
}

pub fn globMatch(pattern: []const u8, str: []const u8) bool {
    var p_i: usize = 0;
    var s_i: usize = 0;
    var star_p: ?usize = null;
    var star_s: ?usize = null;

    while (s_i < str.len) {
        if (p_i < pattern.len and (pattern[p_i] == str[s_i] or pattern[p_i] == '?')) {
            p_i += 1;
            s_i += 1;
        } else if (p_i < pattern.len and pattern[p_i] == '*') {
            star_p = p_i;
            star_s = s_i;
            p_i += 1;
        } else if (star_p != null) {
            p_i = star_p.? + 1;
            s_i = star_s.? + 1;
            star_s.? += 1;
        } else {
            return false;
        }
    }

    while (p_i < pattern.len and pattern[p_i] == '*') {
        p_i += 1;
    }

    return p_i == pattern.len;
}

pub fn getFileStatus(allocator: *Allocator, path: []const u8, index_entry: ?index.IndexEntry) !FileStatus {
    const file_info = fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return if (index_entry != null) FileStatus.Deleted else FileStatus.Untracked,
        else => return err,
    };

    if (file_info.kind == .directory) {
        return FileStatus.Directory;
    }

    if (index_entry) |entry| {
        if (file_info.mtime != entry.timestamp) {
            const file = try fs.cwd().openFile(path, .{});
            defer file.close();
            const content = try file.readToEndAlloc(allocator.*, 1024 * 1024);
            defer allocator.free(content);
            const new_hash = try hashObject(allocator, content);
            return if (mem.eql(u8, new_hash, entry.hash)) FileStatus.Unmodified else FileStatus.Modified;
        } else {
            return FileStatus.Unmodified;
        }
    } else {
        return FileStatus.Untracked;
    }
}

pub fn getCurrentBranch(allocator: *Allocator) ![]const u8 {
    const current_branch_path = try std.fmt.allocPrint(allocator.*, "{s}/branch", .{OOPS_DIR});
    defer allocator.free(current_branch_path);

    const branch_name = fs.cwd().readFileAlloc(allocator.*, current_branch_path, 1024) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, "detached HEAD"),
        else => return err,
    };

    return branch_name;
}

pub fn longestCommonSubsequence(allocator: *Allocator, a: []const []const u8, b: []const []const u8) ![]const usize {
    const m = a.len;
    const n = b.len;
    var dp = try allocator.alloc([]usize, m + 1);
    defer allocator.free(dp);
    for (dp) |*row| {
        row.* = try allocator.alloc(usize, n + 1);
    }
    defer for (dp) |row| {
        allocator.free(row);
    };

    for (a, 0..) |_, i| {
        for (b, 0..) |_, j| {
            if (mem.eql(u8, a[i], b[j])) {
                dp[i + 1][j + 1] = dp[i][j] + 1;
            } else {
                dp[i + 1][j + 1] = @max(dp[i + 1][j], dp[i][j + 1]);
            }
        }
    }

    var result = std.ArrayList(usize).init(allocator.*);
    var i: usize = m;
    var j: usize = n;
    while (i > 0 and j > 0) {
        if (mem.eql(u8, a[i - 1], b[j - 1])) {
            try result.append(i - 1);
            i -= 1;
            j -= 1;
        } else if (dp[i - 1][j] > dp[i][j - 1]) {
            i -= 1;
        } else {
            j -= 1;
        }
    }

    std.mem.reverse(usize, result.items);
    return result.toOwnedSlice();
}
