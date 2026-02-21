const std = @import("std");
const h = @import("test_helpers.zig");

const storage_mod = h.storage_mod;
const Status = h.Status;
const Issue = h.Issue;
const fixed_timestamp = h.fixed_timestamp;
const makeTestIssue = h.makeTestIssue;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const openTestStorage = h.openTestStorage;

test "storage: dependency cycle rejected" {
    // Test cycle detection at storage level
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    // Create two issues
    const issue_a = makeTestIssue("test-001", .open);
    ts.storage.createIssue(issue_a) catch |err| {
        std.debug.panic("create A: {}", .{err});
    };

    const issue_b = makeTestIssue("test-002", .open);
    ts.storage.createIssue(issue_b) catch |err| {
        std.debug.panic("create B: {}", .{err});
    };

    // Add A depends on B (A->B)
    ts.storage.addDependency("test-001", "test-002", "blockers") catch |err| {
        std.debug.panic("add A->B: {}", .{err});
    };

    // Try to add B depends on A (B->A) - should fail with DependencyCycle
    const cycle_result = ts.storage.addDependency("test-002", "test-001", "blockers");
    try std.testing.expectError(error.DependencyCycle, cycle_result);
}

test "storage: delete cascade unblocks dependents" {
    // Test that deleting a blocker unblocks its dependents
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    // Create blocker issue
    const blocker = makeTestIssue("blocker-001", .open);
    ts.storage.createIssue(blocker) catch |err| {
        std.debug.panic("create blocker: {}", .{err});
    };

    // Create dependent issue
    const dependent = makeTestIssue("dependent-002", .open);
    ts.storage.createIssue(dependent) catch |err| {
        std.debug.panic("create dependent: {}", .{err});
    };

    // Add dependency: dependent blocked by blocker
    ts.storage.addDependency("dependent-002", "blocker-001", "blockers") catch |err| {
        std.debug.panic("add dep: {}", .{err});
    };

    // Verify dependent is NOT ready (blocked)
    const ready1 = ts.storage.getReadyIssues() catch |err| {
        std.debug.panic("ready1: {}", .{err});
    };
    defer storage_mod.freeIssues(allocator, ready1);
    try std.testing.expectEqual(@as(usize, 1), ready1.len); // Only blocker is ready

    // Delete blocker
    ts.storage.deleteIssue("blocker-001") catch |err| {
        std.debug.panic("delete: {}", .{err});
    };

    // Verify dependent is now ready (unblocked)
    const ready2 = ts.storage.getReadyIssues() catch |err| {
        std.debug.panic("ready2: {}", .{err});
    };
    defer storage_mod.freeIssues(allocator, ready2);
    try std.testing.expectEqual(@as(usize, 1), ready2.len);
    try std.testing.expectEqualStrings("dependent-002", ready2[0].id);
}

test "storage: delete cleans up dependency refs" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    // Create blocker + external dependent
    const blocker = makeTestIssue("test-020", .open);
    try ts.storage.createIssue(blocker);

    const external = makeTestIssue("test-021", .open);
    try ts.storage.createIssue(external);
    try ts.storage.addDependency("test-021", "test-020", "blockers");

    // Verify external is blocked
    const ready1 = try ts.storage.getReadyIssues();
    defer storage_mod.freeIssues(allocator, ready1);
    var external_ready = false;
    for (ready1) |r| {
        if (std.mem.eql(u8, r.id, "test-021")) external_ready = true;
    }
    try std.testing.expect(!external_ready);

    try ts.storage.deleteIssue("test-020");

    // Verify external is now unblocked (child ref was cleaned up)
    const ready2 = try ts.storage.getReadyIssues();
    defer storage_mod.freeIssues(allocator, ready2);
    try std.testing.expectEqual(@as(usize, 1), ready2.len);
    try std.testing.expectEqualStrings("test-021", ready2[0].id);

    // Verify external's blockers array is now empty
    var ext = try ts.storage.getIssue("test-021") orelse return error.TestUnexpectedResult;
    defer ext.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), ext.blockers.len);
}

test "storage: ID prefix resolution" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    // Create an issue with a known ID
    const issue: Issue = .{
        .id = "abc-123",
        .title = "Test",
        .description = "",
        .status = .open,
        .priority = 2,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blockers = &.{},
    };
    ts.storage.createIssue(issue) catch |err| {
        std.debug.panic("create: {}", .{err});
    };

    // Resolve by prefix
    const resolved = ts.storage.resolveId("abc") catch |err| {
        std.debug.panic("resolve: {}", .{err});
    };
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("abc-123", resolved);
}

test "storage: ambiguous ID prefix errors" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    // Create two issues with same prefix
    const issue1: Issue = .{
        .id = "abc-111",
        .title = "Test1",
        .description = "",
        .status = .open,
        .priority = 2,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blockers = &.{},
    };
    ts.storage.createIssue(issue1) catch |err| {
        std.debug.panic("create1: {}", .{err});
    };

    const issue2: Issue = .{
        .id = "abc-222",
        .title = "Test2",
        .description = "",
        .status = .open,
        .priority = 2,
        .created_at = fixed_timestamp,
        .closed_at = null,
        .close_reason = null,
        .blockers = &.{},
    };
    ts.storage.createIssue(issue2) catch |err| {
        std.debug.panic("create2: {}", .{err});
    };

    // Resolve with ambiguous prefix should error
    const result = ts.storage.resolveId("abc-");
    try std.testing.expectError(error.AmbiguousId, result);
}

