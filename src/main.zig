const std = @import("std");
const fs = std.fs;
const json = std.json;
const Allocator = std.mem.Allocator;
const libc = @cImport({
    @cInclude("time.h");
});

const DOTS_FILE = ".dots";

const Dot = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    status: Status = .open,
    priority: u8 = 2,
    parent: ?[]const u8 = null,
    after: ?[]const u8 = null, // blocked by this dot
    created: []const u8 = "",
    updated: []const u8 = "",
    closed: ?[]const u8 = null,
    reason: ?[]const u8 = null,

    const Status = enum {
        open,
        active,
        done,

        pub fn toString(self: Status) []const u8 {
            return switch (self) {
                .open => "open",
                .active => "active",
                .done => "done",
            };
        }

        pub fn fromString(s: []const u8) Status {
            if (std.mem.eql(u8, s, "open")) return .open;
            if (std.mem.eql(u8, s, "active")) return .active;
            if (std.mem.eql(u8, s, "done")) return .done;
            // Legacy beads compatibility
            if (std.mem.eql(u8, s, "in_progress")) return .active;
            if (std.mem.eql(u8, s, "closed")) return .done;
            return .open;
        }
    };

    pub fn jsonStringify(self: *const Dot, jw: *json.Stringify) !void {
        try jw.beginObject();
        try jw.objectField("id");
        try jw.write(self.id);
        try jw.objectField("title");
        try jw.write(self.title);
        if (self.description.len > 0) {
            try jw.objectField("description");
            try jw.write(self.description);
        }
        try jw.objectField("status");
        try jw.write(self.status.toString());
        try jw.objectField("priority");
        try jw.write(self.priority);
        if (self.parent) |p| {
            try jw.objectField("parent");
            try jw.write(p);
        }
        if (self.after) |a| {
            try jw.objectField("after");
            try jw.write(a);
        }
        if (self.created.len > 0) {
            try jw.objectField("created");
            try jw.write(self.created);
        }
        if (self.updated.len > 0) {
            try jw.objectField("updated");
            try jw.write(self.updated);
        }
        if (self.closed) |c| {
            try jw.objectField("closed");
            try jw.write(c);
        }
        if (self.reason) |r| {
            try jw.objectField("reason");
            try jw.write(r);
        }
        try jw.endObject();
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // No args = show ready
    if (args.len < 2) {
        try cmdReady(allocator, &[_][]const u8{"--json"});
        return;
    }

    const cmd = args[1];

    // Quick add: dot "title"
    if (cmd.len > 0 and cmd[0] != '-' and !isCommand(cmd)) {
        try cmdAdd(allocator, args[1..]);
        return;
    }

    if (std.mem.eql(u8, cmd, "add")) {
        try cmdAdd(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "ls") or std.mem.eql(u8, cmd, "list")) {
        try cmdList(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "it") or std.mem.eql(u8, cmd, "do")) {
        try cmdIt(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "off") or std.mem.eql(u8, cmd, "done")) {
        try cmdOff(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "rm") or std.mem.eql(u8, cmd, "delete")) {
        try cmdRm(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "show")) {
        try cmdShow(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "ready")) {
        try cmdReady(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "tree")) {
        try cmdTree(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "find")) {
        try cmdFind(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit();
    } else if (std.mem.eql(u8, cmd, "create")) {
        // Beads compatibility
        try cmdAdd(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "update")) {
        // Beads compatibility - treat as status change
        try cmdBeadsUpdate(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "close")) {
        // Beads compatibility
        try cmdBeadsClose(allocator, args[2..]);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        try printUsage();
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try printVersion();
    } else {
        // Assume it's a quick add
        try cmdAdd(allocator, args[1..]);
    }
}

fn isCommand(s: []const u8) bool {
    const commands = [_][]const u8{ "add", "ls", "list", "it", "do", "off", "done", "rm", "delete", "show", "ready", "tree", "find", "init", "help", "create", "update", "close" };
    for (commands) |c| {
        if (std.mem.eql(u8, s, c)) return true;
    }
    return false;
}

fn printUsage() !void {
    const usage =
        \\dots - Connect the dots
        \\
        \\Usage: dot [command] [options]
        \\
        \\Commands:
        \\  dot "title"                  Quick add a dot
        \\  dot add "title" [options]    Add a dot (-p priority, -d desc, -P parent, -a after)
        \\  dot ls [--status S] [--json] List dots
        \\  dot it <id>                  Start working ("I'm on it!")
        \\  dot off <id> [-r reason]     Complete ("cross it off")
        \\  dot rm <id>                  Remove a dot
        \\  dot show <id>                Show dot details
        \\  dot ready [--json]           Show unblocked dots
        \\  dot tree                     Show hierarchy
        \\  dot find "query"             Search dots
        \\  dot init                     Initialize .dots file
        \\
        \\Examples:
        \\  dot "Fix the bug"
        \\  dot add "Design API" -p 1 -d "REST endpoints"
        \\  dot add "Implement" -P d-1 -a d-2
        \\  dot it d-3
        \\  dot off d-3 -r "shipped"
        \\
    ;
    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;
    try w.writeAll(usage);
    try w.flush();
}

fn printVersion() !void {
    const stdout_file = fs.File.stdout();
    var buf: [256]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;
    try w.writeAll("dots 0.1.0\n");
    try w.flush();
}

fn cmdInit() !void {
    const file = fs.cwd().createFile(DOTS_FILE, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return,
        else => return err,
    };
    file.close();
}

fn cmdAdd(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printUsage();
        std.process.exit(1);
    }

    var title: []const u8 = "";
    var description: []const u8 = "";
    var priority: u8 = 2;
    var parent: ?[]const u8 = null;
    var after: ?[]const u8 = null;
    var use_json = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            i += 1;
            priority = std.fmt.parseInt(u8, args[i], 10) catch 2;
        } else if (std.mem.eql(u8, args[i], "-d") and i + 1 < args.len) {
            i += 1;
            description = args[i];
        } else if (std.mem.eql(u8, args[i], "-P") and i + 1 < args.len) {
            i += 1;
            parent = args[i];
        } else if (std.mem.eql(u8, args[i], "-a") and i + 1 < args.len) {
            i += 1;
            after = args[i];
        } else if (std.mem.eql(u8, args[i], "--json")) {
            use_json = true;
        } else if (title.len == 0 and args[i].len > 0 and args[i][0] != '-') {
            title = args[i];
        }
    }

    if (title.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Error: title required\n");
        try w.flush();
        std.process.exit(1);
    }

    // Generate ID
    const id = try generateId(allocator);
    defer allocator.free(id);

    var ts_buf: [40]u8 = undefined;
    const now = try formatTimestamp(&ts_buf);

    const dot = Dot{
        .id = id,
        .title = title,
        .description = description,
        .priority = priority,
        .parent = parent,
        .after = after,
        .status = .open,
        .created = now,
        .updated = now,
    };

    try appendDot(allocator, dot);

    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    if (use_json) {
        var jw: json.Stringify = .{ .writer = w };
        try dot.jsonStringify(&jw);
        try w.writeByte('\n');
    } else {
        try w.print("{s}\n", .{id});
    }
    try w.flush();
}

