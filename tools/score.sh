#!/usr/bin/env bash
# score.sh — opens a dynamic score in its own window (editor-godot/score/, docs/scores.md).
#
#   tools/score.sh                                  # examples/scores/demo.score.json
#   tools/score.sh my.score.json                    # another score
#   tools/score.sh my.score.json entertainer        # ... playing the song with that id
#
# Godot comes from $SOUNDGRAPH_GODOT, else `git config soundgraph.godot` (as the gate).
# The extension must be built (tools/rebuild-extensions.sh --desktop).
set -euo pipefail
cd "$(dirname "$0")/.."

godot=${SOUNDGRAPH_GODOT:-$(git config --get soundgraph.godot || true)}
if [ -z "$godot" ] || [ ! -f "$godot" ]; then
    echo "score: Godot not found. Set it with:" >&2
    echo '  git config soundgraph.godot "C:/path/to/Godot_console.exe"' >&2
    exit 1
fi

score=${1:-examples/scores/demo.score.json}
[ -f "$score" ] || { echo "score: no such file: $score" >&2; exit 2; }
score=$(cd "$(dirname "$score")" && pwd -W 2>/dev/null || pwd)/$(basename "$score")

args=(--score "$score")
[ -n "${2:-}" ] && args+=(--song "$2")
exec "$godot" --path editor-godot res://score/score.tscn -- "${args[@]}"