test "storage: resolve active ignores archived match" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    const active = makeTestIssue("test-031", .open);
    ts.storage.createIssue(active) catch |err| {
        std.debug.panic("create active: {}", .{err});
    };
    const archived = makeTestIssue("test-032", .closed);
    ts.storage.createIssue(archived) catch |err| {
        std.debug.panic("create archived: {}", .{err});
    };
    try ts.storage.archiveIssue("test-032");

    const resolved = ts.storage.resolveIdActive("test-03") catch |err| {
        std.debug.panic("resolve: {}", .{err});
    };
    defer allocator.free(resolved);

    try std.testing.expectEqualStrings("test-031", resolved);
}

test "storage: missing required frontmatter fields rejected" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    try ts.storage.dots_dir.makeDir("bad");

    // Write file with missing title
    const no_title =
        \\---
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\created-at: 2024-01-01T00:00:00Z
        \\---
    ;
    try ts.storage.dots_dir.writeFile(.{ .sub_path = "bad/bad-001.md", .data = no_title });

    // Should fail to read
    const result1 = ts.storage.getIssue("bad-001");
    try std.testing.expectError(error.InvalidFrontmatter, result1);

    // Write file with missing created-at
    const no_created =
        \\---
        \\title: Has title
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\---
    ;
    try ts.storage.dots_dir.writeFile(.{ .sub_path = "bad/bad-002.md", .data = no_created });

    // Should fail to read
    const result2 = ts.storage.getIssue("bad-002");
    try std.testing.expectError(error.InvalidFrontmatter, result2);
}

test "storage: parses CRLF frontmatter" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    try ts.storage.dots_dir.makeDir("crlf");

    const crlf_frontmatter =
        "---\r\n" ++
        "title: Windows newline test\r\n" ++
        "status: open\r\n" ++
        "priority: 2\r\n" ++
        "issue-type: task\r\n" ++
        "created-at: 2024-01-01T00:00:00Z\r\n" ++
        "---\r\n" ++
        "Body from Windows\r\n";
    try ts.storage.dots_dir.writeFile(.{ .sub_path = "crlf/crlf-001.md", .data = crlf_frontmatter });

    var issue = (try ts.storage.getIssue("crlf-001")) orelse return error.TestUnexpectedResult;
    defer issue.deinit(allocator);

    try std.testing.expectEqualStrings("Windows newline test", issue.title);
    try std.testing.expectEqualStrings("Body from Windows", issue.description);
}

test "storage: invalid block id rejected" {
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    try ts.storage.dots_dir.makeDir("bad");

    const bad_blocks =
        \\---
        \\title: Bad blocks
        \\status: open
        \\priority: 2
        \\issue-type: task
        \\created-at: 2024-01-01T00:00:00Z
        \\blockers:
        \\  - ../nope
        \\---
    ;
    try ts.storage.dots_dir.writeFile(.{ .sub_path = "bad/bad-003.md", .data = bad_blocks });

    const result = ts.storage.getIssue("bad-003");
    try std.testing.expectError(error.InvalidFrontmatter, result);
}

test "storage: quoted timestamp roundtrip does not double-escape" {
    // Regression test to verify that timestamps stored with quotes are
    // unescaped when read, preventing escape accumulation across save cycles.
    const allocator = std.testing.allocator;

    var test_dir = setupTestDirOrPanic(allocator);
    defer test_dir.cleanup();

    var ts = openTestStorage(allocator, &test_dir);
    defer ts.deinit();

    try ts.storage.dots_dir.makeDir("test");

    // Write file with a QUOTED timestamp (simulating the bug that happened after first save with quoting)
    // The timestamp is stored WITH quotes in the file - this is the "bad" state
    const quoted_timestamp_file =
        \\---
        \\title: Test issue
        \\status: open
        \\priority: 2
        \\created-at: "2024-01-01T00:00:00Z"
        \\---
    ;
    try ts.storage.dots_dir.writeFile(.{ .sub_path = "test/test-001.md", .data = quoted_timestamp_file });

    // First read - should unescape the quotes
    var issue1 = (try ts.storage.getIssue("test-001")) orelse return error.TestUnexpectedResult;
    defer issue1.deinit(allocator);

    // The timestamp should be unescaped (without quotes) - this is the core fix!
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", issue1.created_at);

    // Now create a NEW issue with this data (simulating writing it back to disk)
    // If the parsing is correct, this should serialize cleanly WITHOUT quotes
    const issue2: Issue = .{
        .id = "test-002",
        .title = issue1.title,
        .description = issue1.description,
        .status = issue1.status,
        .priority = issue1.priority,
        .created_at = issue1.created_at,
        .closed_at = null,
        .close_reason = null,
        .blockers = &.{},
    };
    try ts.storage.createIssue(issue2);

    // Read the new issue - should have clean timestamp
    var issue3 = (try ts.storage.getIssue("test-002")) orelse return error.TestUnexpectedResult;
    defer issue3.deinit(allocator);

    // The timestamp should still be clean (not double-escaped)
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", issue3.created_at);

    // Do another round-trip to be sure - create issue 3 from issue 2's data
    const issue4: Issue = .{
        .id = "test-003",
        .title = issue3.title,
        .description = issue3.description,
        .status = issue3.status,
        .priority = issue3.priority,
        .created_at = issue3.created_at,
        .closed_at = null,
        .close_reason = null,
        .blockers = &.{},
    };
    try ts.storage.createIssue(issue4);

    var issue5 = (try ts.storage.getIssue("test-003")) orelse return error.TestUnexpectedResult;
    defer issue5.deinit(allocator);

    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", issue5.created_at);
}