fn cmdList(allocator: Allocator, args: []const []const u8) !void {
    var use_json = false;
    var filter_status: ?Dot.Status = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            use_json = true;
        } else if (std.mem.eql(u8, arg, "--status")) {
            // Next arg is the status
        } else if (std.mem.eql(u8, arg, "open") or std.mem.eql(u8, arg, "active") or std.mem.eql(u8, arg, "done")) {
            filter_status = Dot.Status.fromString(arg);
        }
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--status") and i + 1 < args.len) {
            i += 1;
            filter_status = Dot.Status.fromString(args[i]);
        }
    }

    const dots = try loadDots(allocator);
    defer freeDots(allocator, dots);

    var filtered: std.ArrayList(Dot) = .{};
    defer filtered.deinit(allocator);

    for (dots) |dot| {
        if (filter_status) |fst| {
            if (dot.status != fst) continue;
        } else {
            // Default: hide done
            if (dot.status == .done) continue;
        }
        try filtered.append(allocator, dot);
    }

    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    if (use_json) {
        try w.writeByte('[');
        for (filtered.items, 0..) |dot, idx| {
            if (idx > 0) try w.writeByte(',');
            var jw: json.Stringify = .{ .writer = w };
            try dot.jsonStringify(&jw);
        }
        try w.writeAll("]\n");
    } else {
        for (filtered.items) |dot| {
            const status_char: u8 = switch (dot.status) {
                .open => 'o',
                .active => '>',
                .done => 'x',
            };
            try w.print("[{s}] {c} {s}\n", .{ dot.id, status_char, dot.title });
        }
    }
    try w.flush();
}

