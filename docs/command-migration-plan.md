# Command & Architecture Migration Plan

## Overview

Major simplification of dots — new storage format, commands, and data model. Major source cleanup, code quality improvement, and reorganization.

This plan now assumes a **hard break**:

- No JSONL hydration path
- No `beads` migration script
- No backward-compat support for legacy `.dots` layouts

## New Storage Format

```
.dots/
  .archive/
  app/
    app-001.md
    app-002.md
  docs/
    docs-001.md
  tests/
    tests-001.md
```

- Each prefix (scope) is a folder inside `.dots/`
- Issues stored as `{PREFIX}-{NNN}.md` inside their scope folder
- Archive is inside `.archive/` with same structure
- No config file — state derived from filesystem

## ID Format

- **Format**: `{PREFIX}-{NNN}` where NNN is 3-4 digit auto-increment
- **Example**: `app-001`, `docs-064`, `tests-135`
- **Auto-increment logic**:
  1. Scan scope directory for existing issues
  2. Sort by number descending
  3. Next ID = highest + 1
  4. If exceeds 999, expand to 4 digits (1000+)
  5. No config file needed — purely filesystem-based

## Command Mapping

| Current       | Proposed | Aliases        | Notes                          |
| ------------- | -------- | -------------- | ------------------------------ |
| `add`         | `create` | _(none)_       | New primary                    |
| `ls`          | `list`   | `ls`           | Keeps `ls` alias               |
| `on`, `it`    | `start`  | _(none)_       | Renamed to `start`             |
| `off`, `done` | `close`  | _(none)_       | New primary                    |
| `rm`          | `rm`     | `rm`, `delete` | Unchanged                      |
| `show`        | `show`   | `show`         | Now shows blocking tree        |
| `ready`       | `ready`  | `ready`        | Unchanged                      |
| `tree`        | `tree`   | `tree`         | Shows scopes in tree format    |
| `find`        | `find`   | `find`         | Unchanged                      |
| `purge`       | `purge`  | `purge`        | Unchanged                      |
| `init`        | `init`   | `init`         | Simplified — just creates dirs |

## Removed Commands

| Command   | Reason                          |
| --------- | ------------------------------- |
| `slugify` | New issues no longer have slugs |
| `blocked` | Integrated into `show`          |
| `update`  | Redundant with `start`/`close`  |

## New Commands

### `dot create "title" [-s <scope>]`

Create a new issue in specified scope. If scope doesn't exist, create it.

```bash
dot create "Fix login bug" -s app      # → app-001
dot create "Write docs" -s docs        # → docs-001
dot create "Add tests" -s tests        # → tests-001

# With DOTS_DEFAULT_SCOPE=app
dot create "Quick task"                # → app-002 (uses default scope)
dot create "Other task" -s docs        # → docs-001 (override default)
```

**Environment Variable**: `DOTS_DEFAULT_SCOPE` — sets default scope when `-s` is omitted.

### `dot show <id>`

Shows issue details AND blocking tree:

```
ID:       app-001
Title:    Fix login bug
Status:   open
Priority: 1
Desc:     Users cannot reset password
Created:  2024-12-24T10:30:00Z

Blocked by:
  └─ app-002 (open) - Setup database
  └─ app-003 (open) - Get DB credentials
```

### `dot tree`

Shows all scopes and their issues:

```
app (2 open, 1 closed)
  ├─ app-001 ○ Fix login bug
  └─ app-002 ○ Setup database
docs (1 open)
  └─ docs-001 ○ API documentation
tests (0 open)
```

### `dot start <id>`

Start working on an issue (status becomes active). If the issue is blocked by other open issues, a warning is shown with the blocking tree:

```bash
$ dot start app-003
Warning: app-003 is blocked by the following open issues:

app-001 (open) - Setup database
  └─ app-002 (open) - Get DB credentials

Started app-003.
```

The command proceeds after showing the warning (does not block the operation).

### `dot close <id>` / `dot close -s <scope>`

Close an issue (or all issues in a scope) and archive them. When an issue is closed, it automatically frees any issues that were blocked by it.

```bash
dot close app-001           # Closes app-001, frees any issues blocked by it
dot close -s app            # Closes all app-* issues, moves to archive
```

## Data Model Changes

### Removed Fields

- `issue_type` — Always "task", no longer stored
- `slug` — Removed from ID format
- `assignee` — Removed (can be added later if needed)

### Issue Struct (Simplified)

```zig
pub const Issue = struct {
    id: []const u8,        // e.g., "app-001"
    title: []const u8,
    description: []const u8,
    status: Status,        // open, active, closed
    priority: i64,        // 0-3 (P0, P1, P2, P3) - Probably don't need i64 here
    created_at: []const u8,
    closed_at: ?[]const u8,
    close_reason: ?[]const u8,
    blocks: []const []const u8,  // IDs this issue is blocked by
};
```

