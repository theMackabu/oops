const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const fs = std.fs;

const commands = @import("commands.zig");
const index = @import("index.zig");
const objects = @import("objects.zig");
const utils = @import("utils.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        help();
        return;
    }

    const command = args[1];
    if (mem.eql(u8, command, "init")) {
        try commands.initOops();
        std.debug.print("Initialized oops repository\n", .{});
    } else if (mem.eql(u8, command, "commit")) {
        if (args.len < 3) {
            std.debug.print("Usage: oops commit <message> [key1 value1 key2 value2 ...]\n", .{});
            return;
        }
        var metadata = std.StringHashMap([]const u8).init(allocator);
        var i: usize = 3;
        while (i < args.len) : (i += 2) {
            if (i + 1 < args.len) {
                try metadata.put(args[i], args[i + 1]);
            }
        }
        try commands.commit(&allocator, args[2], metadata);
        std.debug.print("Created commit: {s}\n", .{args[2]});
    } else if (mem.eql(u8, command, "branch")) {
        if (args.len < 3) {
            std.debug.print("Usage: oops branch <name>\n", .{});
            return;
        }
        try commands.branch(&allocator, args[2]);
        std.debug.print("Created branch: {s}\n", .{args[2]});
    } else if (mem.eql(u8, command, "checkout")) {
        if (args.len < 3) {
            std.debug.print("Usage: oops checkout <branch>\n", .{});
            return;
        }
        try commands.checkout(&allocator, args[2]);
        std.debug.print("Switched to branch: {s}\n", .{args[2]});
    } else if (mem.eql(u8, command, "add")) {
        if (args.len < 3) {
            std.debug.print("Usage: oops add <file>\n", .{});
            return;
        }
        commands.add(&allocator, args[2]) catch |err| {
            std.debug.print("Error adding file: {}\n", .{err});
            return;
        };
    } else if (mem.eql(u8, command, "rm")) {
        if (args.len < 3) {
            std.debug.print("Usage: oops rm [--cached] [--recursive] [--dry-run] <pattern>\n", .{});
            return;
        }
        var options = commands.RmOptions{};
        var pattern_index: usize = 2;
        while (pattern_index < args.len - 1) : (pattern_index += 1) {
            if (mem.eql(u8, args[pattern_index], "--cached")) {
                options.cached = true;
            } else if (mem.eql(u8, args[pattern_index], "--recursive")) {
                options.recursive = true;
            } else if (mem.eql(u8, args[pattern_index], "--dry-run")) {
                options.dry_run = true;
            } else {
                break;
            }
        }
        commands.rm(&allocator, args[pattern_index], options) catch |err| {
            std.debug.print("Error removing files: {}\n", .{err});
            return;
        };
    } else if (mem.eql(u8, command, "restore")) {
        if (args.len < 3) {
            std.debug.print("Usage: oops restore [--staged] [--source=<commit>] <file>\n", .{});
            return;
        }
        var options = commands.RestoreOptions{};
        var file_index: usize = 2;
        while (file_index < args.len - 1) : (file_index += 1) {
            if (mem.eql(u8, args[file_index], "--staged")) {
                options.staged = true;
            } else if (mem.startsWith(u8, args[file_index], "--source=")) {
                options.source = args[file_index][9..];
            } else {
                break;
            }
        }
        commands.restore(&allocator, args[file_index], options) catch |err| {
            std.debug.print("Error restoring file: {}\n", .{err});
            return;
        };
    } else if (mem.eql(u8, command, "stash")) {
        try commands.stash(&allocator);
    } else if (mem.eql(u8, command, "log")) {
        var branch_name: ?[]const u8 = null;
        var page_size: usize = 10;
        var page_number: usize = 1;

        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (mem.eql(u8, args[i], "--branch") and i + 1 < args.len) {
                branch_name = args[i + 1];
                i += 1;
            } else if (mem.eql(u8, args[i], "--page-size") and i + 1 < args.len) {
                page_size = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            } else if (mem.eql(u8, args[i], "--page") and i + 1 < args.len) {
                page_number = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            }
        }

        try commands.log(&allocator, branch_name, page_size, page_number);
    } else if (mem.eql(u8, command, "diff")) {
        if (args.len < 4) {
            std.debug.print("Usage: oops diff <commit1> <commit2> [options]\n", .{});
            return;
        }
        var options = commands.DiffOptions{};
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (mem.eql(u8, args[i], "--context-lines") and i + 1 < args.len) {
                options.context_lines = try std.fmt.parseInt(usize, args[i + 1], 10);
                i += 1;
            } else if (mem.eql(u8, args[i], "--generate-patch")) {
                options.generate_patch = true;
            }
        }
        try commands.diff(&allocator, args[2], args[3], options);
    } else if (mem.eql(u8, command, "status")) {
        try commands.status(&allocator);
    } else if (mem.eql(u8, command, "help")) {
        help();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
    }
}

fn help() void {
    std.debug.print(
        \\Usage: oops <command> [args...]
        \\
        \\Available commands:
        \\  init           Initialize an oops repository
        \\  commit         Create a new commit
        \\  branch         Create a new branch
        \\  checkout       Switch to a different branch
        \\  add            Add a file to the staging area
        \\  rm             Remove files from the working tree and index
        \\  restore        Restore a file from a previous commit
        \\  stash          Stash changes in the working directory
        \\  log            Show commit logs
        \\  diff           Show differences between commits
        \\  status         Show the working tree status
        \\  help           Display this help message
        \\
    , .{});
}