fn cmdReady(allocator: Allocator, args: []const []const u8) !void {
    var use_json = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) use_json = true;
    }

    const dots = try loadDots(allocator);
    defer freeDots(allocator, dots);

    // Build set of open dot IDs
    var open_ids = std.StringHashMap(void).init(allocator);
    defer open_ids.deinit();
    for (dots) |dot| {
        if (dot.status != .done) {
            try open_ids.put(dot.id, {});
        }
    }

    var ready: std.ArrayList(Dot) = .{};
    defer ready.deinit(allocator);

    for (dots) |dot| {
        if (dot.status != .open) continue;
        // Check if blocked
        if (dot.after) |after_id| {
            if (open_ids.contains(after_id)) continue; // blocked
        }
        try ready.append(allocator, dot);
    }

    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    if (use_json) {
        try w.writeByte('[');
        for (ready.items, 0..) |dot, idx| {
            if (idx > 0) try w.writeByte(',');
            var jw: json.Stringify = .{ .writer = w };
            try dot.jsonStringify(&jw);
        }
        try w.writeAll("]\n");
    } else {
        for (ready.items) |dot| {
            try w.print("[{s}] {s}\n", .{ dot.id, dot.title });
        }
    }
    try w.flush();
}

fn cmdIt(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot it <id>\n");
        try w.flush();
        std.process.exit(1);
    }
    try updateDot(allocator, args[0], .active, null);
}

fn cmdOff(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot off <id> [-r reason]\n");
        try w.flush();
        std.process.exit(1);
    }

    const id = args[0];
    var reason: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-r") and i + 1 < args.len) {
            i += 1;
            reason = args[i];
        }
    }

    try updateDot(allocator, id, .done, reason);
}

fn cmdRm(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot rm <id>\n");
        try w.flush();
        std.process.exit(1);
    }
    try removeDot(allocator, args[0]);
}

fn cmdShow(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot show <id>\n");
        try w.flush();
        std.process.exit(1);
    }

    const dots = try loadDots(allocator);
    defer freeDots(allocator, dots);

    const stdout_file = fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    for (dots) |dot| {
        if (std.mem.eql(u8, dot.id, args[0])) {
            try w.print("ID:       {s}\n", .{dot.id});
            try w.print("Title:    {s}\n", .{dot.title});
            try w.print("Status:   {s}\n", .{dot.status.toString()});
            try w.print("Priority: {d}\n", .{dot.priority});
            if (dot.description.len > 0) {
                try w.print("Desc:     {s}\n", .{dot.description});
            }
            if (dot.parent) |p| {
                try w.print("Parent:   {s}\n", .{p});
            }
            if (dot.after) |a| {
                try w.print("After:    {s}\n", .{a});
            }
            try w.print("Created:  {s}\n", .{dot.created});
            if (dot.closed) |c| {
                try w.print("Closed:   {s}\n", .{c});
            }
            if (dot.reason) |r| {
                try w.print("Reason:   {s}\n", .{r});
            }
            try w.flush();
            return;
        }
    }

    const stderr = fs.File.stderr();
    var errbuf: [256]u8 = undefined;
    var err_writer = stderr.writer(&errbuf);
    const ew = &err_writer.interface;
    try ew.print("Dot not found: {s}\n", .{args[0]});
    try ew.flush();
    std.process.exit(1);
}