`Issue.zig` is the core issue module and should own:

- `Issue`/`Status` types
- issue-level operations and invariants (create/start/close/list-ready/show-tree inputs)
- orchestration with storage via a narrow storage interface

`Issue.zig` should not own CLI argument parsing/printing or filesystem/frontmatter details.

### Storage File Format

```markdown
---
title: Fix login bug
status: open
priority: 1
created-at: 2024-12-24T10:30:00Z
blocks:
  - app-002
---

Description as markdown body.
```

## Implementation Phases

### Phase 0: Detangle Legacy-Coupled Features (Do First)

Goal: reduce risky cross-cutting code before changing IDs/layout.

1. Remove `slugify` command and all slug helpers (`slugifyIssue`, slug generation helpers)
2. Remove config read/write usage for prefix (`getOrCreatePrefix`, `getConfig`, `setConfig`)
3. Replace prefix/config behavior with explicit `-s` or `DOTS_DEFAULT_SCOPE`
4. Delete tests that only cover slug/config behavior, keep behavior-neutral tests intact

### Phase 1: Remove Legacy Migration Surface

1. Remove `init --from-jsonl` support
2. Delete JSONL hydration code from CLI entrypoint
3. Remove `migrate-dots.sh`
4. Remove migration docs/tests tied to JSONL import

### Phase 2: Core Data Model

1. Remove `issue_type`, `slug`, `assignee` from Issue struct
2. Change ID generation to `{PREFIX}-{NNN}` format
3. Implement auto-increment via directory scan
4. Remove config file handling

### Phase 3: Storage Restructure

1. Move from flat `.dots/*.md` to `.dots/{prefix}/*.md`
2. Update `findIssuePath()` to search in prefix folders
3. Update archive handling to mirror scope structure

### Phase 4: Command Changes

1. Rename commands (add→create, ls→list, on→start, off→close)
2. Update `create` to accept optional `-s <scope>` (uses `DOTS_DEFAULT_SCOPE` env var), auto-create scope
3. Update `show` to display blocking tree
4. Update `tree` to display scopes
5. Remove `slugify`, `blocked`, `update` commands

### Phase 5: Cleanup

1. Remove `-a` flag from `create` (use `dep add` instead)
2. Add `dep` command for managing dependencies
3. Update documentation

### Phase 6: Codebase Reorganization

Target layout (open to change):

```
src/
  main.zig
  commands/
    create.zig
    list.zig
    start.zig
    close.zig
    show.zig
    tree.zig
    ready.zig
    find.zig
    rm.zig
    init.zig
    purge.zig
  core/
    Issue.zig
  storage/
    mod.zig
    repository.zig
    paths.zig
    frontmatter.zig
```

Responsibilities:

1. `src/main.zig`: bootstrap, command parsing, dispatch, top-level error mapping only
2. `src/commands/*`: thin command adapters; parse command args and call `core`
3. `src/core/Issue.zig`: issue domain + use-case operations, coordinates with storage
4. `src/storage/*`: path layout, frontmatter parse/serialize, persistence and query logic

## File Changes Summary

| File                             | Changes                                                    |
| -------------------------------- | ---------------------------------------------------------- |
| `src/main.zig`                   | Reduced to parse/dispatch/bootstrap/error handling         |
| `src/commands/*.zig`             | New command modules; one command per file                  |
| `src/core/Issue.zig`             | New issue domain/use-case module (public API for commands) |
| `src/storage/*.zig`              | Split storage concerns (repository, paths, frontmatter)    |
| `README.md`                      | Full command reference update                              |
| `docs/command-migration-plan.md` | This document                                              |

## Testing

Test strategy:

- Keep **unit tests** in their implementation files
- Move **property tests** and **CLI/integration tests** to `tests/` at root.
- Add a dedicated test root (`src/tests.zig` or `tests/main.zig`) instead of importing tests from `src/main.zig`

```bash
# Run existing tests
zig build test

# Manual testing - basic flow
dot init
dot create "Fix bug" -s app
dot create "Write doc" -s docs
dot list
dot list -s app
dot show app-001
dot start app-001
dot close app-001
dot close -s app
dot tree
dot find "bug"

# Testing default scope
dot create "Task without prefix"  # Should fail (no DOTS_DEFAULT_SCOPE)
DOTS_DEFAULT_SCOPE=app dot create "Task with default"  # Creates app-XXX

# Testing blocking behavior
dot create "Setup DB" -s app              # app-001
dot create "Fix login" -s app             # app-002
dot dep add app-002 app-001               # app-002 blocked by app-001
dot start app-002                         # Should show warning about app-001 blocking it
dot close app-001                         # Should free app-002 from blocking
```
