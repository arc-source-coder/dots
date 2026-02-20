const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const storage_mod = @import("storage.zig");
const build_options = @import("build_options");

const zeit = @import("zeit");

const Storage = storage_mod.Storage;
const Issue = storage_mod.Issue;
const Status = storage_mod.Status;

const dots_dir = storage_mod.dots_dir;
const default_priority: i64 = 2;
const min_priority: i64 = 0;
const max_priority: i64 = 9;

// Command dispatch table
const Handler = *const fn (Allocator, []const []const u8) anyerror!void;
const Command = struct { names: []const []const u8, handler: Handler };

const commands = [_]Command{
    .{ .names = &.{ "add", "create" }, .handler = cmdAdd },
    .{ .names = &.{ "ls", "list" }, .handler = cmdList },
    .{ .names = &.{ "on", "it" }, .handler = cmdOn },
    .{ .names = &.{ "off", "done" }, .handler = cmdOff },
    .{ .names = &.{ "rm", "delete" }, .handler = cmdRm },
    .{ .names = &.{"show"}, .handler = cmdShow },
    .{ .names = &.{"ready"}, .handler = cmdReady },
    .{ .names = &.{"tree"}, .handler = cmdTree },
    .{ .names = &.{"fix"}, .handler = cmdFix },
    .{ .names = &.{"find"}, .handler = cmdFind },
    .{ .names = &.{"update"}, .handler = cmdUpdate },
    .{ .names = &.{"close"}, .handler = cmdClose },
    .{ .names = &.{"purge"}, .handler = cmdPurge },
    .{ .names = &.{"init"}, .handler = cmdInit },
    .{ .names = &.{ "help", "--help", "-h" }, .handler = cmdHelp },
    .{ .names = &.{ "--version", "-v" }, .handler = cmdVersion },
};

fn findCommand(name: []const u8) ?Handler {
    inline for (commands) |cmd| {
        inline for (cmd.names) |n| {
            if (std.mem.eql(u8, name, n)) return cmd.handler;
        }
    }
    return null;
}

pub fn main() void {
    if (run()) |_| {} else |err| handleError(err);
}

fn run() !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try cmdReady(allocator, &.{});
    } else {
        const cmd = args[1];
        if (findCommand(cmd)) |handler| {
            try handler(allocator, args[2..]);
        } else if (std.mem.eql(u8, cmd, "hook")) {
            fatal("Unknown command: hook\n", .{});
        } else {
            // Quick add: dot "title"
            try cmdAdd(allocator, args[1..]);
        }
    }

    if (stdout_writer) |*writer| {
        try writer.interface.flush();
    }
    if (stderr_writer) |*writer| {
        try writer.interface.flush();
    }
}

fn cmdHelp(_: Allocator, _: []const []const u8) !void {
    return stdout().writeAll(usage);
}

fn cmdVersion(_: Allocator, _: []const []const u8) !void {
    return stdout().print("dots {s} ({s})\n", .{ build_options.version, build_options.git_hash });
}

fn openStorage(allocator: Allocator) !Storage {
    return Storage.open(allocator);
}

// I/O helpers
var stdout_buffer: [4096]u8 = undefined;
var stdout_writer: ?fs.File.Writer = null;
var stderr_buffer: [4096]u8 = undefined;
var stderr_writer: ?fs.File.Writer = null;

fn stdout() *std.Io.Writer {
    if (stdout_writer == null) {
        stdout_writer = fs.File.stdout().writer(&stdout_buffer);
    }
    return &stdout_writer.?.interface;
}

fn stderr() *std.Io.Writer {
    if (stderr_writer == null) {
        stderr_writer = fs.File.stderr().writer(&stderr_buffer);
    }
    return &stderr_writer.?.interface;
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    const w = stderr();
    w.print(fmt, args) catch unreachable;
    w.flush() catch unreachable;
    std.process.exit(1);
}

