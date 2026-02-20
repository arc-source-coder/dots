const std = @import("std");
const h = @import("test_helpers.zig");

const storage_mod = h.storage_mod;
const zc = h.zc;
const Status = h.Status;
const Issue = h.Issue;
const LifecycleOracle = h.LifecycleOracle;
const OpType = h.OpType;
const fixed_timestamp = h.fixed_timestamp;
const makeTestIssue = h.makeTestIssue;
const runDot = h.runDot;
const isExitCode = h.isExitCode;
const trimNewline = h.trimNewline;
const oracleReady = h.oracleReady;
const oracleListCount = h.oracleListCount;
const oracleUpdateClosed = h.oracleUpdateClosed;
const setupTestDirOrPanic = h.setupTestDirOrPanic;
const openTestStorage = h.openTestStorage;

test "prop: ready issues match oracle" {
    const ReadyCase = struct {
        statuses: [4]Status,
        deps: [4][4]bool,
    };

    try zc.check(struct {
        fn property(args: ReadyCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            var ts = openTestStorage(allocator, &test_dir);
            defer ts.deinit();

            var id_bufs: [4][16]u8 = undefined;
            var ids: [4][]const u8 = undefined;

            for (0..4) |i| {
                ids[i] = std.fmt.bufPrint(&id_bufs[i], "t-{d:0>3}", .{i}) catch |err| {
                    std.debug.panic("id format: {}", .{err});
                };

                const issue = makeTestIssue(ids[i], args.statuses[i]);
                ts.storage.createIssue(issue) catch |err| {
                    std.debug.panic("create issue: {}", .{err});
                };
            }

            for (0..4) |i| {
                for (0..4) |j| {
                    if (args.deps[i][j]) {
                        ts.storage.addDependency(ids[i], ids[j], "blocks") catch |err| switch (err) {
                            error.DependencyCycle => {}, // Skip cycles
                            else => std.debug.panic("add dependency: {}", .{err}),
                        };
                    }
                }
            }

            const issues = ts.storage.getReadyIssues() catch |err| {
                std.debug.panic("get ready: {}", .{err});
            };
            defer storage_mod.freeIssues(allocator, issues);

            const expected = oracleReady(args.statuses, args.deps);
            var found = [_]bool{ false, false, false, false };

            for (issues) |issue| {
                var matched = false;
                for (0..4) |i| {
                    if (std.mem.eql(u8, issue.id, ids[i])) {
                        matched = true;
                        found[i] = true;
                        break;
                    }
                }
                if (!matched) return false;
            }

            for (0..4) |i| {
                if (expected[i] != found[i]) return false;
            }

            return true;
        }
    }.property, .{ .iterations = 40, .seed = 0xD07D07 });
}

test "prop: listIssues filter matches oracle" {
    const ListCase = struct {
        statuses: [6]Status,
    };

    try zc.check(struct {
        fn property(args: ListCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            var ts = openTestStorage(allocator, &test_dir);
            defer ts.deinit();

            var id_bufs: [6][16]u8 = undefined;
            var ids: [6][]const u8 = undefined;

            for (0..6) |i| {
                ids[i] = std.fmt.bufPrint(&id_bufs[i], "i-{d:0>3}", .{i}) catch |err| {
                    std.debug.panic("id format: {}", .{err});
                };

                const issue = makeTestIssue(ids[i], args.statuses[i]);
                ts.storage.createIssue(issue) catch |err| {
                    std.debug.panic("create issue: {}", .{err});
                };
            }

            const filters = [_]Status{ .open, .active, .closed };
            for (filters) |filter| {
                const issues = ts.storage.listIssues(filter) catch |err| {
                    std.debug.panic("list issues: {}", .{err});
                };
                defer storage_mod.freeIssues(allocator, issues);

                const expected_count = oracleListCount(args.statuses, filter);
                if (issues.len != expected_count) return false;

                for (issues) |issue| {
                    if (issue.status != filter) return false;
                }
            }

            return true;
        }
    }.property, .{ .iterations = 40, .seed = 0xC0FFEE });
}