fn cmdTree(allocator: Allocator, args: []const []const u8) !void {
    _ = args;

    const dots = try loadDots(allocator);
    defer freeDots(allocator, dots);

    // Build set of open dot IDs for blocking check
    var open_ids = std.StringHashMap(void).init(allocator);
    defer open_ids.deinit();
    for (dots) |dot| {
        if (dot.status != .done) {
            try open_ids.put(dot.id, {});
        }
    }

    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    // Print roots first, then children
    for (dots) |dot| {
        if (dot.status == .done) continue;
        if (dot.parent != null) continue; // Skip children in first pass

        const status_sym = switch (dot.status) {
            .open => "○",
            .active => "●",
            .done => "✓",
        };
        try w.print("[{s}] {s} {s}\n", .{ dot.id, status_sym, dot.title });

        // Print children
        for (dots) |child| {
            if (child.status == .done) continue;
            if (child.parent) |p| {
                if (std.mem.eql(u8, p, dot.id)) {
                    const child_status = switch (child.status) {
                        .open => "○",
                        .active => "●",
                        .done => "✓",
                    };
                    var blocked_msg: []const u8 = "";
                    if (child.after) |a| {
                        if (open_ids.contains(a)) {
                            blocked_msg = " (blocked)";
                        }
                    }
                    try w.print("  └─ [{s}] {s} {s}{s}\n", .{ child.id, child_status, child.title, blocked_msg });
                }
            }
        }
    }
    try w.flush();
}

fn cmdFind(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot find <query>\n");
        try w.flush();
        std.process.exit(1);
    }

    const query = args[0];
    const dots = try loadDots(allocator);
    defer freeDots(allocator, dots);

    const stdout_file = fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var file_writer = stdout_file.writer(&buf);
    const w = &file_writer.interface;

    for (dots) |dot| {
        if (std.mem.indexOf(u8, dot.title, query) != null or
            std.mem.indexOf(u8, dot.description, query) != null)
        {
            const status_char: u8 = switch (dot.status) {
                .open => 'o',
                .active => '>',
                .done => 'x',
            };
            try w.print("[{s}] {c} {s}\n", .{ dot.id, status_char, dot.title });
        }
    }
    try w.flush();
}

fn generateId(allocator: Allocator) ![]u8 {
    const nanos = std.time.nanoTimestamp();
    const ts: u64 = @intCast(@as(u128, @intCast(nanos)) & 0xFFFFFFFF);
    return std.fmt.allocPrint(allocator, "d-{x}", .{@as(u16, @truncate(ts))});
}

fn formatTimestamp(buf: []u8) ![]const u8 {
    const nanos = std.time.nanoTimestamp();
    const epoch_nanos: u128 = @intCast(nanos);
    const epoch_secs: libc.time_t = @intCast(epoch_nanos / 1_000_000_000);
    const micros: u64 = @intCast((epoch_nanos % 1_000_000_000) / 1000);

    var tm: libc.struct_tm = undefined;
    _ = libc.localtime_r(&epoch_secs, &tm);

    const year: u64 = @intCast(tm.tm_year + 1900);
    const month: u64 = @intCast(tm.tm_mon + 1);
    const day: u64 = @intCast(tm.tm_mday);
    const hours: u64 = @intCast(tm.tm_hour);
    const mins: u64 = @intCast(tm.tm_min);
    const secs: u64 = @intCast(tm.tm_sec);

    const tz_offset_secs: i64 = tm.tm_gmtoff;
    const tz_hours: i64 = @divTrunc(tz_offset_secs, 3600);
    const tz_mins: u64 = @abs(@rem(tz_offset_secs, 3600)) / 60;
    const tz_sign: u8 = if (tz_hours >= 0) '+' else '-';
    const tz_hours_abs: u64 = @abs(tz_hours);

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}{c}{d:0>2}:{d:0>2}", .{
        year, month, day, hours, mins, secs, micros, tz_sign, tz_hours_abs, tz_mins,
    });
}

