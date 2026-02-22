# Phase 6: Codebase Reorganization — Implementation Plan

## Target Layout

```
src/
  main.zig          (unchanged)
  Commands.zig      (update imports only)
  Issue.zig         (new — pure data model + domain logic)
  Storage.zig       (slimmed — FS operations only)
  Frontmatter.zig   (new — parsing/serialization)
tests/
  helpers.zig
  property.test.zig
  cli.test.zig
  snapshots.test.zig
```

## Module Responsibilities

### Issue.zig (~250 lines) — Pure, no FS/IO

Extracted from storage.zig:

- **Types**: `Issue` struct (with `order`, `withStatus`, `withBlockers`, `clone`, `deinit`), `Status` enum
- **Validators**: `validateId`
- **ID helpers**: `extractScope`, `extractScopeNumber`
- **Free helpers**: `freeIssues`, `freeScopes`
- **Errors**: `IssueError` — `InvalidId`, `InvalidStatus`, `IssueNotFound`, `IssueAlreadyExists`, `AmbiguousId`

Unit tests for `validateId`, `extractScope`, `extractScopeNumber`, `Status.parse` go inline as `test` blocks.

### Frontmatter.zig (~300 lines) — Pure parse/serialize

Extracted from storage.zig:

- **Types**: `Frontmatter`, `ParseResult`, `FrontmatterField` enum, `YamlValue` union, `frontmatter_field_map`
- **Parsing**: `parseFrontmatter`, `parseYamlValue`, `stripYamlQuotes`
- **Serialization**: `serializeFrontmatter`, `needsYamlQuoting`, `writeYamlValue`
- **Errors**: `InvalidFrontmatter` (part of `IssueError`, imported from Issue.zig — frontmatter validation produces domain errors)

Imports `Issue` and `Status` from Issue.zig. Unit tests for round-trip parse/serialize go inline.

Note: `parseFrontmatter` currently returns `StorageError.InvalidFrontmatter` and `StorageError.InvalidStatus`. After the split these come from `IssueError`. The function signature uses Zig error unions so this is transparent to callers.

### Storage.zig (~850 lines) — All FS-bound operations

Remains in storage.zig, slimmed:

- **Types**: `Storage` struct, `ResolveResult`, `ResolveState`, `StatusMap`
- **Constants**: `dots_dir`, `archive_dir`, buffer size constants, `default_priority`
- **ID generation**: `nextId`, `scanHighestId` (FS scanning)
- **File ops**: `writeFileAtomic`
- **Storage methods**: `open`, `close`, `resolveId`, `resolveIdActive`, `resolveIds`, `issueExists`, `findIssuePath`, `getIssue`, `readIssueFromPath`, `createIssue`, `updateStatus`, `archiveIssue`, `maybeArchive`, `deleteIssue`, `removeDependencyReferences`, `listAllIssuesIncludingArchived`, `listIssues`, `listScopes`, `collectIssuesFromDir`, `buildStatusMap`, `getReadyIssues`, `searchIssues`, `containsIgnoreCase`, `asciiEqualIgnoreCase`, `removeDependency`, `addDependency`, `wouldCreateCycle`, `purgeArchive`
- **Free helpers**: `freeResolveResults`
- **Errors**: `StorageError` — `DependencyNotFound`, `DependencyCycle`, `DependencyConflict`, `IoError`

Imports from Issue.zig (`Issue`, `Status`, `IssueError`, `validateId`, `extractScope`, `extractScopeNumber`, `freeIssues`) and Frontmatter.zig (`parseFrontmatter`, `serializeFrontmatter`).

Combined error: `pub const Error = StorageError || IssueError;`

### Commands.zig (~740 lines) — Update imports only

No structural changes. Replace:

```zig
const storage_mod = @import("storage.zig");
const Issue = storage_mod.Issue;
const Status = storage_mod.Status;
```

With:

```zig
const Issue = @import("Issue.zig");
const Frontmatter = @import("Frontmatter.zig");
const Storage = @import("Storage.zig");
// Issue.zig re-exports are accessed via the Issue namespace
```

Symbols currently accessed as `storage_mod.X` get remapped:

- `storage_mod.Issue` → `Issue.Issue`
- `storage_mod.Status` → `Issue.Status`
- `storage_mod.Storage` → `Storage.Storage`
- `storage_mod.extractScope` → `Issue.extractScope`
- `storage_mod.freeIssues` → `Issue.freeIssues`
- `storage_mod.freeScopes` → `Issue.freeScopes`
- `storage_mod.nextId` → `Storage.nextId`
- `storage_mod.freeResolveResults` → `Storage.freeResolveResults`
- `storage_mod.dots_dir` → `Storage.dots_dir`

### main.zig (unchanged)

Continues to import Commands.zig only. Error names in `handleError` don't change — Zig error values are global.

## Test Migration

### Moved to tests/ (outside src/)

| Current                     | New                                       |
| --------------------------- | ----------------------------------------- |
| `src/test_property.zig`     | `tests/property.test.zig`                 |
| `src/test_cli_commands.zig` | `tests/cli.test.zig`                      |
| `src/test_snapshots.zig`    | `tests/snapshots.test.zig`                |
| `src/test_storage.zig`      | `tests/storage.test.zig`                  |
| `src/test_helpers.zig`      | `tests/helpers.zig`                       |
| `src/tests.zig`             | deleted (replaced by build.zig test root) |

### Inline unit tests

Move applicable unit-level tests from `test_storage.zig` into their owning modules:

- `validateId` tests → `Issue.zig`
- `extractScope`/`extractScopeNumber` tests → `Issue.zig`
- Frontmatter round-trip tests → `Frontmatter.zig`
- Storage-level tests (dependency cycle, resolve, CRUD) stay in `tests/storage.test.zig`

### build.zig changes

Update test module root from `src/tests.zig` to a new test root that imports from `tests/`. Alternatively, register each test file individually. The test module needs access to `Issue.zig`, `Storage.zig`, `Frontmatter.zig` source modules for inline tests, plus the `tests/` files.

## Implementation Order

1. **Create Issue.zig** — extract types/validators/helpers from storage.zig, define `IssueError`
2. **Create Frontmatter.zig** — extract parse/serialize from storage.zig, import Issue.zig
3. **Slim Storage.zig** — remove extracted code, add imports from Issue.zig + Frontmatter.zig, define `StorageError` (reduced)
4. **Update Commands.zig** — remap imports
5. **Verify build** — `zig build` clean, `zig build test` passing
6. **Move tests to tests/** — relocate files, update build.zig, merge inline tests
7. **Verify tests** — `zig build test` passing
8. **Update migration-progress.md** — mark Phase 6 complete