test "prop: update done sets closed_at" {
    const UpdateCase = struct {
        done: bool,
    };

    try zc.check(struct {
        fn property(args: UpdateCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            const init = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
                std.debug.panic("init: {}", .{err});
            };
            defer init.deinit(allocator);

            const add = runDot(allocator, &.{ "add", "Update done test", "-s", "test" }, test_dir.path) catch |err| {
                std.debug.panic("add: {}", .{err});
            };
            defer add.deinit(allocator);

            const id = trimNewline(add.stdout);
            if (id.len == 0) return false;

            const status = if (args.done) "done" else "open";
            const update = runDot(allocator, &.{ "update", id, "--status", status }, test_dir.path) catch |err| {
                std.debug.panic("update: {}", .{err});
            };
            defer update.deinit(allocator);
            if (!isExitCode(update.term, 0)) return false;

            const show = runDot(allocator, &.{ "show", id }, test_dir.path) catch |err| {
                std.debug.panic("show: {}", .{err});
            };
            defer show.deinit(allocator);
            if (!isExitCode(show.term, 0)) return false;

            const expects_closed = oracleUpdateClosed(args.done);
            if (expects_closed) {
                if (std.mem.indexOf(u8, show.stdout, "Closed:") == null) return false;
                if (std.mem.indexOf(u8, show.stdout, "Status:   done") == null) return false;
            } else {
                if (std.mem.indexOf(u8, show.stdout, "Closed:") != null) return false;
                if (std.mem.indexOf(u8, show.stdout, "Status:   open") == null) return false;
            }

            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0xD0DE });
}

test "prop: unknown id errors" {
    const UnknownCase = struct {
        raw: [8]u8,
    };

    try zc.check(struct {
        fn property(args: UnknownCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            const init = runDot(allocator, &.{"init"}, test_dir.path) catch |err| {
                std.debug.panic("init: {}", .{err});
            };
            defer init.deinit(allocator);

            var id_buf: [8]u8 = undefined;
            for (args.raw, 0..) |byte, i| {
                id_buf[i] = @as(u8, 'a') + (byte % 26);
            }
            const id = id_buf[0..];

            const on_result = runDot(allocator, &.{ "on", id }, test_dir.path) catch |err| {
                std.debug.panic("on: {}", .{err});
            };
            defer on_result.deinit(allocator);
            if (!isExitCode(on_result.term, 1)) return false;
            if (std.mem.indexOf(u8, on_result.stderr, "Issue not found") == null) return false;

            const rm_result = runDot(allocator, &.{ "rm", id }, test_dir.path) catch |err| {
                std.debug.panic("rm: {}", .{err});
            };
            defer rm_result.deinit(allocator);
            if (!isExitCode(rm_result.term, 1)) return false;
            if (std.mem.indexOf(u8, rm_result.stderr, "Issue not found") == null) return false;

            return true;
        }
    }.property, .{ .iterations = 20, .seed = 0xBAD1D });
}

