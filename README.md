![Connect the dots](assets/banner.jpg)

# dots

> **Fast, minimal task tracking with plain markdown files — no database required**

Minimal task tracker for AI coding agents.

|               |       beads (SQLite) |           dots (markdown) |
| ------------- | -------------------: | ------------------------: |
| Binary        |                25 MB | **200 KB** (125x smaller) |
| Lines of code |              115,000 |      **2,800** (41x less) |
| Dependencies  |      Go, SQLite/Wasm |                      None |
| Portability   | Rebuild per platform |    Copy `.dots/` anywhere |

## What is dots?

A CLI task tracker with **zero dependencies** — tasks are plain markdown files with YAML frontmatter in `.dots/`. No database, no server, no configuration. Copy the folder between machines, commit to git, edit with any tool. Each task has an ID, title, status, priority, and optional blocking dependencies.

## Contributing

Please open an issue with the details of the feature you want, including the AI prompt if possible, instead of submitting PRs.

## Installation

### Homebrew

```bash
brew install joelreymont/tap/dots
```

### From source (requires Zig 0.15+)

```bash
git clone https://github.com/joelreymont/dots.git
cd dots
zig build -Doptimize=ReleaseSmall
cp zig-out/bin/dot ~/.local/bin/
```

### Verify installation

```bash
dot --version
# Output: dots 0.6.4
```

## Quick Start

```bash
# Initialize in current directory
dot init
# Creates: .dots/ directory (added to git if in repo)

# Open a task
dot open "Fix the login bug" -s app
# Output: app-001

# List tasks
dot list
# Output: [app-001] o Fix the login bug

# Start working
dot start app-001

# Complete task
dot close app-001 -r "Fixed in commit abc123"
```

## Scopes

Every task belongs to a **scope** — a short label like `app`, `docs`, or `tests`.

```bash
# Specify scope explicitly
dot open "Design API" -s app        # → app-001
dot open "Write docs" -s docs       # → docs-001

# Or set a default scope
export DOTS_DEFAULT_SCOPE=app
dot open "Quick task"               # → app-002
```

## Command Reference

### Initialize

```bash
dot init
```

Creates `.dots/` directory. Runs `git add .dots` if in a git repository. Safe to run if already initialized.

### Open Task

```bash
dot open "title" -s <scope> [-p PRIORITY] [-d "description"]
dot create "title" -s <scope>  # alias
```

Options:

- `-s <scope>`: Scope name (required if `DOTS_DEFAULT_SCOPE` is not set)
- `-p N`: Priority 0–9 (0 = highest, default 2)
- `-d "text"`: Description (markdown body of the file)

Examples:

```bash
dot open "Design API" -p 1 -s app
# Output: app-001

dot open "Implement API" -d "REST endpoints" -s app
# Output: app-002
```

### List Tasks

```bash
dot list [--status STATUS]
dot ls   # alias
```

Options:

- `--status`: Filter by `open`, `active`, or `closed` (default: shows all non-closed)

Output format:

```
[app-001] o Design API       # o = open
[app-002] > Implement API    # > = active
[app-003] x Write tests      # x = closed
```

### Start Working

```bash
dot start <id> [id2 ...]
```

Marks task(s) as `active`. If a task is blocked by open issues, a warning is shown but the command proceeds.

```bash
$ dot start app-002
Warning: app-002 is blocked by:
  app-001 (open) - Design API
```

### Close Task

```bash
dot close <id|scope> [id2 ...] [-r "reason"]
```

Marks task(s) as `closed` and archives them. Pass a scope name to close all issues in that scope.

```bash
dot close app-001 -r "shipped"   # Close one task
dot close -s app                 # Close all app-* tasks
```

### Show Task Details

```bash
dot show <id>
```

Shows issue details plus its full dependency context — what blocks it and what it blocks.

```
ID:       app-002
Title:    Implement API
Status:   open
Priority: 2
Created:  2024-12-24T10:30:00Z

Blocked by:
  └─ app-001 (open) - Design API

Blocks:
  └─ app-003 (open) - Write tests
```

### Show Dependency Tree

```bash
dot tree [scope]
```

Shows all scopes and their open/active issues. Pass a scope name to filter.

```
app (2 open)
  ├─ app-001 ○ Design API
  └─ app-002 ○ Implement API
docs (1 open)
  └─ docs-001 ○ API documentation
```

### Block / Unblock

```bash
dot block <id> <blocker-id>     # Mark id as blocked by blocker-id
dot unblock <id> <blocker-id>   # Remove that blocking relationship
```

Blocking relationships are stored in the issue's frontmatter. A blocked task is excluded from `dot ready` until all its blockers are closed.

```bash
dot block app-002 app-001       # app-002 can't start until app-001 is done
dot unblock app-002 app-001     # Remove that constraint
```

### Show Ready Tasks

```bash
dot ready
```

Lists tasks that are `open` and have no open blocking dependencies. Run with no arguments to see what to work on next.

### Remove Task

```bash
dot rm <id> [id2 ...]
```

Permanently deletes task file(s) and removes any references to them from other tasks' dependency lists.

### Search Tasks

```bash
dot find "query"
```

Case-insensitive search across title, description, close-reason, created-at, and closed-at. Shows open tasks first, then archived.

### Purge Archive

```bash
dot purge
```

Permanently deletes all archived (closed) tasks from `.dots/archive/`.

## Storage Format

```
.dots/
  app/
    app-001.md
    app-002.md
  docs/
    docs-001.md
  archive/
    app/
      app-003.md   # closed tasks
```

### File Format

```markdown
---
title: Implement API
status: open
priority: 2
created-at: 2024-12-24T10:30:00Z
blockers:
  - app-001
---

REST endpoints for user management.
```

### ID Format

IDs have the format `{scope}-{NNN}`:

- `scope`: Short label for the work area (`app`, `docs`, `tests`, …)
- `NNN`: Auto-incrementing 3-digit number (4 digits after 999)

Examples: `app-001`, `docs-064`, `tests-135`

Commands accept short prefixes:

```bash
dot start app-0    # Matches app-001 if unambiguous
dot show app       # Error: ambiguous (matches all app-*)
```

### Status Flow

```
open → active → closed (archived)
```

- `open`: Task created, not started
- `active`: Currently being worked on
- `closed`: Completed, moved to `.dots/archive/`

### Priority Scale

- `0`: Critical
- `1`: High
- `2`: Normal (default)
- `3`: Low
- `4+`: Backlog

## Agent Integration

dots is a pure CLI tool. For Claude Code and Codex integration (session management, auto-continuation, context clearing), use [banjo](https://github.com/joelreymont/banjo).

## Why dots?

| Feature           | Description                                    |
| ----------------- | ---------------------------------------------- |
| Markdown files    | Human-readable, git-friendly storage           |
| YAML frontmatter  | Structured metadata with flexible body         |
| Scoped IDs        | `app-001` instead of opaque hex strings        |
| Short prefixes    | Type `app-0` instead of the full ID            |
| Archive           | Closed tasks out of sight, available if needed |
| Zero dependencies | Single binary, no runtime requirements         |

## License

MIT
