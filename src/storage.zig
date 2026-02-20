const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;

pub const dots_dir = ".dots";
const archive_dir = ".dots/archive";

// Buffer size constants
const max_path_len = 512; // Maximum path length for file operations
const max_id_len = 128; // Maximum ID length (validated in validateId)
const max_issue_file_size = 1024 * 1024; // 1MB max issue file
const default_priority: i64 = 2; // Default priority for new issues

// Errors
pub const StorageError = error{
    IssueNotFound,
    IssueAlreadyExists,
    AmbiguousId,
    DependencyNotFound,
    DependencyCycle,
    DependencyConflict,
    InvalidFrontmatter,
    InvalidStatus,
    InvalidId,
    IoError,
};

/// Validates that an ID is safe for use in paths and YAML
pub fn validateId(id: []const u8) StorageError!void {
    if (id.len == 0) return StorageError.InvalidId;
    if (id.len > max_id_len) return StorageError.InvalidId;
    // Reject path traversal attempts
    if (std.mem.indexOf(u8, id, "/") != null) return StorageError.InvalidId;
    if (std.mem.indexOf(u8, id, "\\") != null) return StorageError.InvalidId;
    if (std.mem.indexOf(u8, id, "..") != null) return StorageError.InvalidId;
    if (std.mem.eql(u8, id, ".")) return StorageError.InvalidId;
    // Reject control characters and YAML-sensitive characters
    for (id) |c| {
        if (c < 0x20 or c == 0x7F) return StorageError.InvalidId;
        if (c == '#' or c == ':' or c == '\'' or c == '"') return StorageError.InvalidId;
    }
}

/// Write content to file atomically (write to unique .tmp, sync, rename)
/// Uses random suffix to prevent concurrent write conflicts
fn writeFileAtomic(dir: fs.Dir, path: []const u8, content: []const u8) !void {
    // Generate unique tmp filename with random suffix
    var rand_buf: [4]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const hex = std.fmt.bytesToHex(rand_buf, .lower);

    var tmp_path_buf: [max_path_len + 16]u8 = undefined; // +16 for ".XXXXXXXX.tmp"
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.{s}.tmp", .{ path, hex }) catch return StorageError.IoError;

    const tmp_file = try dir.createFile(tmp_path, .{});
    defer tmp_file.close();
    errdefer dir.deleteFile(tmp_path) catch {};
    try tmp_file.writeAll(content);
    try tmp_file.sync();

    try dir.rename(tmp_path, path);
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
    blocks: []const []const u8,

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
            .blocks = self.blocks,
        };
    }

    /// Create a copy with updated blocks (borrows all strings)
    pub fn withBlocks(self: Issue, blocks: []const []const u8) Issue {
        return .{
            .id = self.id,
            .title = self.title,
            .description = self.description,
            .status = self.status,
            .priority = self.priority,
            .created_at = self.created_at,
            .closed_at = self.closed_at,
            .close_reason = self.close_reason,
            .blocks = blocks,
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

        var blocks: std.ArrayList([]const u8) = .{};
        errdefer {
            for (blocks.items) |b| allocator.free(b);
            blocks.deinit(allocator);
        }
        for (self.blocks) |b| {
            const duped = try allocator.dupe(u8, b);
            try blocks.append(allocator, duped);
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
            .blocks = try blocks.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Issue, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.description);
        allocator.free(self.created_at);
        if (self.closed_at) |s| allocator.free(s);
        if (self.close_reason) |s| allocator.free(s);
        for (self.blocks) |b| allocator.free(b);
        allocator.free(self.blocks);
        self.* = undefined;
    }
};

pub const StatusMap = std.StringHashMap(Status);

pub const ResolveResult = union(enum) {
    ok: []const u8,
    not_found,
    ambiguous,
};

pub fn freeResolveResults(allocator: Allocator, results: []ResolveResult) void {
    for (results) |result| {
        switch (result) {
            .ok => |id| allocator.free(id),
            .not_found, .ambiguous => {},
        }
    }
    allocator.free(results);
}

