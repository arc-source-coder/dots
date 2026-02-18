# Command & Architecture Migration Plan

## Overview

Major simplification of dots — new storage format, commands, and data model.

## New Storage Format

```
.dots/
  .archive/
  app/
    APP-001.md
    APP-002.md
  docs/
    DOCS-001.md
  tests/
    TEST-001.md
```

- Each prefix (scope) is a folder inside `.dots/`
- Issues stored as `{PREFIX}-{NNN}.md` inside their scope folder
- Archive is inside `.archive/` with same structure
- No config file — state derived from filesystem

## ID Format

- **Format**: `{PREFIX}-{NNN}` where NNN is 3-4 digit auto-increment
- **Example**: `APP-001`, `DOCS-064`, `TEST-135`
- **Auto-increment logic**:
  1. Scan scope directory for existing issues
  2. Sort by number descending
  3. Next ID = highest + 1
  4. If exceeds 999, expand to 4 digits (1000+)
  5. No config file needed — purely filesystem-based

## Command Mapping

| Current | Proposed | Aliases | Notes |
|---------|----------|---------|-------|
| `add` | `create` | *(none)* | New primary |
| `ls` | `list` | `ls` | Keeps `ls` alias |
| `on`, `it` | `start` | *(none)* | Renamed to `start` |
| `off`, `done` | `close` | *(none)* | New primary |
| `rm` | `rm` | `rm`, `delete` | Unchanged |
| `show` | `show` | `show` | Now shows blocking tree |
| `ready` | `ready` | `ready` | Unchanged |
| `tree` | `tree` | `tree` | Shows scopes in tree format |
| `find` | `find` | `find` | Unchanged |
| `purge` | `purge` | `purge` | Unchanged |
| `init` | `init` | `init` | Simplified — just creates dirs |

## Removed Commands

| Command | Reason |
|---------|--------|
| `slugify` | New issues no longer have slugs |
| `blocked` | Integrated into `show` |
| `update` | Redundant with `start`/`close` |

## New Commands

### `dot create "title" [-p <prefix>]`

Create a new issue in specified scope (prefix). If scope doesn't exist, create it.

```bash
dot create "Fix login bug" -p app      # → APP-001
dot create "Write docs" -p docs        # → DOCS-001
dot create "Add tests" -p tests        # → TEST-001

# With DOTS_DEFAULT_SCOPE=app
dot create "Quick task"                # → APP-002 (uses default scope)
dot create "Other task" -p docs        # → DOCS-001 (override default)
```

**Environment Variable**: `DOTS_DEFAULT_SCOPE` — sets default prefix when `-p` is omitted.

### `dot show <id>`

Shows issue details AND blocking tree:

```
ID:       APP-001
Title:    Fix login bug
Status:   open
Priority: 1
Desc:     Users cannot reset password
Created:  2024-12-24T10:30:00Z

Blocked by:
  └─ APP-002 (open) - Setup database
      └─ APP-003 (open) - Get DB credentials
```

### `dot tree`

Shows all scopes and their issues:

```
app (2 open, 1 closed)
  ├─ APP-001 ○ Fix login bug
  └─ APP-002 ○ Setup database
docs (1 open)
  └─ DOCS-001 ○ API documentation
tests (0 open)
```

### `dot start <id>`

Start working on an issue. If the issue is blocked by other open issues, a warning is shown with the blocking tree:

```bash
$ dot start APP-003
Warning: APP-003 is blocked by the following open issues:

APP-001 (open) - Setup database
  └─ APP-002 (open) - Get DB credentials

Started APP-003.
```

The command proceeds after showing the warning (does not block the operation).

### `dot close <id>` / `dot close -p <prefix>`

Close an issue (or all issues in a scope) and archive them. When an issue is closed, it automatically frees any issues that were blocked by it.

```bash
dot close APP-001           # Closes APP-001, frees any issues blocked by it
dot close -p app            # Closes all APP-* issues, moves to archive
```

## Data Model Changes

### Removed Fields

- `issue_type` — Always "task", no longer stored
- `slug` — Removed from ID format
- `assignee` — Removed (can be added later if needed)

### Issue Struct (Simplified)

```zig
pub const Issue = struct {
    id: []const u8,        // e.g., "APP-001"
    title: []const u8,
    description: []const u8,
    status: Status,        // open, active, closed
    priority: i64,        // 0-4
    created_at: []const u8,
    closed_at: ?[]const u8,
    close_reason: ?[]const u8,
    blocks: []const []const u8,  // IDs this issue is blocked by
};
```

### Storage File Format

```markdown
---
title: Fix login bug
status: open
priority: 1
created-at: 2024-12-24T10:30:00Z
blocks:
  - APP-002
---

Description as markdown body.
```

## Implementation Phases

### Phase 1: Core Data Model

1. Remove `issue_type`, `slug`, `assignee` from Issue struct
2. Change ID generation to `{PREFIX}-{NNN}` format
3. Implement auto-increment via directory scan
4. Remove config file handling

### Phase 2: Storage Restructure

1. Move from flat `.dots/*.md` to `.dots/{prefix}/*.md`
2. Update `findIssuePath()` to search in prefix folders
3. Update archive handling to mirror scope structure

### Phase 3: Command Changes

1. Rename commands (add→create, ls→list, on→start, off→close)
2. Update `create` to accept optional `-p <prefix>` (uses `DOTS_DEFAULT_SCOPE` env var), auto-create scope
3. Update `show` to display blocking tree
4. Update `tree` to display scopes
5. Remove `slugify`, `blocked`, `update` commands

### Phase 4: Cleanup

1. Remove `-a` flag from `create` (use `dep add` instead)
2. Add `dep` command for managing dependencies
3. Update documentation

## File Changes Summary

| File | Changes |
|------|---------|
| `src/main.zig` | Rename commands, update `create` for scopes, update `show`/`tree`, remove commands |
| `src/storage.zig` | New ID format, auto-increment, scope-based storage, remove config |
| `README.md` | Full command reference update |
| `docs/command-migration-plan.md` | This document |

## Migration Notes

- Old `.dots/` format will need migration script
- Existing issues without slugs just get new ID format
- Archive structure changes — need to move to scope folders

## Testing

```bash
# Run existing tests
zig build test

# Manual testing - basic flow
dot init
dot create "Fix bug" -p app
dot create "Write doc" -p docs
dot list
dot list -p app
dot show APP-001
dot start APP-001
dot close APP-001
dot close -p app
dot tree
dot find "bug"

# Testing default scope
dot create "Task without prefix"  # Should fail (no DOTS_DEFAULT_SCOPE)
DOTS_DEFAULT_SCOPE=app dot create "Task with default"  # Creates APP-XXX

# Testing blocking behavior
dot create "Setup DB" -p app              # APP-001
dot create "Fix login" -p app --blocked-by APP-001   # APP-002
dot start APP-002                         # Should show warning about APP-001 blocking it
dot close APP-001                         # Should free APP-002 from blocking
```
