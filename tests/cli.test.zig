const std = @import("std");
const fs = std.fs;
const h = @import("helpers.zig");

const Issue = h.Issue;
const OhSnap = h.OhSnap;
const runDot = h.runDot;
const isExitCode = h.isExitCode;
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

    const result = runDot(allocator, &.{ "open", "Test task", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer result.deinit(allocator);

    try std.testing.expect(isExitCode(result.term, 0));

    const id = std.mem.trimEnd(u8, result.stdout, "\n");
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
    const add = runDot(allocator, &.{ "open", "To archive", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);

    const id = std.mem.trimEnd(u8, add.stdout, "\n");

    const off = runDot(allocator, &.{ "close", id }, test_dir.path) catch |err| {
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

    const add = runDot(allocator, &.{ "open", "Scoped task", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add scoped: {}", .{err});
    };
    defer add.deinit(allocator);
    const id = std.mem.trimEnd(u8, add.stdout, "\n");

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

    const add1 = runDot(allocator, &.{ "open", "Fix Bug", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add1: {}", .{err});
    };
    defer add1.deinit(allocator);

    const add2 = runDot(allocator, &.{ "open", "Write docs", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add2: {}", .{err});
    };
    defer add2.deinit(allocator);

    const add3 = runDot(allocator, &.{ "open", "BUG report", "-s", "test" }, test_dir.path) catch |err| {
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
        .blockers = &.{},
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
        .blockers = &.{},
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
    try std.testing.expect(std.mem.indexOf(u8, help.stdout, "Usage: dot tree [scope]") != null);
    try std.testing.expect(help.stderr.len == 0);
}

test "cli: tree shows scopes and issues" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Fix login", "-s", "app", "-p", "1" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Setup DB", "-s", "app", "-p", "2" }, test_dir.path);
    defer a2.deinit(allocator);
    const d1 = try runDot(allocator, &.{ "open", "API docs", "-s", "docs" }, test_dir.path);
    defer d1.deinit(allocator);

    const tree = try runDot(allocator, &.{"tree"}, test_dir.path);
    defer tree.deinit(allocator);

    try std.testing.expect(isExitCode(tree.term, 0));
    try std.testing.expect(tree.stderr.len == 0);

    // Verify scope headers appear
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "app (2 open)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "docs (1 open)") != null);

    // Verify issues appear
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "Fix login") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "Setup DB") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "API docs") != null);
}

test "cli: tree filters by scope" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Fix login", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const d1 = try runDot(allocator, &.{ "open", "API docs", "-s", "docs" }, test_dir.path);
    defer d1.deinit(allocator);

    const tree = try runDot(allocator, &.{ "tree", "app" }, test_dir.path);
    defer tree.deinit(allocator);

    try std.testing.expect(isExitCode(tree.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "app (1 open)") != null);
    // docs scope should NOT appear
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "docs") == null);
}

test "cli: tree unknown scope fails" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const tree = try runDot(allocator, &.{ "tree", "nope" }, test_dir.path);
    defer tree.deinit(allocator);

    try std.testing.expect(!isExitCode(tree.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, tree.stderr, "Unknown scope: nope") != null);
}

test "cli: tree hides closed issues" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Open task", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Will close", "-s", "app" }, test_dir.path);
    defer a2.deinit(allocator);

    // Close the second issue
    const id2 = std.mem.trimEnd(u8, a2.stdout, "\n");
    const close = try runDot(allocator, &.{ "close", id2 }, test_dir.path);
    defer close.deinit(allocator);

    const tree = try runDot(allocator, &.{"tree"}, test_dir.path);
    defer tree.deinit(allocator);

    try std.testing.expect(isExitCode(tree.term, 0));
    // Only 1 open issue remains visible
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "app (1 open)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "Open task") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "Will close") == null);
}

test "cli: tree shows empty scopes" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    // Create an issue then close it so the scope dir exists but has 0 visible issues
    const a1 = try runDot(allocator, &.{ "open", "Temp", "-s", "empty" }, test_dir.path);
    defer a1.deinit(allocator);
    const id = std.mem.trimEnd(u8, a1.stdout, "\n");
    const close = try runDot(allocator, &.{ "close", id }, test_dir.path);
    defer close.deinit(allocator);

    const tree = try runDot(allocator, &.{"tree"}, test_dir.path);
    defer tree.deinit(allocator);

    try std.testing.expect(isExitCode(tree.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "empty (0 open)") != null);
}

test "cli: tree shows active issues with open count" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Open task", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Active task", "-s", "app" }, test_dir.path);
    defer a2.deinit(allocator);

    // Start the second issue (becomes active)
    const id2 = std.mem.trimEnd(u8, a2.stdout, "\n");
    const start = try runDot(allocator, &.{ "start", id2 }, test_dir.path);
    defer start.deinit(allocator);

    const tree = try runDot(allocator, &.{"tree"}, test_dir.path);
    defer tree.deinit(allocator);

    try std.testing.expect(isExitCode(tree.term, 0));
    // Both open + active count together
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "app (2 open)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "Open task") != null);
    try std.testing.expect(std.mem.indexOf(u8, tree.stdout, "Active task") != null);
}

test "cli: block adds a blocking dependency" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Setup DB", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Fix login", "-s", "app" }, test_dir.path);
    defer a2.deinit(allocator);

    const id1 = std.mem.trimEnd(u8, a1.stdout, "\n");
    const id2 = std.mem.trimEnd(u8, a2.stdout, "\n");

    // Block id2 by id1
    const block = try runDot(allocator, &.{ "block", id2, id1 }, test_dir.path);
    defer block.deinit(allocator);

    try std.testing.expect(isExitCode(block.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, block.stdout, "blocked by") != null);

    // id2 should now be excluded from ready list (blocked)
    const ready = try runDot(allocator, &.{"ready"}, test_dir.path);
    defer ready.deinit(allocator);

    try std.testing.expect(isExitCode(ready.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, ready.stdout, "Fix login") == null);
    try std.testing.expect(std.mem.indexOf(u8, ready.stdout, "Setup DB") != null);
}

