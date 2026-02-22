const std = @import("std");
const fs = std.fs;
const h = @import("helpers.zig");

const OhSnap = h.OhSnap;
const runDot = h.runDot;
const setupTestDirOrPanic = h.setupTestDirOrPanic;

test "snap: simple struct" {
    // Test basic ohsnap functionality with a simple struct
    const TestStruct = struct {
        name: []const u8,
        value: i32,
    };
    const data: TestStruct = .{
        .name = "test",
        .value = 42,
    };
    const oh: OhSnap = .{};
    try oh.snap(
        @src(),
        \\snapshots.test.test.snap: simple struct.TestStruct
        \\  .name: []const u8
        \\    "test"
        \\  .value: i32 = 42
        ,
    ).expectEqual(data);
}

test "snap: markdown frontmatter format" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const init = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Add a task with specific parameters
    const add = runDot(allocator, &.{
        "open", "Test snapshot task",
        "-p",   "1",
        "-d",   "This is a description",
        "-s",   "test",
    }, test_dir.path) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);

    const id = std.mem.trimEnd(u8, add.stdout, "\n");

    // Read the markdown file
    const md_path = std.fmt.allocPrint(allocator, "{s}/.dots/test/{s}.md", .{ test_dir.path, id }) catch |err| {
        std.debug.panic("path: {}", .{err});
    };
    defer allocator.free(md_path);

    const content = fs.cwd().readFileAlloc(allocator, md_path, 64 * 1024) catch |err| {
        std.debug.panic("read: {}", .{err});
    };
    defer allocator.free(content);

    // Normalize: replace dynamic ID and timestamp with placeholders
    var normalized: std.ArrayList(u8) = .{};
    defer normalized.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try normalized.append(allocator, '\n');
        first = false;

        if (std.mem.startsWith(u8, line, "created-at:")) {
            try normalized.appendSlice(allocator, "created-at: <TIMESTAMP>");
        } else {
            try normalized.appendSlice(allocator, line);
        }
    }

    const oh: OhSnap = .{};
    try oh.snap(@src(),
        \\[]u8
        \\  "---
        \\title: Test snapshot task
        \\status: open
        \\priority: 1
        \\created-at: <TIMESTAMP>
        \\---
        \\
        \\This is a description
        \\"
    ).expectEqual(normalized.items);
}

test "snap: tree output format" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    const init = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
        std.debug.panic("init: {}", .{err});
    };
    defer init.deinit(allocator);

    // Create issues across two scopes
    const a1 = runDot(allocator, &.{ "open", "Fix login", "-s", "app", "-p", "1" }, test_dir.path) catch |err| {
        std.debug.panic("open app-001: {}", .{err});
    };
    defer a1.deinit(allocator);

    const a2 = runDot(allocator, &.{ "open", "Setup DB", "-s", "app", "-p", "2" }, test_dir.path) catch |err| {
        std.debug.panic("open app-002: {}", .{err});
    };
    defer a2.deinit(allocator);

    const d1 = runDot(allocator, &.{ "open", "API docs", "-s", "docs" }, test_dir.path) catch |err| {
        std.debug.panic("open docs-001: {}", .{err});
    };
    defer d1.deinit(allocator);

    const tree = runDot(allocator, &.{"tree"}, test_dir.path) catch |err| {
        std.debug.panic("tree: {}", .{err});
    };
    defer tree.deinit(allocator);

    try std.testing.expect(tree.stderr.len == 0);

    const oh: OhSnap = .{};
    try oh.snap(@src(),
        \\[]u8
        \\  "app (2 open)
        \\  ├─ app-001 ○ Fix login
        \\  └─ app-002 ○ Setup DB
        \\docs (1 open)
        \\  └─ docs-001 ○ API docs
        \\"
    ).expectEqual(tree.stdout);
}
