const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;

const issue_mod = @import("Issue.zig");
const storage_mod = @import("Storage.zig");
const build_options = @import("build_options");

const Issue = issue_mod.Issue;
const Status = issue_mod.Status;
const Storage = storage_mod.Storage;

const dots_dir = storage_mod.dots_dir;
const default_priority = issue_mod.default_priority;

const min_priority: i64 = 0;
const max_priority: i64 = 9;

// Command dispatch table
const Handler = *const fn (Allocator, []const []const u8) anyerror!void;
const Command = struct { names: []const []const u8, handler: Handler };

const cmds = [_]Command{
    .{ .names = &.{ "open", "create" }, .handler = cmdOpen },
    .{ .names = &.{ "list", "ls" }, .handler = cmdList },
    .{ .names = &.{"start"}, .handler = cmdStart },
    .{ .names = &.{"close"}, .handler = cmdClose },
    .{ .names = &.{ "rm", "delete" }, .handler = cmdRm },
    .{ .names = &.{"show"}, .handler = cmdShow },
    .{ .names = &.{"ready"}, .handler = cmdReady },
    .{ .names = &.{"block"}, .handler = cmdBlock },
    .{ .names = &.{"unblock"}, .handler = cmdUnblock },
    .{ .names = &.{"update"}, .handler = cmdUpdate },
    .{ .names = &.{"purge"}, .handler = cmdPurge },
    .{ .names = &.{"init"}, .handler = cmdInit },
};

fn findCommand(name: []const u8) ?Handler {
    inline for (cmds) |cmd| {
        inline for (cmd.names) |n| {
            if (std.mem.eql(u8, name, n)) return cmd.handler;
        }
    }
    return null;
}

pub fn dispatch(allocator: Allocator, args: []const []const u8) !void {
    defer if (stdout_writer) |*w| w.interface.flush() catch {};
    defer if (stderr_writer) |*w| w.interface.flush() catch {};

    if (args.len < 2) return printHelp(stdout());

    const cmd = args[1];

    const help_cmds: [3][]const u8 = .{ "help", "--help", "-h" };
    for (help_cmds) |h| {
        if (std.mem.eql(u8, cmd, h)) return printHelp(stdout());
    }

    const version_cmds: [2][]const u8 = .{ "--version", "-v" };
    for (version_cmds) |v| {
        if (std.mem.eql(u8, cmd, v)) return printVersion(stdout());
    }

    if (findCommand(cmd)) |handler| {
        try handler(allocator, args[2..]);
    } else {
        fatal("Unknown command: {s}\n", .{cmd});
    }
}

// --- I/O helpers ---

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

// --- Arg parsing helpers ---

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

fn parseStatusArg(status_str: []const u8) Status {
    return Status.parse(status_str) orelse fatal("Invalid status: {s}\n", .{status_str});
}

// ID resolution helper
fn resolveIdOrFatal(storage: *Storage, id: []const u8) []const u8 {
    return storage.resolveId(id) catch |err| switch (err) {
        error.IssueNotFound => fatal("Issue not found: {s}\n", .{id}),
        error.AmbiguousId => fatal("Ambiguous ID: {s}\n", .{id}),
        else => fatal("Error resolving ID: {s}\n", .{id}),
    };
}

fn formatTimestamp(buf: []u8) ![]const u8 {
    const ts: u64 = @intCast(std.time.timestamp());
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = ts };

    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

// --- Commands ---

