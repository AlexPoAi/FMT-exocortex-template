#!/bin/bash
set -euo pipefail

NOW_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
TODAY="$(date +"%Y-%m-%d")"

SRC_DIR="${OBSIDIAN_FLEETING_DIR:-/Users/alexander/Documents/Творческий конвеер/1. Исчезающие заметки}"
ARCHIVE_DIR="${OBSIDIAN_FLEETING_ARCHIVE_DIR:-/Users/alexander/Documents/Творческий конвеер/System/Архив исчезающих заметок}"
CAPTURES_FILE="${EXOCORTEX_CAPTURES_FILE:-/Users/alexander/Github/DS-strategy/inbox/captures.md}"

mkdir -p "$ARCHIVE_DIR"
mkdir -p "$(dirname "$CAPTURES_FILE")"
touch "$CAPTURES_FILE"

if [ ! -d "$SRC_DIR" ]; then
    echo "skip: source dir not found: $SRC_DIR"
    exit 0
fi

imported=0
shopt -s nullglob
for note in "$SRC_DIR"/*.md; do
    [ -f "$note" ] || continue
    base="$(basename "$note")"
    stem="${base%.md}"
    hash="$(shasum -a 256 "$note" | awk '{print $1}')"

    if grep -Fq "[obsidian-source-hash: $hash]" "$CAPTURES_FILE"; then
        continue
    fi

    {
        echo ""
        echo "## Capture: Obsidian fleeting — $stem"
        echo ""
        echo "- source: $note"
        echo "- imported_at: $NOW_UTC"
        echo "- obsidian-source-hash: $hash"
        echo ""
        cat "$note"
        echo ""
        echo "---"
    } >> "$CAPTURES_FILE"

    archive_target="$ARCHIVE_DIR/$TODAY - $base"
    if [ -e "$archive_target" ]; then
        short_hash="${hash:0:12}"
        archive_target="$ARCHIVE_DIR/$TODAY - ${stem} [$short_hash].md"
        counter=2
        while [ -e "$archive_target" ]; do
            archive_target="$ARCHIVE_DIR/$TODAY - ${stem} [$short_hash-$counter].md"
            counter=$((counter + 1))
        done
    fi

    mv "$note" "$archive_target"
    imported=$((imported + 1))
done

echo "obsidian-fleeting-intake: imported=$imported"