fn handleError(err: anyerror) noreturn {
    switch (err) {
        error.OutOfMemory => fatal("Out of memory\n", .{}),
        error.FileNotFound => fatal("Missing issue file or directory in .dots\n", .{}),
        error.AccessDenied => fatal("Permission denied\n", .{}),
        error.NotDir => fatal("Expected a directory but found a file\n", .{}),
        error.InvalidFrontmatter => fatal("Invalid issue frontmatter\n", .{}),
        error.InvalidStatus => fatal("Invalid issue status\n", .{}),
        error.InvalidId => fatal("Invalid issue id\n", .{}),
        error.DependencyNotFound => fatal("Dependency not found\n", .{}),
        error.DependencyCycle => fatal("Dependency would create a cycle\n", .{}),
        error.IssueAlreadyExists => fatal("Issue already exists\n", .{}),
        error.ChildrenNotClosed => fatal("Cannot close: children are not all closed\n", .{}),
        error.IssueNotFound => fatal("Issue not found\n", .{}),
        error.AmbiguousId => fatal("Ambiguous issue id\n", .{}),
        error.InvalidTimestamp => fatal("Invalid system time\n", .{}),
        error.TimestampOverflow => fatal("System time out of range\n", .{}),
        error.LocaltimeFailed => fatal("Failed to read local time\n", .{}),
        error.IoError => fatal("I/O error\n", .{}),
        else => fatal("Unexpected internal error (code: {s})\n", .{@errorName(err)}),
    }
}

// ID resolution helper - resolves short ID or exits with error
fn resolveIdOrFatal(storage: *storage_mod.Storage, id: []const u8) []const u8 {
    return storage.resolveId(id) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{id}),
        error.AmbiguousId => fatal("Ambiguous ID: {s}\n", .{id}),
        else => fatal("Error resolving ID: {s}\n", .{id}),
    };
}

fn resolveIdActiveOrFatal(storage: *storage_mod.Storage, id: []const u8) []const u8 {
    return storage.resolveIdActive(id) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{id}),
        error.AmbiguousId => fatal("Ambiguous ID: {s}\n", .{id}),
        else => fatal("Error resolving ID: {s}\n", .{id}),
    };
}

// Status parsing helper
fn parseStatusArg(status_str: []const u8) Status {
    return Status.parse(status_str) orelse fatal("Invalid status: {s}\n", .{status_str});
}

// Arg parsing helper
fn getArg(args: []const []const u8, i: *usize, flag: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, args[i.*], flag) and i.* + 1 < args.len) {
        i.* += 1;
        return args[i.*];
    }
    return null;
}

fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

const usage =
    \\dots - Connect the dots
    \\
    \\Usage: dot [command] [options]
    \\
    \\Commands:
    \\  dot "title" -s <scope>           Quick add a dot
    \\  dot add "title" -s <scope>       Add a dot (-p priority, -d desc, -P parent, -a after)
    \\  dot ls [--status S]              List dots
    \\  dot on <id>                      Start working (turn it on!)
    \\  dot off <id> [-r reason]         Complete ("cross it off")
    \\  dot rm <id>                      Remove a dot
    \\  dot show <id>                    Show dot details
    \\  dot ready                        Show unblocked dots
    \\  dot tree [id]                    Show hierarchy
    \\  dot fix                          Repair missing parents
    \\  dot find "query"                 Search all dots
    \\  dot purge                        Delete archived dots
    \\  dot init                         Initialize .dots directory
    \\
    \\Scope: -s <scope> or DOTS_DEFAULT_SCOPE env var
    \\
    \\Examples:
    \\  dot "Fix the bug" -s app
    \\  dot add "Design API" -p 1 -d "REST endpoints" -s app
    \\  dot add "Implement" -P app-001 -a app-002 -s app
    \\  dot on app-003
    \\  dot off app-003 -r "shipped"
    \\
;

fn gitAddDots(allocator: Allocator) !void {
    // Add .dots to git if in a git repo
    fs.cwd().access(".git", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    // Run git add .dots
    var child = std.process.Child.init(&.{ "git", "add", dots_dir }, allocator);
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                try stderr().print("Warning: git add failed with exit code {d}\n", .{code});
            }
        },
        .Signal => |sig| try stderr().print("Warning: git add killed by signal {d}\n", .{sig}),
        else => try stderr().writeAll("Warning: git add terminated abnormally\n"),
    }
}