fn printHelp(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\dots - A lightweight issue tracker with first-class dependency support
        \\
        \\Usage: dot [command] [options]
        \\
        \\Commands:
        \\  dot open "title" -s <scope>            Open a dot (-p priority, -d desc)
        \\  dot list [scope]                       Show scopes and issues
        \\  dot start <id>                         Start working on a dot
        \\  dot close <id|scope> [...] [-r reason] Close dots by id or scope
        \\  dot rm <id>                            Remove a dot
        \\  dot show <id>                          Show dot details and dependencies
        \\  dot ready                              Show unblocked dots
        \\  dot block <id> <blocker-id>            Mark id as blocked by blocker-id
        \\  dot unblock <id> <blocker-id>          Remove blocking relationship
        \\  dot purge                              Delete archived dots
        \\  dot init                               Initialize .dots directory
        \\
        \\Scope: -s <scope> or DOTS_DEFAULT_SCOPE env var
        \\
        \\Examples:
        \\  dot open "Design API" -p 1 -d "REST endpoints" -s app
        \\  dot start app-003
        \\  dot close app-003 -r "shipped"
        \\  dot block app-002 app-001
        \\  dot unblock app-002 app-001
        \\
    );
}

fn printVersion(w: *std.Io.Writer) !void {
    try w.print("dots {s}\n", .{build_options.version});
}

fn gitAddDots(allocator: Allocator) !void {
    fs.cwd().access(".git", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

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
    var storage = try Storage.open(allocator);
    defer storage.close();
    try gitAddDots(allocator);
}

fn cmdOpen(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot open <title> [options]\n", .{});

    var title: []const u8 = "";
    var description: []const u8 = "";
    var priority: i64 = default_priority;
    var scope: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-p")) |v| {
            const p = std.fmt.parseInt(i64, v, 10) catch fatal("Invalid priority: {s}\n", .{v});
            priority = std.math.clamp(p, min_priority, max_priority);
        } else if (getArg(args, &i, "-d")) |v| {
            description = v;
        } else if (getArg(args, &i, "-s")) |v| {
            scope = v;
        } else if (title.len == 0 and args[i].len > 0 and args[i][0] != '-') {
            title = args[i];
        }
    }

    if (title.len == 0) fatal("Error: title required\n", .{});

    const resolved_scope = scope orelse blk: {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        if (env.get("DOTS_DEFAULT_SCOPE")) |s| {
            break :blk s;
        }
        fatal("Error: scope required (-s <scope> or DOTS_DEFAULT_SCOPE)\n", .{});
    };

    var storage = try Storage.open(allocator);
    defer storage.close();

    const id = try storage_mod.nextId(allocator, storage.dots_dir, resolved_scope);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    const issue: Issue = .{
        .id = id,
        .title = title,
        .description = description,
        .status = .open,
        .priority = priority,
        .created_at = now,
        .closed_at = null,
        .close_reason = null,
        .blockers = &.{},
    };

    try storage.createIssue(issue);
    try stdout().print("{s}\n", .{id});
}

fn cmdReady(allocator: Allocator, _: []const []const u8) !void {
    var storage = try Storage.open(allocator);
    defer storage.close();

    const issues = try storage.getReadyIssues();
    defer issue_mod.freeIssues(allocator, issues);

    const w = stdout();
    for (issues) |issue| {
        try w.print("[{s}] {c} {s}\n", .{ issue.id, issue.status.char(), issue.title });
    }
}

fn cmdStart(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot start <id> [id2 ...]\n", .{});

    var storage = try Storage.open(allocator);
    defer storage.close();

    const results = try storage.resolveIds(args);
    defer storage_mod.freeResolveResults(allocator, results);

    for (results, 0..) |result, i| {
        switch (result) {
            .ok => |id| {
                // Warn if any open/active blockers exist, but proceed regardless.
                var iss = try storage.getIssue(id) orelse fatal("Issue not found: {s}\n", .{args[i]});
                defer iss.deinit(allocator);

                var warned = false;
                for (iss.blockers) |blocker_id| {
                    if (try storage.getIssue(blocker_id)) |blocker| {
                        var bl = blocker;
                        defer bl.deinit(allocator);
                        if (bl.status == .open or bl.status == .active) {
                            if (!warned) {
                                try stdout().print("Warning: {s} is blocked by:\n", .{id});
                                warned = true;
                            }
                            try stdout().print("  {s} ({s}) - {s}\n", .{ bl.id, bl.status.display(), bl.title });
                        }
                    }
                }

                try storage.updateStatus(id, .active, null, null);
            },
            .not_found => fatal("Issue not found: {s}\n", .{args[i]}),
            .ambiguous => fatal("Ambiguous ID: {s}\n", .{args[i]}),
        }
    }
}

