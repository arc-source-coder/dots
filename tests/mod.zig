// Test entry point - imports all test modules
//
// Test files are organized by functionality:
// - helpers.zig: Shared infrastructure (oracles, runners, setup/cleanup)
// - storage.test.zig: Storage layer tests (dependencies, ID resolution, validation)
// - cli.test.zig: Basic CLI tests (init, add, purge, search, import)
// - property.test.zig: Property-based tests using oracles
// - snapshots.test.zig: Snapshot tests for output formats

test {
    _ = @import("storage.test.zig");
    _ = @import("cli.test.zig");
    _ = @import("property.test.zig");
    _ = @import("snapshots.test.zig");
}
