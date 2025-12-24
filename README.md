# dots

> **Connect the dots.**

Minimal task tracker in Zig. Single file, ~1ms startup, no daemon.

## Install

```bash
zig build -Doptimize=ReleaseFast
cp zig-out/bin/dot ~/.local/bin/
```

Requires Zig 0.15+.

## Usage

```bash
dot "Fix the bug"                    # quick add
dot add "Task" -p 1 -d "Details..."  # with priority & description
dot ls                               # list open tasks
dot it d-1                           # start working ("I'm on it!")
dot off d-1 -r "shipped"             # complete ("cross it off")
dot tree                             # show hierarchy
dot ready                            # show unblocked tasks
```

## Commands

| Command | Description |
|---------|-------------|
| `dot "title"` | Quick add |
| `dot add "title" [-p N] [-d "desc"] [-P parent] [-a after]` | Add with options |
| `dot ls [--status S] [--json]` | List dots |
| `dot it <id>` | Start working |
| `dot off <id> [-r reason]` | Complete |
| `dot rm <id>` | Remove |
| `dot show <id>` | Show details |
| `dot tree` | Show hierarchy |
| `dot ready [--json]` | Show unblocked |
| `dot find "query"` | Search |

## Data Model

```json
{"id":"d-1","title":"Fix bug","status":"open","priority":2,"parent":null,"after":null}
```

- **status**: `open` → `active` → `done`
- **priority**: 0-4 (0 = highest)
- **parent**: hierarchical grouping
- **after**: blocked until that dot is done

## Dependencies

```bash
dot add "Design API"
# d-1

dot add "Implement API" -a d-1
# d-2 (blocked by d-1)

dot ready
# [d-1] Design API     ← only d-1 is ready

dot off d-1
dot ready
# [d-2] Implement API  ← now d-2 is ready
```

## Hierarchy

```bash
dot add "Build auth"
# d-1

dot add "Design" -P d-1
dot add "Implement" -P d-1 -a d-2
dot add "Test" -P d-1 -a d-3

dot tree
# [d-1] ○ Build auth
#   └─ [d-2] ○ Design
#   └─ [d-3] ○ Implement (blocked)
#   └─ [d-4] ○ Test (blocked)
```

## Storage

Single `.dots` file (JSONL) in current directory. No database, no daemon, no config.

## Beads Compatibility

Drop-in replacement for beads hooks:

```bash
dot create "title" -p 2 -d "desc" --json
dot update <id> --status in_progress
dot close <id> --reason "done"
dot list --json --status open
dot ready --json
```

## Why dots?

| | beads | dots |
|---|-------|------|
| Startup | ~50-100ms | ~1ms |
| Storage | SQLite + JSONL | JSONL only |
| Commands | 50+ | 10 |
| Daemon | Required | None |
| Config | Complex | Zero |

## License

MIT
