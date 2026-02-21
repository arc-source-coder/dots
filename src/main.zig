const std = @import("std");
const builtin = @import("builtin");
const commands = @import("Commands.zig");

pub fn main() void {
    // Enable UTF-8 output on Windows consoles (default codepage is CP437,
    // which garbles box-drawing characters like ├─ and symbols like ○).
    if (comptime builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    }

    if (run()) |_| {} else |err| handleError(err);
}

fn run() !void {
    const allocator = std.heap.smp_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    try commands.dispatch(allocator, args);
}

fn handleError(err: anyerror) noreturn {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);

    const msg: []const u8 = switch (err) {
        error.OutOfMemory => "Out of memory\n",
        error.FileNotFound => "Missing issue file or directory in .dots\n",
        error.AccessDenied => "Permission denied\n",
        error.NotDir => "Expected a directory but found a file\n",
        error.InvalidFrontmatter => "Invalid issue frontmatter\n",
        error.InvalidStatus => "Invalid issue status\n",
        error.InvalidId => "Invalid issue id\n",
        error.DependencyNotFound => "Dependency not found\n",
        error.DependencyCycle => "Dependency would create a cycle\n",
        error.IssueAlreadyExists => "Issue already exists\n",
        error.IssueNotFound => "Issue not found\n",
        error.AmbiguousId => "Ambiguous issue id\n",
        error.InvalidTimestamp => "Invalid system time\n",
        error.TimestampOverflow => "System time out of range\n",
        error.LocaltimeFailed => "Failed to read local time\n",
        error.IoError => "I/O error\n",
        else => {
            // ziglint-ignore: Z026 - Best effort cleanup
            writer.interface.print("Unexpected internal error (code: {s})\n", .{@errorName(err)}) catch {};
            // ziglint-ignore: Z026 - Best effort cleanup
            writer.interface.flush() catch {};
            std.process.exit(1);
        },
    };

    // ziglint-ignore: Z026 - Best effort cleanup
    writer.interface.writeAll(msg) catch {};
    // ziglint-ignore: Z026 - Best effort cleanup
    writer.interface.flush() catch {};
    std.process.exit(1);
}