fn cmdInit(allocator: Allocator, _: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();
    try gitAddDots(allocator);
}

fn cmdAdd(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot add <title> [options]\n", .{});

    var title: []const u8 = "";
    var description: []const u8 = "";
    var priority: i64 = default_priority;
    var parent: ?[]const u8 = null;
    var after: ?[]const u8 = null;
    var scope: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-p")) |v| {
            const p = std.fmt.parseInt(i64, v, 10) catch fatal("Invalid priority: {s}\n", .{v});
            priority = std.math.clamp(p, min_priority, max_priority);
        } else if (getArg(args, &i, "-d")) |v| {
            description = v;
        } else if (getArg(args, &i, "-P")) |v| {
            parent = v;
        } else if (getArg(args, &i, "-a")) |v| {
            after = v;
        } else if (getArg(args, &i, "-s")) |v| {
            scope = v;
        } else if (title.len == 0 and args[i].len > 0 and args[i][0] != '-') {
            title = args[i];
        }
    }

    if (title.len == 0) fatal("Error: title required\n", .{});
    if (parent != null and after != null and std.mem.eql(u8, parent.?, after.?)) {
        fatal("Error: parent and after cannot be the same issue\n", .{});
    }

    // Resolve scope: -s flag > DOTS_DEFAULT_SCOPE env var > error
    const resolved_scope = scope orelse blk: {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        if (env.get("DOTS_DEFAULT_SCOPE")) |s| {
            break :blk s;
        }
        fatal("Error: scope required (-s <scope> or DOTS_DEFAULT_SCOPE)\n", .{});
    };

    var storage = try openStorage(allocator);
    defer storage.close();

    const id = try storage_mod.nextId(allocator, storage.dots_dir, resolved_scope);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(allocator, &ts_buf);

    // Handle after dependency (blocks)
    var blocks: []const []const u8 = &.{};
    var blocks_buf: [1][]const u8 = undefined;
    var resolved_after: ?[]const u8 = null;
    if (after) |after_id| {
        resolved_after = storage.resolveId(after_id) catch |err| switch (err) {
            error.IssueNotFound => fatal("After issue not found: {s}\n", .{after_id}),
            error.AmbiguousId => fatal("Ambiguous ID: {s}\n", .{after_id}),
            else => return err,
        };
        blocks_buf[0] = resolved_after.?;
        blocks = &blocks_buf;
    }
    defer if (resolved_after) |r| allocator.free(r);

    // Resolve parent ID if provided
    var resolved_parent: ?[]const u8 = null;
    if (parent) |parent_id| {
        resolved_parent = storage.resolveId(parent_id) catch |err| switch (err) {
            error.IssueNotFound => fatal("Parent issue not found: {s}\n", .{parent_id}),
            error.AmbiguousId => fatal("Ambiguous ID: {s}\n", .{parent_id}),
            else => return err,
        };
    }
    defer if (resolved_parent) |p| allocator.free(p);

    const issue: Issue = .{
        .id = id,
        .title = title,
        .description = description,
        .status = .open,
        .priority = priority,
        .issue_type = "task",
        .assignee = null,
        .created_at = now,
        .closed_at = null,
        .close_reason = null,
        .blocks = blocks,
    };

    storage.createIssue(issue, resolved_parent) catch |err| switch (err) {
        error.DependencyNotFound => fatal("Parent or after issue not found\n", .{}),
        error.DependencyCycle => fatal("Dependency would create a cycle\n", .{}),
        else => return err,
    };

    try stdout().print("{s}\n", .{id});
}

fn cmdList(allocator: Allocator, args: []const []const u8) !void {
    var filter_status: ?Status = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| filter_status = parseStatusArg(v);
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.listIssues(filter_status);
    defer storage_mod.freeIssues(allocator, issues);

    try writeIssueList(issues, filter_status == null);
}

fn cmdReady(allocator: Allocator, _: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.getReadyIssues();
    defer storage_mod.freeIssues(allocator, issues);

    try writeIssueList(issues, false);
}

fn writeIssueList(issues: []const Issue, skip_done: bool) !void {
    const w = stdout();
    for (issues) |issue| {
        if (skip_done and issue.status == .closed) continue;
        try w.print("[{s}] {c} {s}\n", .{ issue.id, issue.status.char(), issue.title });
    }
}

