//! Pure frontmatter parsing and serialization.

const std = @import("std");
const Allocator = std.mem.Allocator;

const issue_mod = @import("Issue.zig");
const Issue = issue_mod.Issue;
const Status = issue_mod.Status;
const IssueError = issue_mod.IssueError;
const validateId = issue_mod.validateId;
const default_priority = issue_mod.default_priority;

const Frontmatter = struct {
    title: []const u8 = "",
    status: Status = .open,
    priority: i64 = default_priority,
    created_at: []const u8 = "",
    closed_at: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
    blockers: []const []const u8 = &.{},
};

pub const ParseResult = struct {
    frontmatter: Frontmatter,
    description: []const u8,
    // Track allocated strings for cleanup
    allocated_blockers: [][]const u8,
    allocated_title: ?[]const u8 = null,

    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        if (self.allocated_title) |t| allocator.free(t);
        for (self.allocated_blockers) |b| allocator.free(b);
        allocator.free(self.allocated_blockers);
        self.* = undefined;
    }
};

// Frontmatter field enum and map (file-scope for efficiency)
const FrontmatterField = enum {
    title,
    status,
    priority,
    created_at,
    closed_at,
    close_reason,
    blockers,
};

const frontmatter_field_map = std.StaticStringMap(FrontmatterField).initComptime(.{
    .{ "title", .title },
    .{ "status", .status },
    .{ "priority", .priority },
    .{ "created-at", .created_at },
    .{ "closed-at", .closed_at },
    .{ "close-reason", .close_reason },
    .{ "blockers", .blockers },
});

/// Result of parsing a YAML value - clearly indicates ownership
const YamlValue = union(enum) {
    borrowed: []const u8, // Points to input, caller must NOT free
    owned: []const u8, // Allocated, caller MUST free

    fn slice(self: YamlValue) []const u8 {
        return switch (self) {
            .borrowed => |s| s,
            .owned => |s| s,
        };
    }

    fn getOwned(self: YamlValue) ?[]const u8 {
        return switch (self) {
            .borrowed => null,
            .owned => |s| s,
        };
    }
};

/// Strip leading and trailing quotes from a YAML value
/// Use only for values that never contain escape sequences (e.g. timestamps).
fn stripYamlQuotes(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    return value;
}

/// Parse a YAML value, handling quoted strings with escape sequences
fn parseYamlValue(allocator: Allocator, value: []const u8) !YamlValue {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') {
        // Unquoted value, use as-is (caller should not free)
        return .{ .borrowed = value };
    }
    // Quoted value - unescape it
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 1; // Skip opening quote
    while (i < value.len - 1) { // Stop before closing quote
        if (value[i] == '\\' and i + 1 < value.len - 1) {
            const next = value[i + 1];
            switch (next) {
                'n' => try result.append(allocator, '\n'),
                'r' => try result.append(allocator, '\r'),
                't' => try result.append(allocator, '\t'),
                '"' => try result.append(allocator, '"'),
                '\\' => try result.append(allocator, '\\'),
                else => {
                    try result.append(allocator, '\\');
                    try result.append(allocator, next);
                },
            }
            i += 2; // Skip backslash and escaped char
        } else {
            try result.append(allocator, value[i]);
            i += 1;
        }
    }
    return .{ .owned = try result.toOwnedSlice(allocator) };
}

pub fn parseFrontmatter(allocator: Allocator, content: []const u8) !ParseResult {
    // Find YAML delimiters
    const frontmatter_start: usize = if (std.mem.startsWith(u8, content, "---\r\n"))
        5
    else if (std.mem.startsWith(u8, content, "---\n"))
        4
    else
        return error.InvalidFrontmatter;

    const end_marker = std.mem.indexOf(u8, content[frontmatter_start..], "\n---");
    if (end_marker == null) {
        return error.InvalidFrontmatter;
    }

    const yaml_content = content[frontmatter_start .. frontmatter_start + end_marker.?];

    // Skip "---" and an optional trailing line ending after the closing delimiter.
    var description_start = frontmatter_start + end_marker.? + 4; // skip "\n---"
    if (description_start < content.len and content[description_start] == '\r') {
        description_start += 1;
    }
    if (description_start < content.len and content[description_start] == '\n') {
        description_start += 1;
    }
    const description = if (description_start < content.len)
        std.mem.trim(u8, content[description_start..], "\n\r\t ")
    else
        "";

    var fm: Frontmatter = .{};
    var blockers_list: std.ArrayList([]const u8) = .{};
    var allocated_title: ?[]const u8 = null;
    errdefer {
        if (allocated_title) |t| allocator.free(t);
        for (blockers_list.items) |b| allocator.free(b);
        blockers_list.deinit(allocator);
    }

    var in_blockers = false;
    var lines = std.mem.splitScalar(u8, yaml_content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r\t ");

        // Handle blockers array items
        if (in_blockers) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                const block_id = std.mem.trim(u8, trimmed[2..], " ");
                // Validate block ID to prevent path traversal attacks
                validateId(block_id) catch return error.InvalidFrontmatter;
                const duped = try allocator.dupe(u8, block_id);
                try blockers_list.append(allocator, duped);
                continue;
            } else if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, " ")) {
                in_blockers = false;
            } else {
                continue;
            }
        }

        // Parse key: value
        const colon_idx = std.mem.indexOf(u8, trimmed, ":") orelse continue;
        const key = trimmed[0..colon_idx];
        const value = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " ");

        const field = frontmatter_field_map.get(key) orelse continue;

        switch (field) {
            .title => {
                const parsed = try parseYamlValue(allocator, value);
                fm.title = parsed.slice();
                allocated_title = parsed.getOwned();
            },
            .status => fm.status = Status.parse(value) orelse return IssueError.InvalidStatus,
            .priority => fm.priority = std.fmt.parseInt(i64, value, 10) catch return error.InvalidFrontmatter,
            .created_at => fm.created_at = stripYamlQuotes(value),
            .closed_at => fm.closed_at = if (value.len > 0) stripYamlQuotes(value) else null,
            .close_reason => fm.close_reason = if (value.len > 0) stripYamlQuotes(value) else null,
            .blockers => in_blockers = true,
        }
    }

    const allocated_blockers = try blockers_list.toOwnedSlice(allocator);
    fm.blockers = allocated_blockers;

    // Validate required fields
    if (fm.title.len == 0 or fm.created_at.len == 0) {
        // Clean up allocations on validation failure
        for (allocated_blockers) |b| allocator.free(b);
        allocator.free(allocated_blockers);
        if (allocated_title) |t| {
            allocator.free(t);
            allocated_title = null; // Prevent errdefer double-free
        }
        return error.InvalidFrontmatter;
    }

    return .{
        .frontmatter = fm,
        .description = description,
        .allocated_blockers = allocated_blockers,
        .allocated_title = allocated_title,
    };
}

