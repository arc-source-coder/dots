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

### Phase 2: Core Data Model ✅

- Removed `issue_type`, `assignee`, and `parent` fields from the active issue model/frontmatter paths
- Removed related parent/child helper types and orphan-fix plumbing from storage
- Kept `{PREFIX}-{NNN}` ID generation via scope directory scanning (`nextId` + archive-aware scan)
- Retained explicit-scope creation flow (`-s` or `DOTS_DEFAULT_SCOPE`) with no config fallback

### Phase 3: Storage Restructure ✅

- Switched active storage to scope layout: `.dots/{scope}/{id}.md`
- Updated create path logic to derive scope from ID and auto-create scope folders
- Updated archive behavior to mirror scope layout: `.dots/archive/{scope}/{id}.md`
- Removed parent-folder hierarchy logic (no folder promotion/orphan repair/root-child traversal)
- Simplified deletion to single-issue file removal + dependency cleanup

### Additional Migration Work Completed

- Removed `fix` command from CLI dispatch and deleted `cmdFix`
- Removed `-P` and `-a` flags from `dot add`
- Updated `cmdAdd` to call `createIssue(issue)` (no parent argument)
- Stubbed `cmdTree` during hierarchy removal to keep compilation stable
- Updated help/usage text to remove parent/fix references

## LOC Reduction

~1,500 lines removed. Current Zig source: **4,949 lines** (4,299 code) across 9 files.

## Build Status

- `zig build` — ✅ clean
- `zig build test` — ✅ passing after Phase 2/3 expectation updates
- `test_cli_commands.zig` — enabled in `tests.zig`

## Known Issues

- Unrecognized commands/flags can still fall through silently to quick-add parsing. This is tracked as follow-up work.
- `tree` is intentionally stubbed during migration; tests currently only assert command viability, not final tree semantics.

## Tree Command Bring-Back Notes

- Re-enable `cmdTree` with scope-aware rendering over `.dots/{scope}/{id}.md`.
- Define output contract:
  - no-arg form shows scopes and issue rows
  - optional filters/status behavior is explicit (and tested)
  - stable ordering by scope name, then issue order (`priority`, `created_at`)
- Add focused tests:
  - scope aggregation counts
  - mixed open/active/closed visibility rules
  - archive exclusion/inclusion policy (explicit)
  - snapshot for output shape on both Unix/Windows newline handling (snap: tree output format is currently stubbed - proper snapshot should be restored)
- Remove temporary stub messaging and tighten CLI snapshots once behavior is finalized.

## Remaining Phases

### Phase 4: Command Changes

- Rename commands: `add`→`open` (alias: `create`), `ls`→`list`, `on`→`start`, `off`→`close`
- Update `open` to accept `-s <scope>`, auto-create scope
- Update `show` to display blocking tree
- Update `tree` to display all scopes
- Remove `slugify`, `blocked` commands (already done)
- Remove `fix` command (done)
- Keep `update` command (decision: retain it)
- Stop commands from silently accepting unknown flags. Don't fallback to `add` for unknown commands. Fail fast and fail loudly.

### Phase 5: Cleanup

- Remove `-a` flag from `create` (done; use `dep add` instead)
- Add `dep` command for managing dependencies
- Update documentation

### Phase 6: Codebase Reorganization

Split into `src/commands/`, `src/core/`, `src/storage/` layout per plan.

## Decisions

- **Keep `update` command** — not removing it despite being listed as removed in the original plan.
- **Hard break** — no backward compatibility with legacy `.dots` layouts, JSONL, or slug-based IDs.