test "prop: lifecycle simulation maintains invariants" {
    // Simulate random sequences of operations and verify state consistency
    const LifecycleCase = struct {
        // Sequence of operations: each is (op_type, target_idx, secondary_idx, priority)
        ops: [12]struct { op: u3, target: u3, secondary: u3, priority: u3 },
    };

    try zc.check(struct {
        fn property(args: LifecycleCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            var ts = openTestStorage(allocator, &test_dir);
            defer ts.deinit();

            var oracle: LifecycleOracle = .{};
            var ids: [LifecycleOracle.max_issues]?[]const u8 = [_]?[]const u8{null} ** LifecycleOracle.max_issues;
            var id_storage: [LifecycleOracle.max_issues][32]u8 = undefined;

            // Execute operations
            for (args.ops) |op_data| {
                const idx = @as(usize, op_data.target) % LifecycleOracle.max_issues;
                const secondary = @as(usize, op_data.secondary) % LifecycleOracle.max_issues;
                const op: OpType = switch (op_data.op % 6) {
                    0 => .create,
                    1 => .delete,
                    2 => .set_open,
                    3 => .set_active,
                    4 => .set_closed,
                    5 => .add_dep,
                    else => unreachable,
                };

                switch (op) {
                    .create => {
                        if (!oracle.exists[idx]) {
                            const id = std.fmt.bufPrint(&id_storage[idx], "issue-{d}", .{idx}) catch continue;
                            ids[idx] = id;
                            const issue = Issue{
                                .id = id,
                                .title = id,
                                .description = "",
                                .status = .open,
                                .priority = op_data.priority % 5,
                                .created_at = fixed_timestamp,
                                .closed_at = null,
                                .close_reason = null,
                                .blocks = &.{},
                            };
                            ts.storage.createIssue(issue) catch continue;
                            oracle.create(idx, op_data.priority % 5, null);
                        }
                    },
                    .delete => {
                        if (oracle.exists[idx]) {
                            ts.storage.deleteIssue(ids[idx].?) catch continue;
                            oracle.delete(idx);
                        }
                    },
                    .set_open => {
                        if (oracle.exists[idx]) {
                            ts.storage.updateStatus(ids[idx].?, .open, null, null) catch continue;
                            oracle.setStatus(idx, .open);
                        }
                    },
                    .set_active => {
                        if (oracle.exists[idx]) {
                            ts.storage.updateStatus(ids[idx].?, .active, null, null) catch continue;
                            oracle.setStatus(idx, .active);
                        }
                    },
                    .set_closed => {
                        if (oracle.exists[idx] and oracle.canClose(idx)) {
                            ts.storage.updateStatus(ids[idx].?, .closed, fixed_timestamp, null) catch continue;
                            oracle.setStatus(idx, .closed);
                        }
                    },
                    .add_dep => {
                        if (oracle.exists[idx] and oracle.exists[secondary] and idx != secondary) {
                            if (ts.storage.addDependency(ids[idx].?, ids[secondary].?, "blocks")) {
                                _ = oracle.addDep(idx, secondary);
                            } else |err| switch (err) {
                                error.DependencyCycle => {},
                                else => continue,
                            }
                        }
                    },
                }
            }

            // Verify invariants

            // 1. Ready count matches oracle
            const ready_issues = ts.storage.getReadyIssues() catch return false;
            defer storage_mod.freeIssues(allocator, ready_issues);
            if (ready_issues.len != oracle.readyCount()) return false;

            // 2. Status counts match
            for ([_]Status{ .open, .active, .closed }) |status| {
                const issues = ts.storage.listIssues(status) catch return false;
                defer storage_mod.freeIssues(allocator, issues);
                if (issues.len != oracle.countByStatus(status)) return false;
            }

            // 3. Each existing non-archived issue has correct status
            for (0..LifecycleOracle.max_issues) |i| {
                if (oracle.exists[i] and !oracle.archived[i]) {
                    const maybe_issue = ts.storage.getIssue(ids[i].?) catch return false;
                    var issue = maybe_issue orelse return false;
                    defer issue.deinit(allocator);
                    if (issue.status != oracle.statuses[i]) return false;
                    // Closed issues must have closed_at
                    if (issue.status == .closed and issue.closed_at == null) return false;
                }
            }

            return true;
        }
    }.property, .{ .iterations = 50, .seed = 0xCAFE });
}

