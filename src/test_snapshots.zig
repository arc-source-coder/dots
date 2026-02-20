const std = @import("std");
const fs = std.fs;
const h = @import("test_helpers.zig");

const OhSnap = h.OhSnap;
const runDot = h.runDot;
const trimNewline = h.trimNewline;
const normalizeTreeOutput = h.normalizeTreeOutput;
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
        \\test_snapshots.test.snap: simple struct.TestStruct
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
        "add", "Test snapshot task",
        "-p",  "1",
        "-d",  "This is a description",
        "-s",  "test",
    }, test_dir.path) catch |err| {
        std.debug.panic("add: {}", .{err});
    };
    defer add.deinit(allocator);

    const id = trimNewline(add.stdout);

    // Read the markdown file
    const md_path = std.fmt.allocPrint(allocator, "{s}/.dots/{s}.md", .{ test_dir.path, id }) catch |err| {
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
        \\issue-type: task
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

    // Add parent
    const parent = runDot(allocator, &.{ "add", "Parent task", "-s", "test" }, test_dir.path) catch |err| {
        std.debug.panic("add parent: {}", .{err});
    };
    defer parent.deinit(allocator);

    const parent_id = trimNewline(parent.stdout);

    // Add children
    const child1_result = runDot(allocator, &.{ "add", "Child one", "-P", parent_id, "-s", "test" }, test_dir.path);
    const child1 = child1_result catch |err| {
        std.debug.panic("add child1: {}", .{err});
    };
    defer child1.deinit(allocator);
    const child1_id = trimNewline(child1.stdout);

    const child2_result = runDot(allocator, &.{ "add", "Child two", "-P", parent_id, "-a", child1_id, "-s", "test" }, test_dir.path);
    const child2 = child2_result catch |err| {
        std.debug.panic("add child2: {}", .{err});
    };
    defer child2.deinit(allocator);

    // Get tree output
    const tree = runDot(allocator, &.{"tree"}, test_dir.path) catch |err| {
        std.debug.panic("tree: {}", .{err});
    };
    defer tree.deinit(allocator);

    const normalized = try normalizeTreeOutput(allocator, tree.stdout);
    defer allocator.free(normalized);

    const oh: OhSnap = .{};
    // Tree shows parent with children indented
    try oh.snap(@src(),
        \\[]u8
        \\  "[ID] ○ Parent task
        \\  └─ [ID] ○ Child one
        \\  └─ [ID] ○ Child two (blocked)
        \\"
    ).expectEqual(normalized);
}