fn cmdClose(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot close <id|scope> [id2 ...] [-r reason]\n", .{});

    var reason: ?[]const u8 = null;
    var ids: std.ArrayList([]const u8) = .{};
    defer ids.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "-r")) |v| {
            reason = v;
        } else if (args[i].len > 0 and args[i][0] != '-') {
            try ids.append(allocator, args[i]);
        }
    }

    if (ids.items.len == 0) fatal("Usage: dot close <id|scope> [id2 ...] [-r reason]\n", .{});

    var storage = try Storage.open(allocator);
    defer storage.close();

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    for (ids.items) |arg| {
        if (issue_mod.extractScope(arg) == null) {
            try closeScopeIssues(allocator, &storage, arg, now, reason);
        } else {
            const resolved = resolveIdOrFatal(&storage, arg);
            defer allocator.free(resolved);
            try storage.updateStatus(resolved, .closed, now, reason);
        }
    }
}

fn closeScopeIssues(allocator: Allocator, storage: *Storage, scope: []const u8, now: []const u8, reason: ?[]const u8) !void {
    const issues = try storage.listIssues(null);
    defer {
        for (issues) |*iss| iss.deinit(allocator);
        allocator.free(issues);
    }

    var closed: usize = 0;
    for (issues) |issue| {
        if (issue.status == .closed) continue;
        const issue_scope = issue_mod.extractScope(issue.id) orelse continue;
        if (!std.mem.eql(u8, issue_scope, scope)) continue;
        try storage.updateStatus(issue.id, .closed, now, reason);
        closed += 1;
    }

    if (closed == 0) fatal("No open issues found in scope: {s}\n", .{scope});
}

fn cmdRm(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot rm <id> [id2 ...]\n", .{});

    var storage = try Storage.open(allocator);
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

    var storage = try Storage.open(allocator);
    defer storage.close();

    const resolved = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(resolved);

    var iss = try storage.getIssue(resolved) orelse fatal("Issue not found: {s}\n", .{args[0]});
    defer iss.deinit(allocator);

    const w = stdout();
    const tty_conf = std.Io.tty.Config.detect(fs.File.stdout());

    // Print header fields; highlight the focal ID in cyan.
    try w.writeAll("ID:       ");
    try tty_conf.setColor(w, .cyan);
    try w.writeAll(iss.id);
    try tty_conf.setColor(w, .reset);
    try w.print("\nTitle:    {s}\nStatus:   {s}\nPriority: {d}\n", .{
        iss.title,
        iss.status.display(),
        iss.priority,
    });
    if (iss.description.len > 0) try w.print("Desc:     {s}\n", .{iss.description});
    try w.print("Created:  {s}\n", .{iss.created_at});
    if (iss.closed_at) |ca| try w.print("Closed:   {s}\n", .{ca});
    if (iss.close_reason) |r| try w.print("Reason:   {s}\n", .{r});

    // Blocked by: issues listed in iss.blockers.
    if (iss.blockers.len > 0) {
        try w.writeAll("\nBlocked by:\n");
        for (iss.blockers, 0..) |blocker_id, j| {
            const connector: []const u8 = if (j + 1 == iss.blockers.len) "  └─" else "  ├─";
            if (try storage.getIssue(blocker_id)) |blocker| {
                var bl = blocker;
                defer bl.deinit(allocator);
                try w.print("{s} {s} ({s}) - {s}\n", .{ connector, blocker_id, bl.status.display(), bl.title });
            } else {
                try w.print("{s} {s} (not found)\n", .{ connector, blocker_id });
            }
        }
    }

    // Blockers: issues that list iss.id in their blockers array.
    // Only scans active (non-archived) issues; archived dependents are done anyway.
    const all_issues = try storage.listIssues(null);
    defer issue_mod.freeIssues(allocator, all_issues);

    // Collect indices of issues blocked by iss.id.
    var blocked_indices: std.ArrayList(usize) = .{};
    defer blocked_indices.deinit(allocator);

    for (all_issues, 0..) |other, idx| {
        for (other.blockers) |b| {
            if (std.mem.eql(u8, b, iss.id)) {
                try blocked_indices.append(allocator, idx);
                break;
            }
        }
    }

    if (blocked_indices.items.len > 0) {
        try w.writeAll("\nBlocks:\n");
        for (blocked_indices.items, 0..) |idx, j| {
            const other = all_issues[idx];
            const connector: []const u8 = if (j + 1 == blocked_indices.items.len) "  └─" else "  ├─";
            try w.print("{s} {s} ({s}) - {s}\n", .{ connector, other.id, other.status.display(), other.title });
        }
    }
}

