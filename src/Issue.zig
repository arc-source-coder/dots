//! Pure data model and domain logic for issues.
//! No FS/IO dependencies.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const default_priority: i64 = 2;
const max_id_len = 128;

/// Issue domain errors
pub const IssueError = error{
    InvalidId,
    InvalidStatus,
    InvalidFrontmatter,
    IssueNotFound,
    IssueAlreadyExists,
    AmbiguousId,
};

/// Validates that an ID is safe for use in paths and YAML
pub fn validateId(id: []const u8) IssueError!void {
    if (id.len == 0) return IssueError.InvalidId;
    if (id.len > max_id_len) return IssueError.InvalidId;
    // Reject path traversal attempts
    if (std.mem.indexOf(u8, id, "/") != null) return IssueError.InvalidId;
    if (std.mem.indexOf(u8, id, "\\") != null) return IssueError.InvalidId;
    if (std.mem.indexOf(u8, id, "..") != null) return IssueError.InvalidId;
    if (std.mem.eql(u8, id, ".")) return IssueError.InvalidId;
    // Reject control characters and YAML-sensitive characters
    for (id) |c| {
        if (c < 0x20 or c == 0x7F) return IssueError.InvalidId;
        if (c == '#' or c == ':' or c == '\'' or c == '"') return IssueError.InvalidId;
    }
}

// Status enum with comptime string map
pub const Status = enum {
    open,
    active,
    closed,

    const map = std.StaticStringMap(Status).initComptime(.{
        .{ "open", .open },
        .{ "active", .active },
        .{ "closed", .closed },
        .{ "done", .closed }, // alias
    });

    pub fn parse(s: []const u8) ?Status {
        return map.get(s);
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .open => "open",
            .active => "active",
            .closed => "closed",
        };
    }

    pub fn display(self: Status) []const u8 {
        return switch (self) {
            .open => "open",
            .active => "active",
            .closed => "done",
        };
    }

    pub fn char(self: Status) u8 {
        return switch (self) {
            .open => 'o',
            .active => '>',
            .closed => 'x',
        };
    }

    pub fn symbol(self: Status) []const u8 {
        return switch (self) {
            .open => "○",
            .active => ">",
            .closed => "✓",
        };
    }
};

pub const Issue = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8,
    status: Status,
    priority: i64,
    created_at: []const u8,
    closed_at: ?[]const u8,
    close_reason: ?[]const u8,
    blockers: []const []const u8,

    /// Compare issues by priority (ascending) then created_at (ascending)
    pub fn order(_: void, a: Issue, b: Issue) bool {
        if (a.priority != b.priority) return a.priority < b.priority;
        return std.mem.order(u8, a.created_at, b.created_at) == .lt;
    }

    /// Create a copy with updated status fields (borrows all strings)
    pub fn withStatus(self: Issue, status: Status, closed_at: ?[]const u8, close_reason: ?[]const u8) Issue {
        return .{
            .id = self.id,
            .title = self.title,
            .description = self.description,
            .status = status,
            .priority = self.priority,
            .created_at = self.created_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .blockers = self.blockers,
        };
    }

    /// Create a copy with updated blockers (borrows all strings)
    pub fn withBlockers(self: Issue, blockers: []const []const u8) Issue {
        return .{
            .id = self.id,
            .title = self.title,
            .description = self.description,
            .status = self.status,
            .priority = self.priority,
            .created_at = self.created_at,
            .closed_at = self.closed_at,
            .close_reason = self.close_reason,
            .blockers = blockers,
        };
    }

    /// Create a deep copy of this issue with all strings duplicated
    pub fn clone(self: Issue, allocator: Allocator) !Issue {
        const id = try allocator.dupe(u8, self.id);
        errdefer allocator.free(id);

        const title = try allocator.dupe(u8, self.title);
        errdefer allocator.free(title);

        const description = try allocator.dupe(u8, self.description);
        errdefer allocator.free(description);

        const created_at = try allocator.dupe(u8, self.created_at);
        errdefer allocator.free(created_at);

        const closed_at = if (self.closed_at) |c| try allocator.dupe(u8, c) else null;
        errdefer if (closed_at) |c| allocator.free(c);

        const close_reason = if (self.close_reason) |r| try allocator.dupe(u8, r) else null;
        errdefer if (close_reason) |r| allocator.free(r);

        var blockers: std.ArrayList([]const u8) = .{};
        errdefer {
            for (blockers.items) |b| allocator.free(b);
            blockers.deinit(allocator);
        }
        for (self.blockers) |b| {
            const duped = try allocator.dupe(u8, b);
            try blockers.append(allocator, duped);
        }

        return .{
            .id = id,
            .title = title,
            .description = description,
            .status = self.status,
            .priority = self.priority,
            .created_at = created_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .blockers = try blockers.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Issue, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.created_at);
        if (self.closed_at) |s| allocator.free(s);
        if (self.close_reason) |s| allocator.free(s);
        for (self.blockers) |b| allocator.free(b);
        allocator.free(self.blockers);
        self.* = undefined;
    }
};