const ResolveState = struct {
    prefix: []const u8,
    match: ?[]const u8 = null,
    ambig: bool = false,

    fn add(self: *ResolveState, allocator: Allocator, id: []const u8) !void {
        if (self.ambig) return;
        if (self.match) |m| {
            allocator.free(m);
            self.match = null;
            self.ambig = true;
            return;
        }
        self.match = try allocator.dupe(u8, id);
    }

    fn deinit(self: *ResolveState, allocator: Allocator) void {
        if (self.match) |m| allocator.free(m);
        self.* = undefined;
    }
};

pub fn freeIssues(allocator: Allocator, issues: []Issue) void {
    for (issues) |*issue| {
        issue.deinit(allocator);
    }
    allocator.free(issues);
}

// YAML Frontmatter parsing
const Frontmatter = struct {
    title: []const u8 = "",
    status: Status = .open,
    priority: i64 = default_priority,
    created_at: []const u8 = "",
    closed_at: ?[]const u8 = null,
    close_reason: ?[]const u8 = null,
    blocks: []const []const u8 = &.{},
};

const ParseResult = struct {
    frontmatter: Frontmatter,
    description: []const u8,
    // Track allocated strings for cleanup
    allocated_blocks: [][]const u8,
    allocated_title: ?[]const u8 = null,

    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        if (self.allocated_title) |t| allocator.free(t);
        for (self.allocated_blocks) |b| allocator.free(b);
        allocator.free(self.allocated_blocks);
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
    blocks,
};

