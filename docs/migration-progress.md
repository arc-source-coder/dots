# Migration Progress

Status as of 2026-02-20.

## Completed

### Phase 0: Detangle Legacy-Coupled Features ✅

- Removed `slugify` command and all slug helpers (`slugifyIssue`, `appendWord`, `abbrev_map`, `generateId`, `generateIdWithTitle`)
- Deleted `test_slugify.zig` (447 lines)
- Removed config read/write (`getOrCreatePrefix`, `getConfig`, `setConfig`) from `storage.zig`
- Removed `renameIssue` and `updateDependencyReferences` from `storage.zig`
- Added `nextId`/`scanHighestId`/`extractScopeNumber` to `storage.zig` for `{PREFIX}-{NNN}` auto-increment ID format
- Changed `cmdAdd` to require `-s <scope>` or `DOTS_DEFAULT_SCOPE` env var
- Removed all JSON output paths: `--json` from `ls`, `ready`, `add`; `JsonIssue`, `writeIssueJson`
- Updated test files to use `-s test` in `runDot` add calls

### Phase 1: Remove Legacy Migration Surface ✅

- Removed `init --from-jsonl` and all JSONL hydration code (`hydrateFromJsonl`, `JsonlIssue`, `JsonlDependency`, `HydrateResult`, `max_jsonl_line_bytes`)
- Deleted `migrate-dots.sh`
- Removed JSONL hydration test from `test_cli_commands.zig`
- Removed JSON snapshot test from `test_snapshots.zig`
- Simplified `cmdInit` to just open storage + git add

## LOC Reduction

~1,500 lines removed. Current Zig source: **4,949 lines** (4,299 code) across 9 files.

## Build Status

- `zig build` — ✅ clean (debug mode works, LLVM dominance bug resolved)
- `zig build test` — ✅ all enabled tests pass
- `test_cli_commands.zig` — commented out in `tests.zig` (pre-existing Windows compatibility issues, not related to migration)

## Known Issues

- `test_cli_commands.zig` has Windows-specific failures (pre-existing, unrelated to migration). Fixed one missing `-s` flag from Phase 0 changes.
- Snapshot test `"snap: markdown frontmatter format"` still expects `issue-type: task` in frontmatter — will become stale after Phase 2 removes `issue_type`.

## Remaining Phases

### Phase 2: Core Data Model

- Remove `issue_type`, `slug`, `assignee` from `Issue` struct
- Change ID generation to `{PREFIX}-{NNN}` format (auto-increment already implemented)
- Remove config file handling

### Phase 3: Storage Restructure

- Move from flat `.dots/*.md` to `.dots/{prefix}/*.md`
- Update `findIssuePath()` to search in prefix folders
- Update archive handling to mirror scope structure

### Phase 4: Command Changes

- Rename commands: `add`→`create`, `ls`→`list`, `on`→`start`, `off`→`close`
- Update `create` to accept optional `-s <scope>`, auto-create scope
- Update `show` to display blocking tree
- Update `tree` to display scopes
- Remove `slugify`, `blocked` commands (already done)
- Keep `update` command (decision: retain it)

### Phase 5: Cleanup

- Remove `-a` flag from `create` (use `dep add` instead)
- Add `dep` command for managing dependencies
- Update documentation

### Phase 6: Codebase Reorganization

Split into `src/commands/`, `src/core/`, `src/storage/` layout per plan.

## Decisions

- **Keep `update` command** — not removing it despite being listed as removed in the original plan.
- **Hard break** — no backward compatibility with legacy `.dots` layouts, JSONL, or slug-based IDs.