/// Returns true if string needs YAML quoting
fn needsYamlQuoting(s: []const u8) bool {
    if (s.len == 0) return true;
    // Check for characters that need quoting
    for (s) |c| {
        if (c == '\n' or c == '\r' or c == ':' or c == '#' or c == '"' or c == '\'' or c == '\\') return true;
    }
    // Leading/trailing whitespace
    if (s[0] == ' ' or s[0] == '\t' or s[s.len - 1] == ' ' or s[s.len - 1] == '\t') return true;
    return false;
}

/// Write a YAML-safe string value, quoting and escaping as needed
fn writeYamlValue(allocator: Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    if (!needsYamlQuoting(value)) {
        try buf.appendSlice(allocator, value);
        return;
    }
    // Use double quotes and escape special characters
    try buf.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

pub fn serializeFrontmatter(allocator: Allocator, issue: Issue) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "---\n");
    try buf.appendSlice(allocator, "title: ");
    try writeYamlValue(allocator, &buf, issue.title);
    try buf.appendSlice(allocator, "\nstatus: ");
    try buf.appendSlice(allocator, issue.status.toString());
    try buf.appendSlice(allocator, "\npriority: ");

    var priority_buf: [21]u8 = undefined; // i64 max is 19 digits + sign
    const priority_str = std.fmt.bufPrint(&priority_buf, "{d}", .{issue.priority}) catch return error.OutOfMemory;
    try buf.appendSlice(allocator, priority_str);

    try buf.appendSlice(allocator, "\ncreated-at: ");
    try writeYamlValue(allocator, &buf, issue.created_at);

    if (issue.closed_at) |closed_at| {
        try buf.appendSlice(allocator, "\nclosed-at: ");
        try writeYamlValue(allocator, &buf, closed_at);
    }

    if (issue.close_reason) |reason| {
        try buf.appendSlice(allocator, "\nclose-reason: ");
        try writeYamlValue(allocator, &buf, reason);
    }

    if (issue.blockers.len > 0) {
        try buf.appendSlice(allocator, "\nblockers:");
        for (issue.blockers) |block_id| {
            try buf.appendSlice(allocator, "\n  - ");
            try buf.appendSlice(allocator, block_id);
        }
    }

    try buf.appendSlice(allocator, "\n---\n");

    if (issue.description.len > 0) {
        try buf.appendSlice(allocator, "\n");
        try buf.appendSlice(allocator, issue.description);
        try buf.appendSlice(allocator, "\n");
    }

    return buf.toOwnedSlice(allocator);
}

test "parseFrontmatter: parses valid frontmatter" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\title: Test Issue
        \\status: open
        \\priority: 2
        \\created-at: 2024-01-01T00:00:00Z
        \\---
        \\Description here
    ;

    var result = try parseFrontmatter(allocator, content);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("Test Issue", result.frontmatter.title);
    try std.testing.expectEqual(Status.open, result.frontmatter.status);
    try std.testing.expectEqual(@as(i64, 2), result.frontmatter.priority);
    try std.testing.expectEqualStrings("2024-01-01T00:00:00Z", result.frontmatter.created_at);
    try std.testing.expectEqualStrings("Description here", result.description);
}

test "parseFrontmatter: rejects missing title" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\status: open
        \\priority: 2
        \\created-at: 2024-01-01T00:00:00Z
        \\---
    ;

    try std.testing.expectError(error.InvalidFrontmatter, parseFrontmatter(allocator, content));
}

test "parseFrontmatter: rejects invalid status" {
    const allocator = std.testing.allocator;
    const content =
        \\---
        \\title: Test
        \\status: invalid
        \\priority: 2
        \\created-at: 2024-01-01T00:00:00Z
        \\---
    ;

    try std.testing.expectError(error.InvalidStatus, parseFrontmatter(allocator, content));
}

test "serializeFrontmatter: roundtrips correctly" {
    const allocator = std.testing.allocator;

    const issue: Issue = .{
        .id = "test-001",
        .title = "Test Issue",
        .description = "Description",
        .status = .open,
        .priority = 2,
        .created_at = "2024-01-01T00:00:00Z",
        .closed_at = null,
        .close_reason = null,
        .blockers = &.{},
    };

    const serialized = try serializeFrontmatter(allocator, issue);
    defer allocator.free(serialized);

    var result = try parseFrontmatter(allocator, serialized);
    defer result.deinit(allocator);

    try std.testing.expectEqualStrings("Test Issue", result.frontmatter.title);
    try std.testing.expectEqualStrings("Description", result.description);
    try std.testing.expectEqual(Status.open, result.frontmatter.status);
}
