#!/bin/bash
# migrate-dots.sh - Convert .beads SQLite to .dots markdown
# Requirements: sqlite3, jq
set -e

# Check for required tools
command -v sqlite3 >/dev/null 2>&1 || { echo "Error: sqlite3 is required but not installed."; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed."; exit 1; }
command -v dot >/dev/null 2>&1 || { echo "Error: dot CLI is required but not installed."; exit 1; }

# Check for beads database
if [ ! -f .beads/beads.db ]; then
    echo "No .beads/beads.db found in current directory"
    exit 1
fi

# Count issues in SQLite
EXPECTED=$(sqlite3 .beads/beads.db 'SELECT COUNT(*) FROM issues')
echo "Found $EXPECTED issues in .beads/beads.db"

if [ "$EXPECTED" -eq 0 ]; then
    echo "No issues to migrate"
    exit 0
fi

# Create temp file for export
EXPORT_FILE=$(mktemp /tmp/dots-export.XXXXXX.jsonl)
trap "rm -f $EXPORT_FILE" EXIT

# Export issues with embedded dependencies to JSONL
echo "Exporting issues..."
sqlite3 -json .beads/beads.db <<'SQL' | jq -c '.[] | .dependencies = (.dependencies | fromjson)' > "$EXPORT_FILE"
SELECT
  i.id,
  i.title,
  i.description,
  i.status,
  i.priority,
  i.issue_type,
  i.assignee,
  i.created_at,
  i.updated_at,
  i.closed_at,
  i.close_reason,
  (SELECT json_group_array(json_object('depends_on_id', d.depends_on_id, 'type', d.type))
   FROM dependencies d WHERE d.issue_id = i.id) AS dependencies
FROM issues i;
SQL

EXPORTED=$(wc -l < "$EXPORT_FILE" | tr -d ' ')
echo "Exported $EXPORTED issues to JSONL"

# Backup existing .dots if present
if [ -d .dots ]; then
    BACKUP=".dots.backup.$(date +%Y%m%d%H%M%S)"
    echo "Backing up existing .dots to $BACKUP"
    mv .dots "$BACKUP"
fi

# Import into new dots
echo "Importing into .dots..."
dot init --from-jsonl "$EXPORT_FILE"

# Count imported issues
IMPORTED=$(find .dots -name "*.md" -type f 2>/dev/null | grep -v archive | wc -l | tr -d ' ')
echo "Imported $IMPORTED issues"

# Verify migration by comparing JSON output
echo "Verifying migration..."

VERIFY_ORIGINAL=$(mktemp /tmp/dots-verify-original.XXXXXX.json)
VERIFY_NEW=$(mktemp /tmp/dots-verify-new.XXXXXX.json)
trap "rm -f $EXPORT_FILE $VERIFY_ORIGINAL $VERIFY_NEW" EXIT

# Normalize original export (sorted by id, relevant fields only, normalize status)
jq -s 'map({id, title, status: (if .status == "closed" then "done" else .status end), priority}) | sort_by(.id)' "$EXPORT_FILE" > "$VERIFY_ORIGINAL"

# Get all issues from new dots as JSON (combine all statuses, sorted by id)
{
    dot ls --status open --json
    dot ls --status active --json
    dot ls --status closed --json
} | jq -s 'add | map({id, title, status, priority}) | sort_by(.id)' > "$VERIFY_NEW"

# Compare
if diff -q "$VERIFY_ORIGINAL" "$VERIFY_NEW" > /dev/null; then
    echo ""
    echo "Migration successful: $EXPECTED issues migrated and verified"
    echo ""
    echo "You can now safely delete the old database:"
    echo "  rm -rf .beads/"
else
    echo ""
    echo "WARNING: Migration verification found differences!"
    echo ""
    echo "Comparing original vs imported:"
    diff "$VERIFY_ORIGINAL" "$VERIFY_NEW" | head -20 || true
    echo ""
    echo "Please check .dots/ manually. Do NOT delete .beads/ until verified."
    exit 1
fi