fn cmdList(allocator: Allocator, args: []const []const u8) !void {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        try stdout().writeAll(
            \\Usage: dot list [scope]
            \\
            \\Show all scopes and their issues in a tree format.
            \\Only open and active issues are displayed.
            \\
            \\If a scope is specified, only that scope is shown.
            \\
            \\Examples:
            \\  dot list          Show all scopes
            \\  dot list app      Show only the app scope
            \\
        );
        return;
    }

    var scope_filter: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') {
            scope_filter = arg;
            break;
        }
    }

    var storage = try Storage.open(allocator);
    defer storage.close();

    const scopes = try storage.listScopes();
    defer issue_mod.freeScopes(allocator, scopes);

    if (scope_filter) |filter| {
        var found = false;
        for (scopes) |s| {
            if (std.mem.eql(u8, s, filter)) {
                found = true;
                break;
            }
        }
        if (!found) fatal("Unknown scope: {s}\n", .{filter});
    }

    const issues = try storage.listIssues(null);
    defer issue_mod.freeIssues(allocator, issues);

    const w = stdout();
    const tty_conf = std.Io.tty.Config.detect(fs.File.stdout());

    for (scopes) |scope| {
        if (scope_filter) |filter| {
            if (!std.mem.eql(u8, scope, filter)) continue;
        }

        var visible: std.ArrayList(usize) = .{};
        defer visible.deinit(allocator);

        for (issues, 0..) |issue, i| {
            if (issue.status == .closed) continue;
            const issue_scope = issue_mod.extractScope(issue.id) orelse continue;
            if (std.mem.eql(u8, issue_scope, scope)) {
                try visible.append(allocator, i);
            }
        }

        try w.print("{s} ({d} open)\n", .{ scope, visible.items.len });

        // Build set of visible IDs for quick lookup
        var visible_ids: std.StringHashMapUnmanaged(void) = .empty;
        defer visible_ids.deinit(allocator);
        for (visible.items) |idx| {
            try visible_ids.put(allocator, issues[idx].id, {});
        }

        // Build parent→children map: if issue A blocks B (both visible), B is a child of A
        var children_map: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
        defer {
            var it = children_map.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(allocator);
            children_map.deinit(allocator);
        }

        var is_child: std.StringHashMapUnmanaged(void) = .empty;
        defer is_child.deinit(allocator);

        for (visible.items) |idx| {
            const issue = issues[idx];
            for (issue.blockers) |blocked_id| {
                if (!visible_ids.contains(blocked_id)) continue;

                const entry = try children_map.getOrPut(allocator, issue.id);
                if (!entry.found_existing) entry.value_ptr.* = .empty;

                // Find the visible index for blocked_id
                for (visible.items) |vidx| {
                    if (std.mem.eql(u8, issues[vidx].id, blocked_id)) {
                        try entry.value_ptr.append(allocator, vidx);
                        break;
                    }
                }
                try is_child.put(allocator, blocked_id, {});
            }
        }

        // Roots: visible issues not blocked by any other visible issue
        var roots: std.ArrayList(usize) = .empty;
        defer roots.deinit(allocator);
        for (visible.items) |idx| {
            if (!is_child.contains(issues[idx].id)) {
                try roots.append(allocator, idx);
            }
        }

        for (roots.items, 0..) |idx, j| {
            const is_last = j + 1 == roots.items.len;
            try renderTreeNode(allocator, w, tty_conf, issues, &children_map, idx, "  ", is_last);
        }
    }
}

