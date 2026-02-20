const std = @import("std");
const fs = std.fs;
const h = @import("test_helpers.zig");

const Issue = h.Issue;
const OhSnap = h.OhSnap;
const runDot = h.runDot;
const isExitCode = h.isExitCode;
const trimNewline = h.trimNewline;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const openTestStorage = h.openTestStorage;

test "cli: hook command is rejected" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const result = try runDot(allocator, &.{"hook"}, test_dir.path);
    defer result.deinit(allocator);

    try std.testing.expect(!isExitCode(result.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "Unknown command: hook") != null);
}

test "cli: init creates dots directory" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const result = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(isExitCode(result.term, 0));

    // Verify .dots directory exists
    const dots_path = std.fmt.allocPrint(allocator, "{s}/.dots", .{test_dir.path}) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(dots_path);

    // Use openDir instead of statFile because statFile uses openFile on
    // Windows which cannot open directories.
    var dots_dir = fs.cwd().openDir(dots_path, .{}) catch |err| {
        std.debug.panic("stat: {}", .{err});
    };
    dots_dir.close();
}

test "cli: add creates markdown file" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const init = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    const result = runDot(allocator, &.{ "add", "Test task", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer result.deinit(allocator);

    try std.testing.expect(isExitCode(result.term, 0));

    const id = trimNewline(result.stdout);
    try std.testing.expect(id.len > 0);

    // Verify markdown file exists
    const md_path = std.fmt.allocPrint(allocator, "{s}/.dots/test/{s}.md", .{ test_dir.path, id }) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(md_path);

    const stat = fs.cwd().statFile(md_path) catch |err| {
        std.debug.panic("stat: {}", .{err});
    };
    try std.testing.expect(stat.kind == .file);
}

test "cli: purge removes archived dots" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const init = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add and close an issue to archive it
    const add = runDot(allocator, &.{ "add", "To archive", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);

    const id = trimNewline(add.stdout);

    const off = runDot(allocator, &.{ "off", id }, test_dir.path) catch |err| {
        std.debug.panic("off: {}", .{err});
    };
    defer off.deinit(allocator);

    // Verify archive has content
    const archive_path = std.fmt.allocPrint(allocator, "{s}/.dots/archive", .{test_dir.path}) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(archive_path);

    var archive_dir = fs.cwd().openDir(archive_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("open archive: {}", .{err});
    };
    defer archive_dir.close();

    var count: usize = 0;
    var iter = archive_dir.iterate();
    while (try iter.next()) |_| {
        count += 1;
    }
    try std.testing.expect(count > 0);

    // Purge
    const purge = runDot(allocator, &.{"purge"}, test_dir.path) catch |err| {
        std.debug.panic("purge: {}", .{err});
    };
    defer purge.deinit(allocator);

    try std.testing.expect(isExitCode(purge.term, 0));

    // Verify archive is empty
    var archive_dir2 = fs.cwd().openDir(archive_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("open archive2: {}", .{err});
    };
    defer archive_dir2.close();

    var count2: usize = 0;
    var iter2 = archive_dir2.iterate();
    while (try iter2.next()) |_| {
        count2 += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), count2);
}

test "cli: add creates scope directory" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const init = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    const add = runDot(allocator, &.{ "add", "Scoped task", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add scoped: {}", .{err});
    };
    defer add.deinit(allocator);
    const id = trimNewline(add.stdout);

    const scope_path = std.fmt.allocPrint(allocator, "{s}/.dots/test", .{test_dir.path}) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(scope_path);

    var scope_dir = fs.cwd().openDir(scope_path, .{}) catch |err| {
        std.debug.panic("open scope dir: {}", .{err});
    };
    scope_dir.close();

    const file_path = std.fmt.allocPrint(allocator, "{s}/.dots/test/{s}.md", .{ test_dir.path, id }) catch |err| {
        std.debug.panic("file path: {}", .{err});
    };
    defer allocator.free(file_path);
    _ = fs.cwd().statFile(file_path) catch |err| {
        std.debug.panic("stat scoped file: {}", .{err});
    };
}

test "cli: find help" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const help = runDot(allocator, &.{ "find", "--help" }, test_dir.path) catch |err| {
        std.debug.panic("find help: {}", .{err});
    };
    defer help.deinit(allocator);

    try std.testing.expect(isExitCode(help.term, 0));

    const oh: OhSnap = .{};
    try oh.snap(@src(),
        \\[]u8
        \\  "Usage: dot find <query>
        \\
        \\Search all dots (open first, then archived).
        \\
        \\Searches: title, description, close-reason, created-at, closed-at
        \\
        \\Examples:
        \\  dot find "auth"      Search for dots mentioning auth
        \\  dot find "2026-01"   Find dots from January 2026
        \\"
    ).expectEqual(help.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(help.stderr);
}