fn cmdOn(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot on <id> [id2 ...]\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const results = try storage.resolveIds(args);
    defer storage_mod.freeResolveResults(allocator, results);

    for (results, 0..) |result, i| {
        switch (result) {
            .ok => |id| try storage.updateStatus(id, .active, null, null),
            .not_found => fatal("Issue not found: {s}\n", .{args[i]}),
            .ambiguous => fatal("Ambiguous ID: {s}\n", .{args[i]}),
        }
    }
}

fn cmdOff(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot off <id> [id2 ...] [-r reason]\n", .{});

    var reason: ?[]const u8 = null;
    var ids: std.ArrayList([]const u8) = .{};
    defer ids.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-r")) |v| {
            reason = v;
        } else {
            try ids.append(allocator, args[i]);
        }
    }

    if (ids.items.len == 0) fatal("Usage: dot off <id> [id2 ...] [-r reason]\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const results = try storage.resolveIds(ids.items);
    defer storage_mod.freeResolveResults(allocator, results);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(allocator, &ts_buf);

    for (results, 0..) |result, idx| {
        switch (result) {
            .ok => |id| storage.updateStatus(id, .closed, now, reason) catch |err| switch (err) {
                error.ChildrenNotClosed => fatal("Cannot close {s}: children are not all closed\n", .{id}),
                else => return err,
            },
            .not_found => fatal("Issue not found: {s}\n", .{ids.items[idx]}),
            .ambiguous => fatal("Ambiguous ID: {s}\n", .{ids.items[idx]}),
        }
    }
}

fn cmdRm(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot rm <id> [id2 ...]\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const results = try storage.resolveIds(args);
    defer storage_mod.freeResolveResults(allocator, results);

    for (results, 0..) |result, i| {
        switch (result) {
            .ok => |id| try storage.deleteIssue(id),
            .not_found => fatal("Issue not found: {s}\n", .{args[i]}),
            .ambiguous => fatal("Ambiguous ID: {s}\n", .{args[i]}),
        }
    }
}

fn cmdShow(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot show <id>\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const resolved = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(resolved);

    var iss = try storage.getIssue(resolved) orelse fatal("Issue not found: {s}\n", .{args[0]});
    defer iss.deinit(allocator);

    const w = stdout();
    try w.print("ID:       {s}\nTitle:    {s}\nStatus:   {s}\nPriority: {d}\n", .{
        iss.id,
        iss.title,
        iss.status.display(),
        iss.priority,
    });
    if (iss.description.len > 0) try w.print("Desc:     {s}\n", .{iss.description});
    try w.print("Created:  {s}\n", .{iss.created_at});
    if (iss.closed_at) |ca| try w.print("Closed:   {s}\n", .{ca});
    if (iss.close_reason) |r| try w.print("Reason:   {s}\n", .{r});
}

fn cmdTree(allocator: Allocator, args: []const []const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        const w = stdout();
        try w.writeAll(
            \\Usage: dot tree [id]
            \\
            \\Show dot hierarchy.
            \\
            \\Without arguments: shows all open root dots and their children.
            \\With id: shows that specific dot's tree (including closed children).
            \\
            \\Examples:
            \\  dot tree                    Show all open root dots
            \\  dot tree my-project         Show specific dot and its children
            \\
        );
        return;
    }
    if (args.len > 1) fatal("Usage: dot tree [id]\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const all_issues = try storage.listIssues(null);
    defer storage_mod.freeIssues(allocator, all_issues);

    var status_by_id = try storage.buildStatusMap(all_issues);
    defer status_by_id.deinit();

    const w = stdout();
    if (args.len == 1) {
        const resolved = resolveIdActiveOrFatal(&storage, args[0]);
        defer allocator.free(resolved);

        var root = try storage.getIssue(resolved) orelse fatal("Issue not found: {s}\n", .{args[0]});
        defer root.deinit(allocator);

        try w.print("[{s}] {s} {s}\n", .{ root.id, root.status.symbol(), root.title });

        const children = try storage.getChildrenWithStatusMap(root.id, &status_by_id);
        defer storage_mod.freeChildIssues(allocator, children);

        for (children) |child| {
            const blocked_msg: []const u8 = if (child.blocked) " (blocked)" else "";
            try w.print(
                "  └─ [{s}] {s} {s}{s}\n",
                .{ child.issue.id, child.issue.status.symbol(), child.issue.title, blocked_msg },
            );
        }
        return;
    }

    const roots = try storage.getRootIssues();
    defer storage_mod.freeIssues(allocator, roots);

    for (roots) |root| {
        try w.print("[{s}] {s} {s}\n", .{ root.id, root.status.symbol(), root.title });

        const children = try storage.getChildrenWithStatusMap(root.id, &status_by_id);
        defer storage_mod.freeChildIssues(allocator, children);

        for (children) |child| {
            const blocked_msg: []const u8 = if (child.blocked) " (blocked)" else "";
            try w.print(
                "  └─ [{s}] {s} {s}{s}\n",
                .{ child.issue.id, child.issue.status.symbol(), child.issue.title, blocked_msg },
            );
        }
    }
}

