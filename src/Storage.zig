//! Storage layer - all FS-bound operations.

const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;

const issue_mod = @import("Issue.zig");

const Issue = issue_mod.Issue;
const Status = issue_mod.Status;
const IssueError = issue_mod.IssueError;

const frontmatter_mod = @import("Frontmatter.zig");
const parseFrontmatter = frontmatter_mod.parseFrontmatter;
const serializeFrontmatter = frontmatter_mod.serializeFrontmatter;

pub const dots_dir = ".dots";
const archive_dir = ".dots/archive";

// Buffer size constants
const max_path_len = 512; // Maximum path length for file operations
const max_issue_file_size = 1024 * 1024; // 1MB max issue file

// Storage errors - FS-bound only
pub const StorageError = error{
    DependencyNotFound,
    DependencyCycle,
    DependencyConflict,
    InvalidDependencyType,
    IoError,
};

/// Combined error type for Storage operations
pub const Error = StorageError || IssueError;

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
            if (issue_mod.extractScopeNumber(id, scope)) |num| {
                if (num > highest.*) highest.* = num;
            }
        }
    }
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

        if (states[0].ambig) return error.AmbiguousId;
        if (states[0].match == null) return error.IssueNotFound;

        return states[0].match.?;
    }

    pub fn resolveIdActive(self: *Storage, prefix: []const u8) ![]const u8 {
        var states = [_]ResolveState{.{ .prefix = prefix }};
        errdefer states[0].deinit(self.allocator);

        try self.scanResolve(self.dots_dir, states[0..]);

        if (states[0].ambig) return error.AmbiguousId;
        if (states[0].match == null) return error.IssueNotFound;

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
            error.IssueNotFound => return false,
            else => return err,
        };
        self.allocator.free(path);
        return true;
    }

    pub fn findIssuePath(self: *Storage, id: []const u8) ![]const u8 {
        var path_buf: [max_path_len]u8 = undefined;

        // Derive scope from ID and look in scope folder
        if (issue_mod.extractScope(id)) |scope| {
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

        return error.IssueNotFound;
    }

    pub fn getIssue(self: *Storage, id: []const u8) !?Issue {
        // Validate ID to prevent path traversal attacks
        try issue_mod.validateId(id);

        const path = self.findIssuePath(id) catch |err| switch (err) {
            error.IssueNotFound => return null,
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
        // Free allocated_blockers on error (transferred to Issue on success)
        var blockers_transferred = false;
        errdefer if (!blockers_transferred) {
            for (parsed.allocated_blockers) |b| self.allocator.free(b);
            self.allocator.free(parsed.allocated_blockers);
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

        // Mark blockers as transferred (will be owned by Issue)
        blockers_transferred = true;
        return .{
            .id = issue_id,
            .title = title,
            .description = description,
            .status = parsed.frontmatter.status,
            .priority = parsed.frontmatter.priority,
            .created_at = created_at,
            .closed_at = closed_at,
            .close_reason = close_reason,
            .blockers = parsed.allocated_blockers,
        };
    }

    pub fn createIssue(self: *Storage, issue: Issue) !void {
        // Validate IDs to prevent path traversal
        try issue_mod.validateId(issue.id);
        for (issue.blockers) |b| try issue_mod.validateId(b);

        // Prevent overwriting existing issues
        // Note: TOCTOU race exists here - concurrent creates may both pass this check.
        // The atomic write ensures no corruption, but last writer wins.
        if (try self.issueExists(issue.id)) {
            return error.IssueAlreadyExists;
        }

        const content = try serializeFrontmatter(self.allocator, issue);
        defer self.allocator.free(content);

        const scope = issue_mod.extractScope(issue.id) orelse return IssueError.InvalidId;
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
            error.IssueNotFound => return error.IssueNotFound,
            else => return err,
        };
        defer self.allocator.free(path);
        try self.maybeArchive(id, path);
    }

    fn maybeArchive(self: *Storage, id: []const u8, path: []const u8) !void {
        // Don't archive if already in archive
        if (std.mem.startsWith(u8, path, "archive/")) return;

        const scope = issue_mod.extractScope(id);

        var archive_path_buf: [max_path_len]u8 = undefined;
        if (scope) |s| {
            var archive_scope_buf: [max_path_len]u8 = undefined;
            const archive_scope = std.fmt.bufPrint(&archive_scope_buf, "archive/{s}", .{s}) catch return StorageError.IoError;
            self.dots_dir.makeDir(archive_scope) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
            const archive_path = std.fmt.bufPrint(&archive_path_buf, "archive/{s}/{s}.md", .{ s, id }) catch return StorageError.IoError;
            try self.dots_dir.rename(path, archive_path);
            // ziglint-ignore: Z026 - Best effort cleanup
            self.deleteEmptyScopeDir(s) catch {};
            return;
        }

        const archive_path = std.fmt.bufPrint(&archive_path_buf, "archive/{s}.md", .{id}) catch return StorageError.IoError;
        try self.dots_dir.rename(path, archive_path);
    }

    fn maybeUnarchive(self: *Storage, id: []const u8, path: []const u8) !void {
        if (!std.mem.startsWith(u8, path, "archive/")) return;

        const scope = issue_mod.extractScope(id) orelse return IssueError.InvalidId;

        self.dots_dir.makeDir(scope) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        var main_path_buf: [max_path_len]u8 = undefined;
        const main_path = std.fmt.bufPrint(&main_path_buf, "{s}/{s}.md", .{ scope, id }) catch return StorageError.IoError;
        try self.dots_dir.rename(path, main_path);

        var archive_scope_buf: [max_path_len]u8 = undefined;
        const archive_scope = std.fmt.bufPrint(&archive_scope_buf, "archive/{s}", .{scope}) catch return StorageError.IoError;
        // ziglint-ignore: Z026 - Best effort cleanup
        self.deleteEmptyScopeDir(archive_scope) catch {};
    }

    fn deleteEmptyScopeDir(self: *Storage, scope: []const u8) !void {
        var scope_dir = self.dots_dir.openDir(scope, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer scope_dir.close();

        var iter = scope_dir.iterate();
        if (iter.next() catch return) |_| return;

        // ziglint-ignore: Z026 - Best effort cleanup
        self.dots_dir.deleteDir(scope) catch {};
    }

    pub fn deleteIssue(self: *Storage, id: []const u8) !void {
        const path = try self.findIssuePath(id);
        defer self.allocator.free(path);

        // Clean up dangling dependency references before deleting
        try self.removeDependencyReferences(id);
        try self.dots_dir.deleteFile(path);
    }

    /// Remove all references to the given ID from other issues' blockers arrays
    /// Optimized: uses already-loaded issues instead of re-reading from disk
    fn removeDependencyReferences(self: *Storage, deleted_id: []const u8) !void {
        // Get all issues (including archived)
        const issues = try self.listAllIssuesIncludingArchived();
        defer issue_mod.freeIssues(self.allocator, issues);

        for (issues) |issue| {
            // Check if this issue references the deleted ID
            var has_reference = false;
            for (issue.blockers) |b| {
                if (std.mem.eql(u8, b, deleted_id)) {
                    has_reference = true;
                    break;
                }
            }

            if (!has_reference) continue;

            // Build new blockers without the removed dependency (using already-loaded issue)
            var new_blockers: std.ArrayList([]const u8) = .{};
            errdefer {
                for (new_blockers.items) |b| self.allocator.free(b);
                new_blockers.deinit(self.allocator);
            }

            for (issue.blockers) |b| {
                if (!std.mem.eql(u8, b, deleted_id)) {
                    const duped = try self.allocator.dupe(u8, b);
                    try new_blockers.append(self.allocator, duped);
                }
            }

            const blockers_slice = try new_blockers.toOwnedSlice(self.allocator);
            defer {
                for (blockers_slice) |b| self.allocator.free(b);
                self.allocator.free(blockers_slice);
            }

            // Find path and write directly (no re-read needed)
            const path = try self.findIssuePath(issue.id);
            defer self.allocator.free(path);

            const content = try serializeFrontmatter(self.allocator, issue.withBlockers(blockers_slice));
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

    /// List scope directory names (subdirs of .dots/, excluding "archive").
    /// Returns alphabetically sorted owned slice.
    pub fn listScopes(self: *Storage) ![]const []const u8 {
        var scopes: std.ArrayList([]const u8) = .{};
        errdefer {
            for (scopes.items) |s| self.allocator.free(s);
            scopes.deinit(self.allocator);
        }

        var iter = self.dots_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory and !std.mem.eql(u8, entry.name, "archive")) {
                const name = try self.allocator.dupe(u8, entry.name);
                try scopes.append(self.allocator, name);
            }
        }

        std.mem.sort([]const u8, scopes.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);

        return scopes.toOwnedSlice(self.allocator);
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
                    IssueError.InvalidFrontmatter, IssueError.InvalidStatus => continue, // Malformed file, skip
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
            if (isBlockedByStatusMap(issue.blockers, &status_by_id)) continue;

            keep[i] = true;
            ready.appendAssumeCapacity(issue);
        }

        for (all_issues, 0..) |*issue, i| {
            if (!keep[i]) issue.deinit(self.allocator);
        }

        return ready.toOwnedSlice(self.allocator);
    }

    fn isBlockedByStatusMap(blockers: []const []const u8, status_by_id: *const StatusMap) bool {
        for (blockers) |blocker_id| {
            const status = status_by_id.get(blocker_id) orelse continue;
            if (status == .open or status == .active) return true;
        }
        return false;
    }

    pub fn removeDependency(self: *Storage, issue_id: []const u8, depends_on_id: []const u8) !void {
        try issue_mod.validateId(issue_id);
        try issue_mod.validateId(depends_on_id);

        const path = try self.findIssuePath(issue_id);
        defer self.allocator.free(path);

        var issue = try self.readIssueFromPath(path, issue_id);
        defer issue.deinit(self.allocator);

        var new_blockers: std.ArrayList([]const u8) = .{};
        errdefer {
            for (new_blockers.items) |b| self.allocator.free(b);
            new_blockers.deinit(self.allocator);
        }

        var found = false;
        for (issue.blockers) |b| {
            if (std.mem.eql(u8, b, depends_on_id)) {
                found = true;
                continue;
            }
            try new_blockers.append(self.allocator, try self.allocator.dupe(u8, b));
        }

        if (!found) return StorageError.DependencyNotFound;

        const blockers_slice = try new_blockers.toOwnedSlice(self.allocator);
        defer {
            for (blockers_slice) |b| self.allocator.free(b);
            self.allocator.free(blockers_slice);
        }

        const content = try serializeFrontmatter(self.allocator, issue.withBlockers(blockers_slice));
        defer self.allocator.free(content);

        try writeFileAtomic(self.dots_dir, path, content);
    }

    pub fn addDependency(self: *Storage, issue_id: []const u8, depends_on_id: []const u8, dep_type: []const u8) !void {
        // Validate IDs to prevent path traversal
        try issue_mod.validateId(issue_id);
        try issue_mod.validateId(depends_on_id);

        // Verify the dependency target exists
        if (!try self.issueExists(depends_on_id)) {
            return StorageError.DependencyNotFound;
        }

        // Validate dependency type
        const valid_dep_types = std.StaticStringMap(void).initComptime(.{
            .{ "blockers", {} },
        });
        if (valid_dep_types.get(dep_type) == null) {
            return error.InvalidDependencyType;
        }

        // For "blockers" type, add to the issue's blockers array
        if (std.mem.eql(u8, dep_type, "blockers")) {
            // Check for cycle
            if (try self.wouldCreateCycle(issue_id, depends_on_id)) {
                return StorageError.DependencyCycle;
            }

            const path = try self.findIssuePath(issue_id);
            defer self.allocator.free(path);

            var issue = try self.readIssueFromPath(path, issue_id);
            defer issue.deinit(self.allocator);

            // Check if already in blockers
            for (issue.blockers) |b| {
                if (std.mem.eql(u8, b, depends_on_id)) return; // Already exists
            }

            // Add to blockers array
            var new_blockers: std.ArrayList([]const u8) = .{};
            errdefer {
                for (new_blockers.items) |b| self.allocator.free(b);
                new_blockers.deinit(self.allocator);
            }

            for (issue.blockers) |b| {
                const duped = try self.allocator.dupe(u8, b);
                try new_blockers.append(self.allocator, duped);
            }
            const new_dep = try self.allocator.dupe(u8, depends_on_id);
            try new_blockers.append(self.allocator, new_dep);

            const blockers_slice = try new_blockers.toOwnedSlice(self.allocator);
            defer {
                for (blockers_slice) |b| self.allocator.free(b);
                self.allocator.free(blockers_slice);
            }

            const content = try serializeFrontmatter(self.allocator, issue.withBlockers(blockers_slice));
            defer self.allocator.free(content);

            try writeFileAtomic(self.dots_dir, path, content);
        }
    }

    fn wouldCreateCycle(self: *Storage, from_id: []const u8, to_id: []const u8) !bool {
        // BFS from to_id following blockers dependencies
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

            for (issue.blockers) |blocker| {
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

    pub fn reopenIssue(self: *Storage, id: []const u8) !void {
        const path = try self.findIssuePath(id);
        defer self.allocator.free(path);

        try self.maybeUnarchive(id, path);
        try self.updateStatus(id, .open, null, null);
    }
};