test "cli: find matches titles case-insensitively" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const init = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    const add1 = runDot(allocator, &.{ "add", "Fix Bug", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);

    const add2 = runDot(allocator, &.{ "add", "Write docs", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);

    const add3 = runDot(allocator, &.{ "add", "BUG report", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add3: {}", .{err});
    };
    defer add3.deinit(allocator);

    const result = runDot(allocator, &.{ "find", "bug" }, test_dir.path) catch |err| {
        std.debug.panic("find: {}", .{err});
    };
    defer result.deinit(allocator);

    try std.testing.expect(isExitCode(result.term, 0));

    var matches: usize = 0;
    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "Bug") != null or std.mem.indexOf(u8, line, "BUG") != null) {
            matches += 1;
        } else {
            try std.testing.expect(false);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), matches);
}

test "cli: find searches archive fields and orders results" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);

    const open_issue: Issue = .{
        .id = "open-11111111",
        .title = "Open task",
        .description = "",
        .status = .open,
        .priority = 2,
        .created_at = "2024-03-01T00:00:00Z",
        .closed_at = null,
        .close_reason = null,
        .blocks = &.{},
    };
    try ts.storage.createIssue(open_issue);

    const closed_issue: Issue = .{
        .id = "closed-22222222",
        .title = "Closed task",
        .description = "",
        .status = .closed,
        .priority = 2,
        .created_at = "2024-01-01T00:00:00Z",
        .closed_at = "2024-02-01T00:00:00Z",
        .close_reason = "wontfix",
        .blocks = &.{},
    };
    try ts.storage.createIssue(closed_issue);
    try ts.storage.archiveIssue("closed-22222222");
    ts.deinit();

    const find_task = runDot(allocator, &.{ "find", "task" }, test_dir.path) catch |err| {
        std.debug.panic("find task: {}", .{err});
    };
    defer find_task.deinit(allocator);

    const find_reason = runDot(allocator, &.{ "find", "wontfix" }, test_dir.path) catch |err| {
        std.debug.panic("find reason: {}", .{err});
    };
    defer find_reason.deinit(allocator);

    const find_created = runDot(allocator, &.{ "find", "2024-03" }, test_dir.path) catch |err| {
        std.debug.panic("find created: {}", .{err});
    };
    defer find_created.deinit(allocator);

    const find_closed = runDot(allocator, &.{ "find", "2024-02" }, test_dir.path) catch |err| {
        std.debug.panic("find closed: {}", .{err});
    };
    defer find_closed.deinit(allocator);

    try std.testing.expect(isExitCode(find_task.term, 0));
    try std.testing.expect(isExitCode(find_reason.term, 0));
    try std.testing.expect(isExitCode(find_created.term, 0));
    try std.testing.expect(isExitCode(find_closed.term, 0));

    const oh: OhSnap = .{};
    try oh.snap(@src(),
        \\[]u8
        \\  "[open-11111111] o Open task
        \\[closed-22222222] x Closed task
        \\"
    ).expectEqual(find_task.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  "[closed-22222222] x Closed task
        \\"
    ).expectEqual(find_reason.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  "[open-11111111] o Open task
        \\"
    ).expectEqual(find_created.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  "[closed-22222222] x Closed task
        \\"
    ).expectEqual(find_closed.stdout);

    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(find_task.stderr);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(find_reason.stderr);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(find_created.stderr);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(find_closed.stderr);
}

test "cli: tree help" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const help = runDot(allocator, &.{ "tree", "--help" }, test_dir.path) catch |err| {
        std.debug.panic("tree help: {}", .{err});
    };
    defer help.deinit(allocator);

    try std.testing.expect(isExitCode(help.term, 0));

    const oh: OhSnap = .{};
    try oh.snap(@src(),
        \\[]u8
        \\  "dot tree is temporarily unavailable during migration
        \\"
    ).expectEqual(help.stdout);
    try oh.snap(@src(),
        \\[]u8
        \\  ""
    ).expectEqual(help.stderr);
}

test "cli: fix token currently falls through to quick-add" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const fix = runDot(allocator, &.{ "fix", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("fix: {}", .{err});
    };
    defer fix.deinit(allocator);

    try std.testing.expect(isExitCode(fix.term, 0));
    try std.testing.expect(trimNewline(fix.stdout).len > 0);
    try std.testing.expectEqual(@as(usize, 0), fix.stderr.len);
}