pub fn freeIssues(allocator: Allocator, issues: []Issue) void {
    for (issues) |*issue| {
        issue.deinit(allocator);
    }
    allocator.free(issues);
}

pub fn freeScopes(allocator: Allocator, scopes: []const []const u8) void {
    for (scopes) |s| allocator.free(s);
    allocator.free(scopes);
}

/// Extract the scope (prefix) from an ID like "app-001" → "app", "my-scope-001" → "my-scope".
/// Returns null if the ID doesn't match the {scope}-{NNN} pattern.
pub fn extractScope(id: []const u8) ?[]const u8 {
    // Find last '-'
    var last_dash: ?usize = null;
    for (0..id.len) |i| {
        if (id[i] == '-') last_dash = i;
    }
    const dash = last_dash orelse return null;
    if (dash == 0 or dash + 1 >= id.len) return null;

    // Check suffix is all digits
    const suffix = id[dash + 1 ..];
    for (suffix) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return id[0..dash];
}

/// Extract the numeric suffix from an ID matching `{scope}-{NNN}`.
/// Returns null if the ID doesn't match the expected pattern.
pub fn extractScopeNumber(id: []const u8, scope: []const u8) ?u32 {
    // Must start with "{scope}-"
    if (id.len <= scope.len + 1) return null;
    if (!std.mem.startsWith(u8, id, scope)) return null;
    if (id[scope.len] != '-') return null;

    const suffix = id[scope.len + 1 ..];
    // Must be all digits
    for (suffix) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u32, suffix, 10) catch null;
}

test "validateId: accepts valid IDs" {
    try validateId("abc");
    try validateId("abc-001");
    try validateId("my-scope-999");
    try validateId("a");
}

test "validateId: rejects empty ID" {
    try std.testing.expectError(error.InvalidId, validateId(""));
}

test "validateId: rejects path traversal" {
    try std.testing.expectError(error.InvalidId, validateId("../etc"));
    try std.testing.expectError(error.InvalidId, validateId("foo/bar"));
    try std.testing.expectError(error.InvalidId, validateId("foo\\bar"));
    try std.testing.expectError(error.InvalidId, validateId("."));
}

test "validateId: rejects control characters" {
    try std.testing.expectError(error.InvalidId, validateId("foo\x00bar"));
    try std.testing.expectError(error.InvalidId, validateId("foo\x1fbar"));
    try std.testing.expectError(error.InvalidId, validateId("foo\x7fbar"));
}

test "validateId: rejects YAML-sensitive characters" {
    try std.testing.expectError(error.InvalidId, validateId("foo#bar"));
    try std.testing.expectError(error.InvalidId, validateId("foo:bar"));
    try std.testing.expectError(error.InvalidId, validateId("foo'bar"));
    try std.testing.expectError(error.InvalidId, validateId("foo\"bar"));
}

test "extractScope: extracts scope from valid IDs" {
    try std.testing.expectEqualStrings("app", extractScope("app-001").?);
    try std.testing.expectEqualStrings("my-scope", extractScope("my-scope-999").?);
    try std.testing.expectEqualStrings("a", extractScope("a-1").?);
}

test "extractScope: returns null for invalid patterns" {
    try std.testing.expectEqual(null, extractScope("no-dash"));
    try std.testing.expectEqual(null, extractScope("-001"));
    try std.testing.expectEqual(null, extractScope("abc-def-ghi"));
    try std.testing.expectEqual(null, extractScope("abc-xyz"));
}

test "extractScopeNumber: extracts number from valid IDs" {
    try std.testing.expectEqual(@as(u32, 1), extractScopeNumber("app-001", "app").?);
    try std.testing.expectEqual(@as(u32, 999), extractScopeNumber("app-999", "app").?);
    try std.testing.expectEqual(@as(u32, 42), extractScopeNumber("my-scope-42", "my-scope").?);
}

test "extractScopeNumber: returns null for invalid patterns" {
    try std.testing.expectEqual(null, extractScopeNumber("app-001", "other"));
    try std.testing.expectEqual(null, extractScopeNumber("app-abc", "app"));
    try std.testing.expectEqual(null, extractScopeNumber("other-001", "app"));
}

test "Status.parse: parses valid status strings" {
    try std.testing.expectEqual(Status.open, Status.parse("open"));
    try std.testing.expectEqual(Status.active, Status.parse("active"));
    try std.testing.expectEqual(Status.closed, Status.parse("closed"));
    try std.testing.expectEqual(Status.closed, Status.parse("done")); // alias
}

test "Status.parse: returns null for invalid status" {
    try std.testing.expectEqual(null, Status.parse("invalid"));
    try std.testing.expectEqual(null, Status.parse(""));
}
