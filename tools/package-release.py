"""Builds the files a numbered release ships, into build-release/<tag>/.

    python tools/package-release.py v0.1.0 [--skip-exports]

Three archives:

    soundgraph-editor-windows-x64-<tag>.zip   the desktop editor: SoundGraphEditor.exe with
                                              its extension DLL beside it (tools/export-desktop.mjs)
    soundgraph-editor-web-<tag>.zip           the web editor, to unpack onto any static host
                                              (tools/export-web.mjs)
    soundgraph-axoloti-mpk-mini-card-<tag>.zip  the Axoloti card image of the MPK mini set:
                                              copy its contents to the root of the board's SD
                                              card (embedded/axoloti/tools/hw.py flash writes the
                                              same files over USB)

The tag has to exist before the exports run, because each export stamps itself from
`git describe`: a build made before the tag says "+n commits past the last tag", which
is a build claiming to be something else. So the order is tag, then this, then the
release. The card image is whatever `hw.py flash` last baked; run the flash (or
bake-bank.py) first if the bank changed.

Publishing is a GitHub release on the tag with these three files attached. Without the
gh CLI it is two calls to the REST API (create the release, then POST each file to its
upload_url), which this script prints at the end rather than performs: putting files in
front of the public is a step somebody should take on purpose.
"""

import argparse
import pathlib
import subprocess
import sys
import zipfile

REPO = pathlib.Path(__file__).resolve().parent.parent
CARD = REPO / "embedded" / "axoloti" / "build" / "bank" / "axoloti-akai-mpk-mini"


def run(*command):
    print("+", " ".join(str(c) for c in command))
    subprocess.run([str(c) for c in command], check=True, cwd=REPO)


def zip_dir(source, target, inner=""):
    """`source`'s contents into `target`, under `inner/` if given."""
    count = 0
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for path in sorted(source.rglob("*")):
            if path.is_file():
                name = path.relative_to(source).as_posix()
                z.write(path, f"{inner}/{name}" if inner else name)
                count += 1
    print(f"  {target.name}: {count} files, {target.stat().st_size / 1e6:.1f} MB")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tag", help="the release tag, e.g. v0.1.0; must already exist")
    parser.add_argument("--skip-exports", action="store_true",
                        help="zip what build-godot-desktop/ and build-godot-web/ already hold")
    args = parser.parse_args()

    described = subprocess.run(["git", "describe", "--tags", "--exact-match", "HEAD"],
                               capture_output=True, text=True, cwd=REPO).stdout.strip()
    if described != args.tag:
        raise SystemExit(f"HEAD is {described or 'not at a tag'}, not {args.tag}: tag first, "
                         "so the builds stamp themselves with the release")
    if not (CARD / "index.axb").exists():
        raise SystemExit(f"no card image at {CARD}: run hw.py flash or bake-bank.py first")

    out = REPO / "build-release" / args.tag
    out.mkdir(parents=True, exist_ok=True)
    if not args.skip_exports:
        run("node", REPO / "tools" / "export-desktop.mjs")
        run("node", REPO / "tools" / "export-web.mjs")
    desktop = REPO / "build-godot-desktop"
    web = REPO / "build-godot-web"
    for required in (desktop / "SoundGraphEditor.exe", desktop / "soundgraph_godot.dll", web / "index.html"):
        if not required.exists():
            raise SystemExit(f"missing {required}")

    zip_dir(desktop, out / f"soundgraph-editor-windows-x64-{args.tag}.zip", "SoundGraphEditor")
    zip_dir(web, out / f"soundgraph-editor-web-{args.tag}.zip")
    zip_dir(CARD, out / f"soundgraph-axoloti-mpk-mini-card-{args.tag}.zip")

    print(f"""
release files in {out}

To publish (a token with repo scope in GITHUB_TOKEN):
  curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" \\
    https://api.github.com/repos/TheMutantFactory/soundgraph/releases \\
    -d '{{"tag_name":"{args.tag}","name":"SoundGraph {args.tag}","body":"...","draft":false}}'
  then for each file, POST it to the upload_url the answer gives:
  curl -s -X POST -H "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/zip" \\
    --data-binary @<file> "https://uploads.github.com/repos/TheMutantFactory/soundgraph/releases/<id>/assets?name=<file>"
""")


if __name__ == "__main__":
    main()