fn loadDots(allocator: Allocator) ![]Dot {
    const file = fs.cwd().openFile(DOTS_FILE, .{}) catch |err| switch (err) {
        error.FileNotFound => return &[_]Dot{},
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var dots: std.ArrayList(Dot) = .{};
    errdefer dots.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();

        const obj = parsed.value.object;
        const dot = Dot{
            .id = try allocator.dupe(u8, obj.get("id").?.string),
            .title = try allocator.dupe(u8, obj.get("title").?.string),
            .description = if (obj.get("description")) |d| try allocator.dupe(u8, d.string) else "",
            .status = Dot.Status.fromString(if (obj.get("status")) |s| s.string else "open"),
            .priority = if (obj.get("priority")) |p| @intCast(p.integer) else 2,
            .parent = if (obj.get("parent")) |p| try allocator.dupe(u8, p.string) else null,
            .after = if (obj.get("after")) |a| try allocator.dupe(u8, a.string) else null,
            .created = if (obj.get("created")) |c| try allocator.dupe(u8, c.string) else "",
            .updated = if (obj.get("updated")) |u| try allocator.dupe(u8, u.string) else "",
            .closed = if (obj.get("closed")) |c| try allocator.dupe(u8, c.string) else null,
            .reason = if (obj.get("reason")) |r| try allocator.dupe(u8, r.string) else null,
        };
        try dots.append(allocator, dot);
    }

    return try dots.toOwnedSlice(allocator);
}

fn freeDots(allocator: Allocator, dots: []Dot) void {
    for (dots) |dot| {
        allocator.free(dot.id);
        allocator.free(dot.title);
        if (dot.description.len > 0) allocator.free(dot.description);
        if (dot.parent) |p| allocator.free(p);
        if (dot.after) |a| allocator.free(a);
        if (dot.created.len > 0) allocator.free(dot.created);
        if (dot.updated.len > 0) allocator.free(dot.updated);
        if (dot.closed) |c| allocator.free(c);
        if (dot.reason) |r| allocator.free(r);
    }
    allocator.free(dots);
}

fn appendDot(allocator: Allocator, dot: Dot) !void {
    const file = try fs.cwd().createFile(DOTS_FILE, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);

    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    var jw: json.Stringify = .{ .writer = w };
    try dot.jsonStringify(&jw);
    try w.writeByte('\n');

    const data = try out.toOwnedSlice();
    defer allocator.free(data);
    try file.writeAll(data);
}

fn updateDot(allocator: Allocator, id: []const u8, new_status: Dot.Status, reason: ?[]const u8) !void {
    const orig_content = blk: {
        const file = fs.cwd().openFile(DOTS_FILE, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const stderr = fs.File.stderr();
                var buf: [256]u8 = undefined;
                var file_writer = stderr.writer(&buf);
                const w = &file_writer.interface;
                try w.print("Dot not found: {s}\n", .{id});
                try w.flush();
                std.process.exit(1);
            },
            else => return err,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    };
    defer allocator.free(orig_content);

    const file = try fs.cwd().createFile(DOTS_FILE, .{});
    defer file.close();

    var found = false;
    var line_iter = std.mem.splitScalar(u8, orig_content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch {
            try file.writeAll(line);
            try file.writeAll("\n");
            continue;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        const dot_id = obj.get("id").?.string;

        if (std.mem.eql(u8, dot_id, id)) {
            found = true;
            var out: std.io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            const w = &out.writer;

            try w.writeByte('{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;

                try w.writeByte('"');
                try w.writeAll(entry.key_ptr.*);
                try w.writeAll("\":");

                if (std.mem.eql(u8, entry.key_ptr.*, "status")) {
                    try json.Stringify.encodeJsonString(new_status.toString(), .{}, w);
                } else if (std.mem.eql(u8, entry.key_ptr.*, "updated")) {
                    var ts_buf: [40]u8 = undefined;
                    const now = try formatTimestamp(&ts_buf);
                    try json.Stringify.encodeJsonString(now, .{}, w);
                } else {
                    try writeJsonValue(entry.value_ptr.*, w);
                }
            }

            // Add closed timestamp and reason if completing
            if (new_status == .done) {
                if (obj.get("closed") == null) {
                    var ts_buf: [40]u8 = undefined;
                    const now = try formatTimestamp(&ts_buf);
                    try w.writeAll(",\"closed\":");
                    try json.Stringify.encodeJsonString(now, .{}, w);
                }
                if (reason) |r| {
                    if (obj.get("reason") == null) {
                        try w.writeAll(",\"reason\":");
                        try json.Stringify.encodeJsonString(r, .{}, w);
                    }
                }
            }

            try w.writeAll("}\n");
            const data = try out.toOwnedSlice();
            defer allocator.free(data);
            try file.writeAll(data);
        } else {
            try file.writeAll(line);
            try file.writeAll("\n");
        }
    }

    if (!found) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.print("Dot not found: {s}\n", .{id});
        try w.flush();
        std.process.exit(1);
    }
}