fn renderTreeNode(
    allocator: Allocator,
    w: *std.Io.Writer,
    tty_conf: std.Io.tty.Config,
    issues: []const Issue,
    children_map: *const std.StringHashMapUnmanaged(std.ArrayList(usize)),
    idx: usize,
    prefix: []const u8,
    is_last: bool,
) !void {
    const issue = issues[idx];
    const connector: []const u8 = if (is_last) "└─" else "├─";

    try w.print("{s}{s} ", .{ prefix, connector });

    if (issue.status == .active) {
        try tty_conf.setColor(w, .cyan);
    }

    try w.print("{s} {s} {s}", .{ issue.id, issue.status.symbol(), issue.title });

    if (issue.status == .active) {
        try tty_conf.setColor(w, .reset);
    }

    try w.writeAll("\n");

    const children = children_map.get(issue.id) orelse return;
    const extension: []const u8 = if (is_last) "   " else "│  ";
    const child_prefix = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, extension });
    defer allocator.free(child_prefix);

    for (children.items, 0..) |child_idx, k| {
        const child_is_last = k + 1 == children.items.len;
        try renderTreeNode(allocator, w, tty_conf, issues, children_map, child_idx, child_prefix, child_is_last);
    }
}

fn cmdBlock(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 2) fatal("Usage: dot block <id> <blocker-id>\n", .{});

    var storage = try Storage.open(allocator);
    defer storage.close();

    const id = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(id);
    const blocker_id = resolveIdOrFatal(&storage, args[1]);
    defer allocator.free(blocker_id);

    try storage.addDependency(id, blocker_id, "blockers");
    try stdout().print("{s} is now blocked by {s}\n", .{ id, blocker_id });
}

fn cmdUnblock(allocator: Allocator, args: []const []const u8) !void {
    if (args.len < 2) fatal("Usage: dot unblock <id> <blocker-id>\n", .{});

    var storage = try Storage.open(allocator);
    defer storage.close();

    const id = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(id);
    const blocker_id = resolveIdOrFatal(&storage, args[1]);
    defer allocator.free(blocker_id);

    try storage.removeDependency(id, blocker_id);
    try stdout().print("{s} is no longer blocked by {s}\n", .{ id, blocker_id });
}

fn cmdUpdate(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) fatal("Usage: dot update <id> [--status S]\n", .{});

    var new_status: ?Status = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (getArg(args, &i, "--status")) |v| new_status = parseStatusArg(v);
    }

    const status = new_status orelse fatal("--status required\n", .{});

    var storage = try Storage.open(allocator);
    defer storage.close();

    const resolved = resolveIdOrFatal(&storage, args[0]);
    defer allocator.free(resolved);

    var ts_buf: [40]u8 = undefined;
    const closed_at: ?[]const u8 = if (status == .closed) try formatTimestamp(&ts_buf) else null;

    try storage.updateStatus(resolved, status, closed_at, null);
}

fn cmdPurge(allocator: Allocator, _: []const []const u8) !void {
    var storage = try Storage.open(allocator);
    defer storage.close();

    try storage.purgeArchive();
    try stdout().writeAll("Archive purged\n");
}