test "prop: transitive blocking chains" {
    // Test that blocking propagates through dependency chains
    // A -> B -> C -> D: if D is open, A/B/C should all be blocked
    const ChainCase = struct {
        chain_length: u3, // 2-7
        blocker_position: u3, // which one in chain is open (rest closed)
        target_position: u3, // which one to check if blocked
    };

    try zc.check(struct {
        fn property(args: ChainCase) bool {
            const allocator = std.testing.allocator;
            const chain_len = @max(2, (args.chain_length % 6) + 2); // 2-7

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            var ts = openTestStorage(allocator, &test_dir);
            defer ts.deinit();

            // Create chain: issue[0] -> issue[1] -> ... -> issue[n-1]
            var id_bufs: [8][16]u8 = undefined;
            var ids: [8][]const u8 = undefined;

            const blocker_pos = args.blocker_position % chain_len;
            const target_pos = args.target_position % chain_len;

            for (0..chain_len) |i| {
                ids[i] = std.fmt.bufPrint(&id_bufs[i], "chain-{d}", .{i}) catch return false;
                // All closed except the blocker
                const status: Status = if (i == blocker_pos) .open else .closed;
                const closed_at: ?[]const u8 = if (status == .closed) fixed_timestamp else null;
                const issue: Issue = .{
                    .id = ids[i],
                    .title = ids[i],
                    .description = "",
                    .status = status,
                    .priority = 2,
                    .created_at = fixed_timestamp,
                    .closed_at = closed_at,
                    .close_reason = null,
                    .blocks = &.{},
                };
                ts.storage.createIssue(issue) catch return false;
            }

            // Create dependency chain: 0 depends on 1, 1 depends on 2, etc.
            for (0..chain_len - 1) |i| {
                ts.storage.addDependency(ids[i], ids[i + 1], "blocks") catch return false;
            }

            // Check if target is in ready list
            const ready = ts.storage.getReadyIssues() catch return false;
            defer storage_mod.freeIssues(allocator, ready);

            var target_in_ready = false;
            for (ready) |issue| {
                if (std.mem.eql(u8, issue.id, ids[target_pos])) {
                    target_in_ready = true;
                    break;
                }
            }

            // If target is open (== blocker_pos), it should be in ready iff not blocked
            // If target is closed, it should never be in ready
            if (target_pos == blocker_pos) {
                // Target is open, should be in ready iff not blocked by anything downstream
                // Since target IS the blocker, nothing blocks it
                return target_in_ready == true;
            } else {
                // Target is closed, never in ready
                return target_in_ready == false;
            }
        }
    }.property, .{ .iterations = 50, .seed = 0xFADE });
}

test "prop: closing issue succeeds with unrelated open issues" {
    const CloseCase = struct {
        other_statuses: [4]Status,
    };

    try zc.check(struct {
        fn property(args: CloseCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            var ts = openTestStorage(allocator, &test_dir);
            defer ts.deinit();

            const target = makeTestIssue("close-001", .open);
            ts.storage.createIssue(target) catch return false;

            var id_bufs: [4][16]u8 = undefined;
            for (0..4) |i| {
                const other_id = std.fmt.bufPrint(&id_bufs[i], "oth-{d:0>3}", .{i}) catch return false;
                const other = makeTestIssue(other_id, args.other_statuses[i]);
                ts.storage.createIssue(other) catch return false;
            }

            ts.storage.updateStatus("close-001", .closed, fixed_timestamp, null) catch return false;
            const maybe_closed = ts.storage.getIssue("close-001") catch return false;
            var closed = maybe_closed orelse return false;
            defer closed.deinit(allocator);
            return closed.status == .closed and closed.closed_at != null;
        }
    }.property, .{ .iterations = 30, .seed = 0xDAD });
}