test "cli: unblock removes a blocking dependency" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Setup DB", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Fix login", "-s", "app" }, test_dir.path);
    defer a2.deinit(allocator);

    const id1 = std.mem.trimEnd(u8, a1.stdout, "\n");
    const id2 = std.mem.trimEnd(u8, a2.stdout, "\n");

    const block1 = try runDot(allocator, &.{ "block", id2, id1 }, test_dir.path);
    defer block1.deinit(allocator);

    // Verify blocked
    const ready1 = try runDot(allocator, &.{"ready"}, test_dir.path);
    defer ready1.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, ready1.stdout, "Fix login") == null);

    // Unblock
    const unblock = try runDot(allocator, &.{ "unblock", id2, id1 }, test_dir.path);
    defer unblock.deinit(allocator);

    try std.testing.expect(isExitCode(unblock.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, unblock.stdout, "no longer blocked by") != null);

    // id2 should now appear in ready list
    const ready2 = try runDot(allocator, &.{"ready"}, test_dir.path);
    defer ready2.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, ready2.stdout, "Fix login") != null);
}

test "cli: unblock unknown dependency fails" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Task A", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Task B", "-s", "app" }, test_dir.path);
    defer a2.deinit(allocator);

    const id1 = std.mem.trimEnd(u8, a1.stdout, "\n");
    const id2 = std.mem.trimEnd(u8, a2.stdout, "\n");

    // No dependency exists — unblock should fail
    const unblock = try runDot(allocator, &.{ "unblock", id2, id1 }, test_dir.path);
    defer unblock.deinit(allocator);

    try std.testing.expect(!isExitCode(unblock.term, 0));
}

test "cli: start warns when issue is blocked" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Setup DB", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Fix login", "-s", "app" }, test_dir.path);
    defer a2.deinit(allocator);

    const id1 = std.mem.trimEnd(u8, a1.stdout, "\n");
    const id2 = std.mem.trimEnd(u8, a2.stdout, "\n");

    const block2 = try runDot(allocator, &.{ "block", id2, id1 }, test_dir.path);
    defer block2.deinit(allocator);

    // Start the blocked issue — should succeed but warn
    const start = try runDot(allocator, &.{ "start", id2 }, test_dir.path);
    defer start.deinit(allocator);

    try std.testing.expect(isExitCode(start.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, start.stdout, "Warning") != null);
    try std.testing.expect(std.mem.indexOf(u8, start.stdout, "Setup DB") != null);
}

test "cli: start with no blockers produces no warning" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Clean task", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);

    const id1 = std.mem.trimEnd(u8, a1.stdout, "\n");

    const start = try runDot(allocator, &.{ "start", id1 }, test_dir.path);
    defer start.deinit(allocator);

    try std.testing.expect(isExitCode(start.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, start.stdout, "Warning") == null);
    try std.testing.expect(start.stdout.len == 0);
}

test "cli: show displays blocked-by section" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Setup DB", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Fix login", "-s", "app" }, test_dir.path);
    defer a2.deinit(allocator);

    const id1 = std.mem.trimEnd(u8, a1.stdout, "\n");
    const id2 = std.mem.trimEnd(u8, a2.stdout, "\n");

    const block3 = try runDot(allocator, &.{ "block", id2, id1 }, test_dir.path);
    defer block3.deinit(allocator);

    // show id2 — should list id1 under "Blocked by"
    const show = try runDot(allocator, &.{ "show", id2 }, test_dir.path);
    defer show.deinit(allocator);

    try std.testing.expect(isExitCode(show.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Blocked by:") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Setup DB") != null);
}

test "cli: show displays blocks section" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Setup DB", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const a2 = try runDot(allocator, &.{ "open", "Fix login", "-s", "app" }, test_dir.path);
    defer a2.deinit(allocator);

    const id1 = std.mem.trimEnd(u8, a1.stdout, "\n");
    const id2 = std.mem.trimEnd(u8, a2.stdout, "\n");

    const block4 = try runDot(allocator, &.{ "block", id2, id1 }, test_dir.path);
    defer block4.deinit(allocator);

    // show id1 — should list id2 under "Blocks"
    const show = try runDot(allocator, &.{ "show", id1 }, test_dir.path);
    defer show.deinit(allocator);

    try std.testing.expect(isExitCode(show.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Blocks:") != null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Fix login") != null);
}

test "cli: show with no dependencies omits dependency sections" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    _ = try runDot(allocator, &.{"init"}, test_dir.path);

    const a1 = try runDot(allocator, &.{ "open", "Standalone", "-s", "app" }, test_dir.path);
    defer a1.deinit(allocator);
    const id1 = std.mem.trimEnd(u8, a1.stdout, "\n");

    const show = try runDot(allocator, &.{ "show", id1 }, test_dir.path);
    defer show.deinit(allocator);

    try std.testing.expect(isExitCode(show.term, 0));
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Blocked by:") == null);
    try std.testing.expect(std.mem.indexOf(u8, show.stdout, "Blocks:") == null);
}

test "cli: unknown command fails with error" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const fix = runDot(allocator, &.{ "fix", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("fix: {}", .{err});
    };
    defer fix.deinit(allocator);

    try std.testing.expect(!isExitCode(fix.term, 0));
    try std.testing.expect(fix.stderr.len > 0);
}
