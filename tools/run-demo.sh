#!/usr/bin/env bash
# Restarts the demo: the SoundGraph editor, in 1:1 detail, without rebuilding — the
# macOS and Linux twin of run-demo.bat.
#
# For the show floor. test-soundgraph-godot.sh rebuilds before it launches, which is
# right at a desk and wrong in front of a queue -- a restart must take seconds and
# must not depend on a compiler. This launches whatever is already built, and tells
# the editor to start in 1:1 so every control is on every node however far out the
# graph is zoomed, at the 4K interface size - whose work area draws its words and
# cells at twice the chrome - whatever the last hand at the laptop left behind. Add
# --zoom=2 for twice that again, nodes and all.
#
# Full screen, through Godot's own switch (it goes before the --, where the engine
# reads its options; everything after the -- is the editor's). Alt+Enter is not a
# thing a queue should watch somebody remember.
#
# Anything else on the command line is passed through to the editor after its own
# arguments, so a patch or a further --detail= can follow. Quit is on the hamburger
# and on Ctrl+Q, so a full screen with no title bar still has a way out.
#
# The Godot binary comes from git config, the same place every other tool reads it.
# On a Mac either the bundle or the binary inside it will do:
#
#   git config soundgraph.godot ~/Downloads/godot-4.7.1/Godot.app
#   git config soundgraph.godot ~/Downloads/godot-4.7.1/Godot.app/Contents/MacOS/Godot
set -e
repo="$(cd "$(dirname "$0")/.." && pwd)"

godot=$(git -C "$repo" config --get soundgraph.godot || true)
if [ -z "$godot" ]; then
    echo "soundgraph.godot is not configured. Set it with:" >&2
    echo '  git config soundgraph.godot /path/to/Godot.app' >&2
    exit 1
fi
# A .app is a folder; the executable is inside it.
if [ -d "$godot" ] && [ -x "$godot/Contents/MacOS/Godot" ]; then
    godot="$godot/Contents/MacOS/Godot"
fi
if [ ! -x "$godot" ]; then
    echo "Configured Godot binary not found: $godot" >&2
    exit 1
fi

if [ ! -f "$repo/editor-godot/bin/libsoundgraph_godot.dylib" ] &&
   [ ! -f "$repo/editor-godot/bin/libsoundgraph_godot.so" ]; then
    echo "The extension has never been built here. Run tools/test-soundgraph-godot.sh once," >&2
    echo "at a desk, before demo day." >&2
    exit 1
fi

# The terminal goes down before the editor comes up. Whatever window this was typed
# into is minimised, not closed, so the output and the prompt are still there when
# the show is over. Best effort: the two Mac terminals that answer AppleScript, and
# xdotool where X11 has it; anywhere else the editor launches in front regardless.
case "$TERM_PROGRAM" in
    Apple_Terminal)
        osascript -e 'tell application "Terminal" to set miniaturized of front window to true' >/dev/null 2>&1 || true ;;
    iTerm.app)
        osascript -e 'tell application "iTerm2" to set miniaturized of current window to true' >/dev/null 2>&1 || true ;;
    *)
        if command -v xdotool >/dev/null 2>&1; then
            xdotool getactivewindow windowminimize >/dev/null 2>&1 || true
        fi ;;
esac

exec "$godot" --path "$repo/editor-godot" --fullscreen -- --detail=1:1 --size=4k --arrange --case=168 "$@"
