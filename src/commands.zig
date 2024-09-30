const std = @import("std");

const fs = std.fs;
const mem = std.mem;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const index = @import("index.zig");
const objects = @import("objects.zig");
const utils = @import("utils.zig");
const datetime = @import("datetime.zig");

pub const RmOptions = struct {
    cached: bool = false,
    recursive: bool = false,
    dry_run: bool = false,
};

pub const RestoreOptions = struct {
    staged: bool = false,
    source: ?[]const u8 = null,
};

pub const DiffOptions = struct {
    context_lines: usize = 3,
    generate_patch: bool = false,
};

pub fn initOops() !void {
    const cwd = fs.cwd();
    try cwd.makeDir(utils.OOPS_DIR);
    try cwd.makeDir(utils.OOPS_OBJECTS);
    try cwd.makeDir(utils.OOPS_REFS);
}

pub fn commit(allocator: *Allocator, message: []const u8, metadata: std.StringHashMap([]const u8)) !void {
    const parent = try getCurrentCommit(allocator);
    const timestamp = std.time.timestamp();
    const author = try utils.getUsername(allocator);
    defer allocator.free(author);

    var commit_data = std.ArrayList(u8).init(allocator.*);
    defer commit_data.deinit();

    try commit_data.writer().print("parent: {s}\n", .{parent orelse "none"});
    try commit_data.writer().print("timestamp: {d}\n", .{timestamp});
    try commit_data.writer().print("author: {s}\n", .{author});

    var metadata_it = metadata.iterator();
    while (metadata_it.next()) |entry| {
        try commit_data.writer().print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    try commit_data.appendSlice("\n");
    try commit_data.appendSlice(message);
    try commit_data.appendSlice("\n");

    const commit_hash = try objects.writeObject(allocator, commit_data.items);
    try setCurrentCommit(commit_hash);
}

pub fn getCurrentCommit(allocator: *Allocator) !?[]u8 {
    const cwd = fs.cwd();
    const head_path = utils.OOPS_REFS ++ "/HEAD";
    const file = cwd.openFile(head_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    const commit_hash = try file.readToEndAlloc(allocator.*, 1024);
    return commit_hash;
}

pub fn setCurrentCommit(commit_hash: []const u8) !void {
    const cwd = fs.cwd();
    const head_path = utils.OOPS_REFS ++ "/HEAD";
    const file = try cwd.createFile(head_path, .{});
    defer file.close();
    try file.writeAll(commit_hash);
}

pub fn branch(allocator: *Allocator, name: []const u8) !void {
    const cwd = fs.cwd();
    const current_commit = (try getCurrentCommit(allocator)) orelse return error.NoCommits;
    const branch_path = try std.fmt.allocPrint(allocator.*, "{s}/{s}", .{ utils.OOPS_REFS, name });
    const file = try cwd.createFile(branch_path, .{});
    defer file.close();
    try file.writeAll(current_commit);
}

pub fn checkout(allocator: *Allocator, name: []const u8) !void {
    const cwd = fs.cwd();
    var commit_hash: []const u8 = undefined;

    const branch_path = try std.fmt.allocPrint(allocator.*, "{s}/refs/heads/{s}", .{ utils.OOPS_DIR, name });
    defer allocator.free(branch_path);

    if (cwd.openFile(branch_path, .{})) |file| {
        defer file.close();
        commit_hash = try file.readToEndAlloc(allocator.*, 1024);
    } else |_| {
        commit_hash = try allocator.dupe(u8, name);
    }
    defer allocator.free(commit_hash);

    const head_path = try std.fmt.allocPrint(allocator.*, "{s}/HEAD", .{utils.OOPS_DIR});
    defer allocator.free(head_path);

    const head_file = try cwd.createFile(head_path, .{});
    defer head_file.close();
    try head_file.writeAll(commit_hash);

    const current_branch_path = try std.fmt.allocPrint(allocator.*, "{s}/branch", .{utils.OOPS_DIR});
    defer allocator.free(current_branch_path);

    const branch_file = try cwd.createFile(current_branch_path, .{});
    defer branch_file.close();
    try branch_file.writeAll(name);

    std.debug.print("Switched to {s}\n", .{name});
}

pub fn add(allocator: *std.mem.Allocator, pattern: []const u8) !void {
    const ignore_patterns = try utils.readIgnorePatterns(allocator);
    defer ignore_patterns.deinit();

    if (std.mem.eql(u8, pattern, ".")) {
        var cwd = try fs.cwd().openDir(".", .{ .iterate = true });
        defer cwd.close();
        try addDirectory(allocator, cwd, ".", &ignore_patterns);
    } else {
        var dir = try fs.cwd().openDir(".", .{ .iterate = true });
        defer dir.close();
        var walker = try dir.walk(allocator.*);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (utils.globMatch(pattern, entry.path)) {
                if (entry.kind == .directory) {
                    if (!utils.isIgnored(entry.path, ignore_patterns)) {
                        var sub_dir = try dir.openDir(entry.path, .{ .iterate = true });
                        defer sub_dir.close();
                        try addDirectory(allocator, sub_dir, entry.path, &ignore_patterns);
                    } else {
                        std.debug.print("Ignoring directory: {s} (matched ignore pattern)\n", .{entry.path});
                    }
                } else {
                    try addFile(allocator, entry.path, &ignore_patterns);
                }
            }
        }
    }
}

fn addDirectory(allocator: *std.mem.Allocator, dir: fs.Dir, dir_path: []const u8, ignore_patterns: *const std.ArrayListAligned([]const u8, null)) !void {
    var dir_iter = dir.iterate();
    while (try dir_iter.next()) |entry| {
        const entry_path = try std.fs.path.join(allocator.*, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(entry_path);
        if (utils.isIgnored(entry_path, ignore_patterns.*)) {
            std.debug.print("Ignoring {s}: {s} (matched ignore pattern)\n", .{ if (entry.kind == .directory) "directory" else "file", entry_path });
            continue;
        }
        if (entry.kind == .directory) {
            var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer sub_dir.close();
            try addDirectory(allocator, sub_dir, entry_path, ignore_patterns);
        } else {
            try addFile(allocator, entry_path, ignore_patterns);
        }
    }
}

fn addFile(allocator: *Allocator, path: []const u8, ignore_patterns: *const std.ArrayListAligned([]const u8, null)) !void {
    if (utils.isIgnored(path, ignore_patterns.*)) {
        std.debug.print("Ignoring file: {s} (matched ignore pattern)\n", .{path});
        return;
    }
    const file = try fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    var file_type: index.FileType = undefined;
    var content: []const u8 = undefined;
    switch (stat.kind) {
        .file => {
            file_type = .Regular;
            content = try file.readToEndAlloc(allocator.*, 1024 * 1024);
        },
        .sym_link => {
            file_type = .Symlink;
            const max_path_len = std.fs.MAX_PATH_BYTES;
            const buffer = try allocator.alloc(u8, max_path_len);
            defer allocator.free(buffer);
            const link_path = try fs.cwd().readLink(path, buffer);
            content = try allocator.dupe(u8, link_path);
        },
        .directory => {
            file_type = .Directory;
            content = "";
        },
        else => {
            file_type = .Other;
            content = "";
        },
    }
    const hash = try objects.writeObject(allocator, content);
    defer allocator.free(content);
    var idx = try index.readIndex(allocator);
    defer idx.deinit();
    for (idx.items) |*entry| {
        if (mem.eql(u8, entry.path, path)) {
            entry.hash = hash;
            entry.timestamp = stat.mtime;
            entry.mode = stat.mode;
            entry.file_type = file_type;
            try index.writeIndex(idx);
            std.debug.print("Updated file: {s} (hash: {s})\n", .{ path, hash });
            return;
        }
    }
    try idx.append(index.IndexEntry{
        .path = try allocator.dupe(u8, path),
        .hash = hash,
        .timestamp = stat.mtime,
        .mode = stat.mode,
        .file_type = file_type,
    });
    try index.writeIndex(idx);
    std.debug.print("Added file: {s} (hash: {s})\n", .{ path, hash });
}

pub fn rm(allocator: *Allocator, pattern: []const u8, options: RmOptions) !void {
    var idx = try index.readIndex(allocator);
    defer idx.deinit();

    var removed_count: usize = 0;
    var i: usize = 0;
    while (i < idx.items.len) {
        const entry = idx.items[i];
        if (utils.globMatch(pattern, entry.path)) {
            const is_dir = entry.file_type == .Directory;

            if (is_dir and !options.recursive) {
                std.debug.print("Skipping directory: {s} (use --recursive to remove)\n", .{entry.path});
                i += 1;
                continue;
            }

            if (!options.dry_run) {
                if (!options.cached) {
                    if (is_dir) {
                        fs.cwd().deleteTree(entry.path) catch |err| {
                            std.debug.print("Error removing directory {s}: {}\n", .{ entry.path, err });
                            i += 1;
                            continue;
                        };
                    } else {
                        fs.cwd().deleteFile(entry.path) catch |err| {
                            std.debug.print("Error removing file {s}: {}\n", .{ entry.path, err });
                            i += 1;
                            continue;
                        };
                    }
                }
                _ = idx.orderedRemove(i);
            } else {
                std.debug.print("Would remove: {s}\n", .{entry.path});
                i += 1;
            }
            removed_count += 1;
        } else {
            i += 1;
        }
    }

    if (!options.dry_run) {
        try index.writeIndex(idx);
    }

    if (options.dry_run) {
        std.debug.print("Would remove {d} file(s)/director(y/ies)\n", .{removed_count});
    } else {
        std.debug.print("Removed {d} file(s)/director(y/ies)\n", .{removed_count});
    }
}

pub fn restore(allocator: *Allocator, path: []const u8, options: RestoreOptions) !void {
    var idx = try index.readIndex(allocator);
    defer idx.deinit();

    const entry = for (idx.items) |e| {
        if (mem.eql(u8, e.path, path)) {
            break e;
        }
    } else {
        return error.FileNotTracked;
    };

    const content = if (options.source) |source| blk: {
        const source_commit = try objects.parseCommit(allocator, source);
        break :blk try objects.readObject(allocator, source_commit.hash);
    } else if (options.staged) blk: {
        break :blk try objects.readObject(allocator, entry.hash);
    } else blk: {
        const head = try getCurrentCommit(allocator) orelse return error.FileNotTracked;
        const head_commit = try objects.parseCommit(allocator, head);
        break :blk try objects.readObject(allocator, head_commit.hash);
    };
    defer allocator.free(content);

    switch (entry.file_type) {
        .Regular => {
            const file = try fs.cwd().createFile(path, .{});
            defer file.close();
            try file.writeAll(content);
        },
        .Symlink => try fs.cwd().symLink(content, path, .{}),
        .Directory => try fs.cwd().makeDir(path),
        .Other => return error.UnexpectedError,
    }

    std.debug.print("Restored file: {s}\n", .{path});
}

pub fn stash(allocator: *Allocator) !void {
    const current_commit = (try getCurrentCommit(allocator)) orelse return error.NoCommits;
    const stash_data = try std.fmt.allocPrint(allocator.*, "stash: {s}\ntimestamp: {d}", .{ current_commit, std.time.timestamp() });
    const stash_hash = try objects.writeObject(allocator, stash_data);
    std.debug.print("Created stash: {s}\n", .{stash_hash});
}

pub fn log(allocator: *Allocator, branch_name: ?[]const u8, page_size: usize, page_number: usize) !void {
    var current_hash: ?[]const u8 = null;

    if (branch_name) |name| {
        const cwd = fs.cwd();
        const branch_path = try std.fmt.allocPrint(allocator.*, "{s}/{s}", .{ utils.OOPS_REFS, name });
        const file = try cwd.openFile(branch_path, .{});
        defer file.close();
        current_hash = try file.readToEndAlloc(allocator.*, 1024);
    } else {
        current_hash = try getCurrentCommit(allocator);
    }

    if (current_hash == null) return error.NoCommits;

    var commits = std.ArrayList(objects.Commit).init(allocator.*);
    defer commits.deinit();

    while (current_hash) |hash| {
        const log_commit = try objects.parseCommit(allocator, hash);
        try commits.append(log_commit);
        current_hash = log_commit.parent;
    }

    const start_index = page_size * (page_number - 1);
    const end_index = @min(start_index + page_size, commits.items.len);

    for (commits.items[start_index..end_index]) |log_commit| {
        const timestamp: u64 = if (log_commit.timestamp >= 0)
            @intCast(log_commit.timestamp)
        else
            @panic("Negative timestamp encountered");

        const date = std.time.epoch.EpochSeconds{ .secs = timestamp };
        const utc_time = datetime.fromTimestamp(date.secs);

        const formatted_date = try std.fmt.allocPrint(allocator.*, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            utc_time.year,
            @intFromEnum(utc_time.month),
            utc_time.day,
            utc_time.hour,
            utc_time.minute,
            utc_time.second,
        });

        std.debug.print("Commit: {s}\n", .{log_commit.hash});
        std.debug.print("Author: {s}\n", .{log_commit.author});
        std.debug.print("Date: {s}\n", .{formatted_date});
        std.debug.print("Message:\n{s}", .{log_commit.message});

        var metadata_it = log_commit.metadata.iterator();
        while (metadata_it.next()) |entry| {
            std.debug.print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    std.debug.print("Page {d} of {d}\n", .{ page_number, (commits.items.len + page_size - 1) / page_size });
}

pub fn splitLines(allocator: *std.mem.Allocator, content: []const u8) ![]const []const u8 {
    var lines = std.ArrayList([]const u8).init(allocator.*);
    defer lines.deinit();

    var iter = std.mem.split(u8, content, "\n");
    while (iter.next()) |line| {
        try lines.append(try allocator.dupe(u8, line));
    }

    return lines.toOwnedSlice();
}

pub fn diff(allocator: *Allocator, hash1: []const u8, hash2: []const u8, options: DiffOptions) !void {
    const content1 = try objects.readObject(allocator, hash1);
    const content2 = try objects.readObject(allocator, hash2);

    const lines1 = try splitLines(allocator, content1);
    defer allocator.free(lines1);
    const lines2 = try splitLines(allocator, content2);
    defer allocator.free(lines2);

    const lcs = try utils.longestCommonSubsequence(allocator, lines1, lines2);
    defer allocator.free(lcs);

    var i: usize = 0;
    var j: usize = 0;
    var lcs_index: usize = 0;

    const writer = std.io.getStdOut().writer();

    while (i < lines1.len or j < lines2.len) {
        if (lcs_index < lcs.len and i == lcs[lcs_index]) {
            if (options.generate_patch) {
                try writer.print(" {s}\n", .{lines1[i]});
            }
            i += 1;
            j += 1;
            lcs_index += 1;
        } else if (i < lines1.len and (lcs_index == lcs.len or i < lcs[lcs_index])) {
            try writer.print("-{s}\n", .{lines1[i]});
            i += 1;
        } else {
            try writer.print("+{s}\n", .{lines2[j]});
            j += 1;
        }
    }

    if (options.generate_patch) {
        try writer.print("--- {s}\n", .{hash1});
        try writer.print("+++ {s}\n", .{hash2});
    }
}

pub fn status(allocator: *Allocator) !void {
    var idx = try index.readIndex(allocator);
    defer idx.deinit();

    var staged = std.ArrayList([]const u8).init(allocator.*);
    defer staged.deinit();
    var modified = std.ArrayList([]const u8).init(allocator.*);
    defer modified.deinit();
    var deleted = std.ArrayList([]const u8).init(allocator.*);
    defer deleted.deinit();
    var untracked = std.ArrayList([]const u8).init(allocator.*);
    defer untracked.deinit();

    // Check indexed files
    for (idx.items) |entry| {
        const file_status = try utils.getFileStatus(allocator, entry.path, entry);
        switch (file_status) {
            .Modified => try modified.append(entry.path),
            .Deleted => try deleted.append(entry.path),
            else => {},
        }
    }

    // Check for untracked files
    var dir = try fs.cwd().openDir(".", .{});
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (mem.eql(u8, entry.name, utils.OOPS_DIR)) continue;
        const full_path = try std.fs.path.join(allocator.*, &[_][]const u8{ ".", entry.name });
        defer allocator.free(full_path);
        const index_entry = for (idx.items) |idx_entry| {
            if (mem.eql(u8, idx_entry.path, full_path)) break idx_entry;
        } else null;
        const file_status = try utils.getFileStatus(allocator, full_path, index_entry);
        if (file_status == .Untracked) {
            try untracked.append(try allocator.dupe(u8, full_path));
        }
    }

    // Print status
    std.debug.print("On branch {s}\n\n", .{try utils.getCurrentBranch(allocator)});

    if (staged.items.len == 0 and modified.items.len == 0 and deleted.items.len == 0 and untracked.items.len == 0) {
        std.debug.print("nothing to commit, working tree clean\n", .{});
        return;
    }

    if (staged.items.len > 0) {
        std.debug.print("Changes to be committed:\n", .{});
        for (staged.items) |file| {
            std.debug.print("  new file: {s}\n", .{file});
        }
        std.debug.print("\n", .{});
    }

    if (modified.items.len > 0 or deleted.items.len > 0) {
        std.debug.print("Changes not staged for commit:\n", .{});
        for (modified.items) |file| {
            std.debug.print("  modified: {s}\n", .{file});
        }
        for (deleted.items) |file| {
            std.debug.print("  deleted: {s}\n", .{file});
        }
        std.debug.print("\n", .{});
    }

    if (untracked.items.len > 0) {
        std.debug.print("Untracked files:\n", .{});
        for (untracked.items) |file| {
            std.debug.print("  {s}\n", .{file});
        }
        std.debug.print("\n", .{});
    }
}