fn removeDot(allocator: Allocator, id: []const u8) !void {
    const orig_content = blk: {
        const file = fs.cwd().openFile(DOTS_FILE, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const stderr = fs.File.stderr();
                var buf: [256]u8 = undefined;
                var file_writer = stderr.writer(&buf);
                const w = &file_writer.interface;
                try w.print("Dot not found: {s}\n", .{id});
                try w.flush();
                std.process.exit(1);
            },
            else => return err,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    };
    defer allocator.free(orig_content);

    const file = try fs.cwd().createFile(DOTS_FILE, .{});
    defer file.close();

    var found = false;
    var line_iter = std.mem.splitScalar(u8, orig_content, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;

        const parsed = json.parseFromSlice(json.Value, allocator, line, .{}) catch {
            try file.writeAll(line);
            try file.writeAll("\n");
            continue;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        const dot_id = obj.get("id").?.string;

        if (std.mem.eql(u8, dot_id, id)) {
            found = true;
            // Skip this line (delete)
        } else {
            try file.writeAll(line);
            try file.writeAll("\n");
        }
    }

    if (!found) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.print("Dot not found: {s}\n", .{id});
        try w.flush();
        std.process.exit(1);
    }
}

fn writeJsonValue(value: json.Value, w: *std.Io.Writer) !void {
    switch (value) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| try json.Stringify.encodeJsonString(s, .{}, w),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, idx| {
                if (idx > 0) try w.writeByte(',');
                try writeJsonValue(item, w);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeByte('"');
                try w.writeAll(entry.key_ptr.*);
                try w.writeAll("\":");
                try writeJsonValue(entry.value_ptr.*, w);
            }
            try w.writeByte('}');
        },
        .number_string => |s| try w.writeAll(s),
    }
}

// Beads compatibility commands
fn cmdBeadsUpdate(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot update <id> [--status S] [-d desc]\n");
        try w.flush();
        std.process.exit(1);
    }

    const id = args[0];
    var new_status: ?Dot.Status = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--status") and i + 1 < args.len) {
            i += 1;
            new_status = Dot.Status.fromString(args[i]);
        }
    }

    if (new_status) |s| {
        try updateDot(allocator, id, s, null);
    }
}

fn cmdBeadsClose(allocator: Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        const stderr = fs.File.stderr();
        var buf: [256]u8 = undefined;
        var file_writer = stderr.writer(&buf);
        const w = &file_writer.interface;
        try w.writeAll("Usage: dot close <id> [--reason R]\n");
        try w.flush();
        std.process.exit(1);
    }

    const id = args[0];
    var reason: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--reason") and i + 1 < args.len) {
            i += 1;
            reason = args[i];
        }
    }

    try updateDot(allocator, id, .done, reason);
}

test "basic" {
    try std.testing.expect(true);
}
