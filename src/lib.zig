//! Public API barrel — imported by tests via the "lib" module alias.
//! main.zig is the binary entry point and is not imported by tests.

pub const issue_mod = @import("Issue.zig");
pub const storage_mod = @import("Storage.zig");

test {
    _ = @import("Commands.zig");
    _ = @import("Issue.zig");
    _ = @import("Storage.zig");
    _ = @import("Frontmatter.zig");
}