test "prop: priority ordering in list" {
    // List should return issues sorted by priority (lower = higher priority)
    const PriorityCase = struct {
        priorities: [6]u3,
    };

    try zc.check(struct {
        fn property(args: PriorityCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            var ts = openTestStorage(allocator, &test_dir);
            defer ts.deinit();

            // Create issues with random priorities
            for (0..6) |i| {
                var id_buf: [16]u8 = undefined;
                const id = std.fmt.bufPrint(&id_buf, "pri-{d}", .{i}) catch return false;
                const issue: Issue = .{
                    .id = id,
                    .title = id,
                    .description = "",
                    .status = .open,
                    .priority = args.priorities[i] % 5,
                    .created_at = fixed_timestamp,
                    .closed_at = null,
                    .close_reason = null,
                    .blocks = &.{},
                };
                ts.storage.createIssue(issue) catch return false;
            }

            // Get list
            const issues = ts.storage.listIssues(.open) catch return false;
            defer storage_mod.freeIssues(allocator, issues);

            // Verify sorted by priority (ascending)
            var prev_priority: i64 = -1;
            for (issues) |issue| {
                if (issue.priority < prev_priority) return false;
                prev_priority = issue.priority;
            }

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0xACE });
}

test "prop: status transition state machine" {
    // Verify: closed issues have closed_at, open/active don't
    // Verify: reopening clears closed_at
    const TransitionCase = struct {
        transitions: [8]u2, // 0=open, 1=active, 2=closed
    };

    try zc.check(struct {
        fn property(args: TransitionCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            var ts = openTestStorage(allocator, &test_dir);
            defer ts.deinit();

            // Create issue
            const issue: Issue = .{
                .id = "transition-001",
                .title = "Transition Test",
                .description = "",
                .status = .open,
                .priority = 2,
                .created_at = fixed_timestamp,
                .closed_at = null,
                .close_reason = null,
                .blocks = &.{},
            };
            ts.storage.createIssue(issue) catch return false;

            // Apply transitions
            for (args.transitions) |t| {
                const status: Status = switch (t % 3) {
                    0 => .open,
                    1 => .active,
                    2 => .closed,
                    else => unreachable,
                };
                const closed_at: ?[]const u8 = if (status == .closed) fixed_timestamp else null;
                ts.storage.updateStatus("transition-001", status, closed_at, null) catch continue;

                // Verify invariant after each transition
                const maybe_current = ts.storage.getIssue("transition-001") catch return false;
                var current = maybe_current orelse return false;
                defer current.deinit(allocator);

                // Invariant: closed_at set iff status is closed
                if (current.status == .closed) {
                    if (current.closed_at == null) return false;
                } else {
                    if (current.closed_at != null) return false;
                }
            }

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0xDEED });
}

test "prop: search finds exactly matching issues" {
    const SearchCase = struct {
        // Create issues with titles containing these substrings
        has_foo: [4]bool,
        has_bar: [4]bool,
    };

    try zc.check(struct {
        fn property(args: SearchCase) bool {
            const allocator = std.testing.allocator;

            var test_dir = setupTestDirOrPanic(allocator);
            defer test_dir.cleanup();

            var ts = openTestStorage(allocator, &test_dir);
            defer ts.deinit();

            var foo_count: usize = 0;
            var bar_count: usize = 0;

            // Create issues
            for (0..4) |i| {
                var title_buf: [32]u8 = undefined;
                var len: usize = 0;

                // Build title
                const prefix = std.fmt.bufPrint(title_buf[len..], "Issue {d}", .{i}) catch return false;
                len += prefix.len;

                if (args.has_foo[i]) {
                    const foo = std.fmt.bufPrint(title_buf[len..], " foo", .{}) catch return false;
                    len += foo.len;
                    foo_count += 1;
                }
                if (args.has_bar[i]) {
                    const bar = std.fmt.bufPrint(title_buf[len..], " bar", .{}) catch return false;
                    len += bar.len;
                    bar_count += 1;
                }

                var id_buf: [16]u8 = undefined;
                const id = std.fmt.bufPrint(&id_buf, "search-{d}", .{i}) catch return false;
                const issue: Issue = .{
                    .id = id,
                    .title = title_buf[0..len],
                    .description = "",
                    .status = .open,
                    .priority = 2,
                    .created_at = fixed_timestamp,
                    .closed_at = null,
                    .close_reason = null,
                    .blocks = &.{},
                };
                ts.storage.createIssue(issue) catch return false;
            }

            // Search for "foo"
            const foo_results = ts.storage.searchIssues("foo") catch return false;
            defer storage_mod.freeIssues(allocator, foo_results);
            if (foo_results.len != foo_count) return false;

            // Search for "bar"
            const bar_results = ts.storage.searchIssues("bar") catch return false;
            defer storage_mod.freeIssues(allocator, bar_results);
            if (bar_results.len != bar_count) return false;

            return true;
        }
    }.property, .{ .iterations = 30, .seed = 0x5EED });
}