fn cmdFix(allocator: Allocator, _: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    const result = try storage.fixOrphans();

    const w = stdout();
    if (result.folders == 0) {
        try w.writeAll("No fixes needed\n");
        return;
    }
    try w.print("Fixed {d} orphan parent(s), moved {d} file(s)\n", .{ result.folders, result.files });
}

fn cmdFind(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0 or hasFlag(args, "--help") or hasFlag(args, "-h")) {
        const w = stdout();
        try w.writeAll(
            \\Usage: dot find <query>
            \\
            \\Search all dots (open first, then archived).
            \\
            \\Searches: title, description, close-reason, created-at, closed-at
            \\
            \\Examples:
            \\  dot find "auth"      Search for dots mentioning auth
            \\  dot find "2026-01"   Find dots from January 2026
            \\
        );
        return;
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const issues = try storage.searchIssues(args[0]);
    defer storage_mod.freeIssues(allocator, issues);

    const w = stdout();
    for (issues) |issue| {
        if (issue.status != .closed) {
            try w.print("[{s}] {c} {s}\n", .{ issue.id, issue.status.char(), issue.title });
        }
    }
    for (issues) |issue| {
        if (issue.status == .closed) {
            try w.print("[{s}] {c} {s}\n", .{ issue.id, issue.status.char(), issue.title });
        }
    }
}

fn cmdUpdate(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot update <id> [--status S]\n", .{});

    var new_status: ?Status = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| new_status = parseStatusArg(v);
    }

    const status = new_status orelse fatal("--status required\n", .{});

    var storage = try openStorage(allocator);
    defer storage.close();

    const resolved = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(resolved);

    var ts_buf: [40]u8 = undefined;
    const closed_at: ?[]const u8 = if (status == .closed) try formatTimestamp(allocator, &ts_buf) else null;

    storage.updateStatus(resolved, status, closed_at, null) catch |err| switch (err) {
        error.ChildrenNotClosed => fatal("Cannot close: children are not all closed\n", .{}),
        else => return err,
    };
}

fn cmdClose(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot close <id> [--reason R]\n", .{});

    var reason: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--reason")) |v| reason = v;
    }

    var storage = try openStorage(allocator);
    defer storage.close();

    const resolved = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(resolved);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(allocator, &ts_buf);

    storage.updateStatus(resolved, .closed, now, reason) catch |err| switch (err) {
        error.ChildrenNotClosed => fatal("Cannot close: children are not all closed\n", .{}),
        else => return err,
    };
}

fn cmdPurge(allocator: Allocator, _: []const []const u8) !void {
    var storage = try openStorage(allocator);
    defer storage.close();

    try storage.purgeArchive();
    try stdout().writeAll("Archive purged\n");
}

fn formatTimestamp(allocator: Allocator, buf: []u8) ![]const u8 {
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    const local_tz = try zeit.local(allocator, &env);
    defer local_tz.deinit();

    const now = try zeit.instant(.{ .timezone = &local_tz });
    return now.time().bufPrint(buf, .rfc3339);
}