const frontmatter_field_map = std.StaticStringMap(FrontmatterField).initComptime(.{
    .{ "title", .title },
    .{ "status", .status },
    .{ "priority", .priority },
    .{ "created-at", .created_at },
    .{ "closed-at", .closed_at },
    .{ "close-reason", .close_reason },
    .{ "blocks", .blocks },
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

fn parseFrontmatter(allocator: Allocator, content: []const u8) !ParseResult {
    // Find YAML delimiters
    const frontmatter_start: usize = if (std.mem.startsWith(u8, content, "---\r\n"))
        5
    else if (std.mem.startsWith(u8, content, "---\n"))
        4
    else
        return StorageError.InvalidFrontmatter;

    const end_marker = std.mem.indexOf(u8, content[frontmatter_start..], "\n---");
    if (end_marker == null) {
        return StorageError.InvalidFrontmatter;
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
    var blocks_list: std.ArrayList([]const u8) = .{};
    var allocated_title: ?[]const u8 = null;
    errdefer {
        if (allocated_title) |t| allocator.free(t);
        for (blocks_list.items) |b| allocator.free(b);
        blocks_list.deinit(allocator);
    }

    var in_blocks = false;
    var lines = std.mem.splitScalar(u8, yaml_content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r\t ");

        // Handle blocks array items
        if (in_blocks) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                const block_id = std.mem.trim(u8, trimmed[2..], " ");
                // Validate block ID to prevent path traversal attacks
                validateId(block_id) catch return StorageError.InvalidFrontmatter;
                const duped = try allocator.dupe(u8, block_id);
                try blocks_list.append(allocator, duped);
                continue;
            } else if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, " ")) {
                in_blocks = false;
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
            .status => fm.status = Status.parse(value) orelse return StorageError.InvalidStatus,
            .priority => fm.priority = std.fmt.parseInt(i64, value, 10) catch return StorageError.InvalidFrontmatter,
            .created_at => fm.created_at = value,
            .closed_at => fm.closed_at = if (value.len > 0) value else null,
            .close_reason => fm.close_reason = if (value.len > 0) value else null,
            .blocks => in_blocks = true,
        }
    }

    const allocated_blocks = try blocks_list.toOwnedSlice(allocator);
    fm.blocks = allocated_blocks;

    // Validate required fields
    if (fm.title.len == 0 or fm.created_at.len == 0) {
        // Clean up allocations on validation failure
        for (allocated_blocks) |b| allocator.free(b);
        allocator.free(allocated_blocks);
        if (allocated_title) |t| {
            allocator.free(t);
            allocated_title = null; // Prevent errdefer double-free
        }
        return StorageError.InvalidFrontmatter;
    }

    return .{
        .frontmatter = fm,
        .description = description,
        .allocated_blocks = allocated_blocks,
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

fn serializeFrontmatter(allocator: Allocator, issue: Issue) ![]u8 {
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

    if (issue.blocks.len > 0) {
        try buf.appendSlice(allocator, "\nblocks:");
        for (issue.blocks) |block_id| {
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

/// Generate the next sequential ID for a given scope.
/// Scans the scope directory for existing `{scope}-NNN.md` files,
/// finds the highest number, and returns `{scope}-{NNN+1}`.
pub fn nextId(allocator: Allocator, dir: fs.Dir, scope: []const u8) ![]u8 {
    var highest: u32 = 0;

    // Scan scope dir
    if (dir.openDir(scope, .{ .iterate = true })) |scope_dir| {
        var sd = scope_dir;
        defer sd.close();
        scanHighestId(sd, scope, &highest);
    } else |_| {}

    // Scan archive scope dir
    {
        var archive_scope_buf: [max_path_len]u8 = undefined;
        const archive_scope = std.fmt.bufPrint(&archive_scope_buf, "archive/{s}", .{scope}) catch return error.OutOfMemory;
        if (dir.openDir(archive_scope, .{ .iterate = true })) |archive_scope_dir| {
            var asd = archive_scope_dir;
            defer asd.close();
            scanHighestId(asd, scope, &highest);
        } else |_| {}
    }

    const next = highest + 1;
    if (next > 999) {
        return std.fmt.allocPrint(allocator, "{s}-{d:0>4}", .{ scope, next });
    }
    return std.fmt.allocPrint(allocator, "{s}-{d:0>3}", .{ scope, next });
}

fn scanHighestId(dir: fs.Dir, scope: []const u8, highest: *u32) void {
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
            const id = entry.name[0 .. entry.name.len - 3];
            if (extractScopeNumber(id, scope)) |num| {
                if (num > highest.*) highest.* = num;
            }
        }
    }
}

/// Extract the numeric suffix from an ID matching `{scope}-{NNN}`.
/// Returns null if the ID doesn't match the expected pattern.
fn extractScopeNumber(id: []const u8, scope: []const u8) ?u32 {
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

pub const Storage = struct {
    allocator: Allocator,
    dots_dir: fs.Dir,

    pub fn open(allocator: Allocator) !Storage {
        // Create .dots directory if needed
        fs.cwd().makeDir(dots_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Create archive directory if needed
        fs.cwd().makeDir(archive_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const dots_dir_handle = try fs.cwd().openDir(dots_dir, .{ .iterate = true });

        return .{
            .allocator = allocator,
            .dots_dir = dots_dir_handle,
        };
    }

    pub fn close(self: *Storage) void {
        self.dots_dir.close();
    }

    // Resolve a short ID prefix to full ID
    pub fn resolveId(self: *Storage, prefix: []const u8) ![]const u8 {
        var states = [_]ResolveState{.{ .prefix = prefix }};
        errdefer states[0].deinit(self.allocator);

        try self.scanResolve(self.dots_dir, states[0..]);

        const archive_dir_opt = self.dots_dir.openDir("archive", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (archive_dir_opt) |*dir| {
            var d = dir.*;
            defer d.close();
            try self.scanResolve(d, states[0..]);
        }

        if (states[0].ambig) return StorageError.AmbiguousId;
        if (states[0].match == null) return StorageError.IssueNotFound;

        return states[0].match.?;
    }

    pub fn resolveIdActive(self: *Storage, prefix: []const u8) ![]const u8 {
        var states = [_]ResolveState{.{ .prefix = prefix }};
        errdefer states[0].deinit(self.allocator);

        try self.scanResolve(self.dots_dir, states[0..]);

        if (states[0].ambig) return StorageError.AmbiguousId;
        if (states[0].match == null) return StorageError.IssueNotFound;

        return states[0].match.?;
    }

    pub fn resolveIds(self: *Storage, prefixes: []const []const u8) ![]ResolveResult {
        var states = try self.allocator.alloc(ResolveState, prefixes.len);
        errdefer {
            for (states) |*state| state.deinit(self.allocator);
            self.allocator.free(states);
        }
        for (prefixes, 0..) |prefix, i| {
            states[i] = .{ .prefix = prefix };
        }

        try self.scanResolve(self.dots_dir, states);

        const archive_dir_opt = self.dots_dir.openDir("archive", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (archive_dir_opt) |*dir| {
            var d = dir.*;
            defer d.close();
            try self.scanResolve(d, states);
        }

        const results = try self.allocator.alloc(ResolveResult, prefixes.len);
        errdefer freeResolveResults(self.allocator, results);

        for (states, 0..) |*state, i| {
            if (state.ambig) {
                results[i] = .ambiguous;
            } else if (state.match) |m| {
                results[i] = .{ .ok = m };
                state.match = null;
            } else {
                results[i] = .not_found;
            }
        }

        for (states) |*state| state.deinit(self.allocator);
        self.allocator.free(states);

        return results;
    }

    fn addResolve(self: *Storage, states: []ResolveState, id: []const u8) !void {
        for (states) |*state| {
            if (state.ambig) continue;
            if (std.mem.startsWith(u8, id, state.prefix)) {
                try state.add(self.allocator, id);
            }
        }
    }

    fn scanResolve(self: *Storage, dir: fs.Dir, states: []ResolveState) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                const id = entry.name[0 .. entry.name.len - 3];
                try self.addResolve(states, id);
            } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "archive")) {
                // Recurse into folder to resolve issue files
                var subdir = try dir.openDir(entry.name, .{ .iterate = true });
                defer subdir.close();
                try self.scanResolve(subdir, states);
            }
        }
    }

    pub fn issueExists(self: *Storage, id: []const u8) !bool {
        const path = self.findIssuePath(id) catch |err| switch (err) {
            StorageError.IssueNotFound => return false,
            else => return err,
        };
        self.allocator.free(path);
        return true;
    }

    fn findIssuePath(self: *Storage, id: []const u8) ![]const u8 {
        var path_buf: [max_path_len]u8 = undefined;

        // Derive scope from ID and look in scope folder
        if (extractScope(id)) |scope| {
            // Try scope folder: .dots/{scope}/{id}.md
            const scope_path = std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ scope, id }) catch return StorageError.IoError;
            if (self.dots_dir.statFile(scope_path)) |_| {
                return self.allocator.dupe(u8, scope_path);
            } else |_| {}

            // Try archive scope folder: .dots/archive/{scope}/{id}.md
            const archive_path = std.fmt.bufPrint(&path_buf, "archive/{s}/{s}.md", .{ scope, id }) catch return StorageError.IoError;
            if (self.dots_dir.statFile(archive_path)) |_| {
                return self.allocator.dupe(u8, archive_path);
            } else |_| {}
        }

        return StorageError.IssueNotFound;
    }

    pub fn getIssue(self: *Storage, id: []const u8) !?Issue {
        // Validate ID to prevent path traversal attacks
        try validateId(id);

        const path = self.findIssuePath(id) catch |err| switch (err) {
            StorageError.IssueNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(path);

        // ziglint-ignore: Z017 (false positive: readIssueFromPath returns !Issue but getIssue returns !?Issue)
        return try self.readIssueFromPath(path, id);
    }

    fn readIssueFromPath(self: *Storage, path: []const u8, id: []const u8) !Issue {
        const file = try self.dots_dir.openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, max_issue_file_size);
        defer self.allocator.free(content);

        const parsed = try parseFrontmatter(self.allocator, content);
        // Free allocated_title after duping
        defer if (parsed.allocated_title) |t| self.allocator.free(t);
        // Free allocated_blocks on error (transferred to Issue on success)
        var blocks_transferred = false;
        errdefer if (!blocks_transferred) {
            for (parsed.allocated_blocks) |b| self.allocator.free(b);
            self.allocator.free(parsed.allocated_blocks);
        };

        const issue_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(issue_id);

        const title = try self.allocator.dupe(u8, parsed.frontmatter.title);
        errdefer self.allocator.free(title);

        const description = try self.allocator.dupe(u8, parsed.description);
        errdefer self.allocator.free(description);

        const created_at = try self.allocator.dupe(u8, parsed.frontmatter.created_at);
        errdefer self.allocator.free(created_at);

        const closed_at = if (parsed.frontmatter.closed_at) |c| try self.allocator.dupe(u8, c) else null;
        errdefer if (closed_at) |c| self.allocator.free(c);

        const close_reason = if (parsed.frontmatter.close_reason) |r| try self.allocator.dupe(u8, r) else null;
        errdefer if (close_reason) |r| self.allocator.free(r);

        // Mark blocks as transferred (will be owned by Issue)
        blocks_transferred = true;
        return .{
            .id = issue_id,
            .title = title,
            .description = description,
            .status = parsed.frontmatter.status,
            .priority = parsed.frontmatter.priority,
            .created_at = created_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .blocks = parsed.allocated_blocks,
        };
    }

    pub fn createIssue(self: *Storage, issue: Issue) !void {
        // Validate IDs to prevent path traversal
        try validateId(issue.id);
        for (issue.blocks) |b| try validateId(b);

        // Prevent overwriting existing issues
        // Note: TOCTOU race exists here - concurrent creates may both pass this check.
        // The atomic write ensures no corruption, but last writer wins.
        if (try self.issueExists(issue.id)) {
            return StorageError.IssueAlreadyExists;
        }

        const content = try serializeFrontmatter(self.allocator, issue);
        defer self.allocator.free(content);

        const scope = extractScope(issue.id) orelse return StorageError.InvalidId;
        self.dots_dir.makeDir(scope) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var path_buf: [max_path_len]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.md", .{ scope, issue.id }) catch return StorageError.IoError;
        try writeFileAtomic(self.dots_dir, path, content);
    }

    pub fn updateStatus(
        self: *Storage,
        id: []const u8,
        status: Status,
        closed_at: ?[]const u8,
        close_reason: ?[]const u8,
    ) !void {
        const path = try self.findIssuePath(id);
        defer self.allocator.free(path);

        var issue = try self.readIssueFromPath(path, id);
        defer issue.deinit(self.allocator);

        // When not closing, clear closed_at; when closing, use provided or keep existing
        const effective_closed_at: ?[]const u8 = if (status == .closed)
            (closed_at orelse issue.closed_at)
        else
            null;

        const effective_close_reason: ?[]const u8 = if (status == .closed)
            (close_reason orelse issue.close_reason)
        else
            null;

        const updated = issue.withStatus(status, effective_closed_at, effective_close_reason);
        const content = try serializeFrontmatter(self.allocator, updated);
        defer self.allocator.free(content);

        try writeFileAtomic(self.dots_dir, path, content);

        // Handle archiving if closed
        if (status == .closed) try self.maybeArchive(id, path);
    }

    /// Archive an issue by ID (for migration of already-closed issues)
    pub fn archiveIssue(self: *Storage, id: []const u8) !void {
        const path = self.findIssuePath(id) catch |err| switch (err) {
            StorageError.IssueNotFound => return StorageError.IssueNotFound,
            else => return err,
        };
        defer self.allocator.free(path);
        try self.maybeArchive(id, path);
    }

    fn maybeArchive(self: *Storage, id: []const u8, path: []const u8) !void {
        // Don't archive if already in archive
        if (std.mem.startsWith(u8, path, "archive/")) return;

        var archive_path_buf: [max_path_len]u8 = undefined;
        if (extractScope(id)) |scope| {
            var archive_scope_buf: [max_path_len]u8 = undefined;
            const archive_scope = std.fmt.bufPrint(&archive_scope_buf, "archive/{s}", .{scope}) catch return StorageError.IoError;
            self.dots_dir.makeDir(archive_scope) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            const archive_path = std.fmt.bufPrint(&archive_path_buf, "archive/{s}/{s}.md", .{ scope, id }) catch return StorageError.IoError;
            try self.dots_dir.rename(path, archive_path);
            return;
        }

        const archive_path = std.fmt.bufPrint(&archive_path_buf, "archive/{s}.md", .{id}) catch return StorageError.IoError;
        try self.dots_dir.rename(path, archive_path);
    }

    pub fn deleteIssue(self: *Storage, id: []const u8) !void {
        const path = try self.findIssuePath(id);
        defer self.allocator.free(path);

        // Clean up dangling dependency references before deleting
        try self.removeDependencyReferences(id);
        try self.dots_dir.deleteFile(path);
    }

    /// Remove all references to the given ID from other issues' blocks arrays
    /// Optimized: uses already-loaded issues instead of re-reading from disk
    fn removeDependencyReferences(self: *Storage, deleted_id: []const u8) !void {
        // Get all issues (including archived)
        const issues = try self.listAllIssuesIncludingArchived();
        defer freeIssues(self.allocator, issues);

        for (issues) |issue| {
            // Check if this issue references the deleted ID
            var has_reference = false;
            for (issue.blocks) |b| {
                if (std.mem.eql(u8, b, deleted_id)) {
                    has_reference = true;
                    break;
                }
            }

            if (!has_reference) continue;

            // Build new blocks without the removed dependency (using already-loaded issue)
            var new_blocks: std.ArrayList([]const u8) = .{};
            errdefer {
                for (new_blocks.items) |b| self.allocator.free(b);
                new_blocks.deinit(self.allocator);
            }

            for (issue.blocks) |b| {
                if (!std.mem.eql(u8, b, deleted_id)) {
                    const duped = try self.allocator.dupe(u8, b);
                    try new_blocks.append(self.allocator, duped);
                }
            }

            const blocks_slice = try new_blocks.toOwnedSlice(self.allocator);
            defer {
                for (blocks_slice) |b| self.allocator.free(b);
                self.allocator.free(blocks_slice);
            }

            // Find path and write directly (no re-read needed)
            const path = try self.findIssuePath(issue.id);
            defer self.allocator.free(path);

            const content = try serializeFrontmatter(self.allocator, issue.withBlocks(blocks_slice));
            defer self.allocator.free(content);

            try writeFileAtomic(self.dots_dir, path, content);
        }
    }

    pub fn listAllIssuesIncludingArchived(self: *Storage) ![]Issue {
        var issues: std.ArrayList(Issue) = .{};
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        // Collect from main dots dir
        try self.collectIssuesFromDir(self.dots_dir, "", null, &issues);

        // Also collect from archive
        if (self.dots_dir.openDir("archive", .{ .iterate = true })) |archive_dir_handle| {
            var ad = archive_dir_handle;
            defer ad.close();
            try self.collectIssuesFromDir(ad, "archive", null, &issues);
        } else |err| switch (err) {
            error.FileNotFound => {}, // Archive doesn't exist yet, that's fine
            else => return err,
        }

        return issues.toOwnedSlice(self.allocator);
    }

    pub fn listIssues(self: *Storage, status_filter: ?Status) ![]Issue {
        var issues: std.ArrayList(Issue) = .{};
        errdefer {
            for (issues.items) |*iss| iss.deinit(self.allocator);
            issues.deinit(self.allocator);
        }

        try self.collectIssuesFromDir(self.dots_dir, "", status_filter, &issues);

        // Sort by priority, then created_at
        std.mem.sort(Issue, issues.items, {}, Issue.order);

        return issues.toOwnedSlice(self.allocator);
    }

    fn collectIssuesFromDir(
        self: *Storage,
        dir: fs.Dir,
        prefix: []const u8,
        status_filter: ?Status,
        issues: *std.ArrayList(Issue),
    ) !void {
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".md")) {
                const id = entry.name[0 .. entry.name.len - 3];
                var path_buf: [max_path_len]u8 = undefined;
                const path = if (prefix.len > 0) blk: {
                    const path_fmt_result = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ prefix, entry.name });
                    break :blk path_fmt_result catch return StorageError.IoError;
                } else entry.name;

                // Only skip expected parsing errors; propagate IO/allocation errors
                var issue = self.readIssueFromPath(path, id) catch |err| switch (err) {
                    StorageError.InvalidFrontmatter, StorageError.InvalidStatus => continue, // Malformed file, skip
                    else => return err, // IO/allocation errors must propagate
                };

                if (status_filter) |filter| {
                    if (issue.status != filter) {
                        issue.deinit(self.allocator);
                        continue;
                    }
                }

                issues.append(self.allocator, issue) catch |err| {
                    issue.deinit(self.allocator);
                    return err;
                };
            } else if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "archive")) {
                var subdir = try dir.openDir(entry.name, .{ .iterate = true });
                defer subdir.close();

                var sub_prefix_buf: [max_path_len]u8 = undefined;
                const sub_prefix = if (prefix.len > 0) blk: {
                    const prefix_fmt_result = std.fmt.bufPrint(&sub_prefix_buf, "{s}/{s}", .{ prefix, entry.name });
                    break :blk prefix_fmt_result catch return StorageError.IoError;
                } else entry.name;

                try self.collectIssuesFromDir(subdir, sub_prefix, status_filter, issues);
            }
        }
    }

    pub fn buildStatusMap(self: *Storage, issues: []const Issue) !StatusMap {
        // Caller must keep issue IDs alive while the map is used.
        var status_by_id = StatusMap.init(self.allocator);
        if (issues.len <= std.math.maxInt(u32)) {
            try status_by_id.ensureTotalCapacity(@intCast(issues.len));
        }
        for (issues) |issue| {
            try status_by_id.put(issue.id, issue.status);
        }
        return status_by_id;
    }

    pub fn getReadyIssues(self: *Storage) ![]Issue {
        const all_issues = try self.listIssues(null);
        defer self.allocator.free(all_issues);

        var ready: std.ArrayList(Issue) = .{};
        errdefer {
            for (ready.items) |*iss| iss.deinit(self.allocator);
            ready.deinit(self.allocator);
        }

        const keep = self.allocator.alloc(bool, all_issues.len) catch |err| {
            for (all_issues) |*issue| issue.deinit(self.allocator);
            return err;
        };
        defer self.allocator.free(keep);
        @memset(keep, false);
        errdefer {
            for (all_issues, 0..) |*issue, i| {
                if (!keep[i]) issue.deinit(self.allocator);
            }
        }

        var status_by_id = try self.buildStatusMap(all_issues);
        defer status_by_id.deinit();

        ready.ensureTotalCapacity(self.allocator, all_issues.len) catch |err| {
            return err;
        };

        for (all_issues, 0..) |issue, i| {
            if (issue.status != .open) continue;
            if (isBlockedByStatusMap(issue.blocks, &status_by_id)) continue;

            keep[i] = true;
            ready.appendAssumeCapacity(issue);
        }

        for (all_issues, 0..) |*issue, i| {
            if (!keep[i]) issue.deinit(self.allocator);
        }

        return ready.toOwnedSlice(self.allocator);
    }

    fn isBlockedByStatusMap(blocks: []const []const u8, status_by_id: *const StatusMap) bool {
        for (blocks) |blocker_id| {
            const status = status_by_id.get(blocker_id) orelse continue;
            if (status == .open or status == .active) return true;
        }
        return false;
    }

    pub fn searchIssues(self: *Storage, query: []const u8) ![]Issue {
        const all_issues = try self.listAllIssuesIncludingArchived();
        defer self.allocator.free(all_issues);

        var matches: std.ArrayList(Issue) = .{};
        errdefer {
            for (matches.items) |*iss| iss.deinit(self.allocator);
            matches.deinit(self.allocator);
        }

        matches.ensureTotalCapacity(self.allocator, all_issues.len) catch |err| {
            for (all_issues) |*issue| issue.deinit(self.allocator);
            return err;
        };

        for (all_issues) |*issue| { // *
            const in_title = containsIgnoreCase(issue.title, query);
            const in_desc = containsIgnoreCase(issue.description, query);
            const in_reason = if (issue.close_reason) |r| containsIgnoreCase(r, query) else false;
            const in_created = containsIgnoreCase(issue.created_at, query);
            const in_closed = if (issue.closed_at) |c| containsIgnoreCase(c, query) else false;

            if (in_title or in_desc or in_reason or in_created or in_closed) {
                matches.appendAssumeCapacity(issue.*);
            } else {
                issue.deinit(self.allocator);
            }
        }

        return matches.toOwnedSlice(self.allocator);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (asciiEqualIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
        }
        return false;
    }

    fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ac, bc| {
            if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
        }
        return true;
    }

    pub fn addDependency(self: *Storage, issue_id: []const u8, depends_on_id: []const u8, dep_type: []const u8) !void {
        // Validate IDs to prevent path traversal
        try validateId(issue_id);
        try validateId(depends_on_id);

        // Verify the dependency target exists
        if (!try self.issueExists(depends_on_id)) {
            return StorageError.DependencyNotFound;
        }

        // Validate dependency type
        const valid_dep_types = std.StaticStringMap(void).initComptime(.{
            .{ "blocks", {} },
        });
        if (valid_dep_types.get(dep_type) == null) {
            return StorageError.InvalidFrontmatter;
        }

        // For "blocks" type, add to the issue's blocks array
        if (std.mem.eql(u8, dep_type, "blocks")) {
            // Check for cycle
            if (try self.wouldCreateCycle(issue_id, depends_on_id)) {
                return StorageError.DependencyCycle;
            }

            const path = try self.findIssuePath(issue_id);
            defer self.allocator.free(path);

            var issue = try self.readIssueFromPath(path, issue_id);
            defer issue.deinit(self.allocator);

            // Check if already in blocks
            for (issue.blocks) |b| {
                if (std.mem.eql(u8, b, depends_on_id)) return; // Already exists
            }

            // Add to blocks array
            var new_blocks: std.ArrayList([]const u8) = .{};
            errdefer {
                for (new_blocks.items) |b| self.allocator.free(b);
                new_blocks.deinit(self.allocator);
            }

            for (issue.blocks) |b| {
                const duped = try self.allocator.dupe(u8, b);
                try new_blocks.append(self.allocator, duped);
            }
            const new_dep = try self.allocator.dupe(u8, depends_on_id);
            try new_blocks.append(self.allocator, new_dep);

            const blocks_slice = try new_blocks.toOwnedSlice(self.allocator);
            defer {
                for (blocks_slice) |b| self.allocator.free(b);
                self.allocator.free(blocks_slice);
            }

            const content = try serializeFrontmatter(self.allocator, issue.withBlocks(blocks_slice));
            defer self.allocator.free(content);

            try writeFileAtomic(self.dots_dir, path, content);
        }
    }

    fn wouldCreateCycle(self: *Storage, from_id: []const u8, to_id: []const u8) !bool {
        // BFS from to_id following blocks dependencies
        // If we reach from_id, cycle would be created

        // Use arena for all BFS allocations - single free at end
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var visited = std.StringHashMap(void).init(alloc);
        var queue: std.ArrayList([]const u8) = .{};

        // Must dupe to_id since it may outlive original
        try queue.append(alloc, try alloc.dupe(u8, to_id));

        // Use index instead of orderedRemove(0) for O(1) dequeue
        var head: usize = 0;
        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;

            if (std.mem.eql(u8, current, from_id)) {
                return true; // Cycle detected
            }

            if (visited.contains(current)) continue;
            try visited.put(current, {});

            var issue = try self.getIssue(current) orelse continue;
            defer issue.deinit(self.allocator);

            for (issue.blocks) |blocker| {
                if (!visited.contains(blocker)) {
                    // Must dupe since issue will be freed
                    try queue.append(alloc, try alloc.dupe(u8, blocker));
                }
            }
        }

        return false;
    }

    pub fn purgeArchive(self: *Storage) !void {
        // deleteTree succeeds silently if the directory doesn't exist
        try self.dots_dir.deleteTree("archive");

        // Recreate empty archive directory (handle race if another process recreated it)
        self.dots_dir.makeDir("archive") catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
};
