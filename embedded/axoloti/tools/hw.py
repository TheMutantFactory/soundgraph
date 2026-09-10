"""The editor's hand on the Axoloti: scan for the board, and flash a bank to it.

    python tools/hw.py scan
    python tools/hw.py flash BANK.json [--dry-run]

Both write run/axoloti-status.json at the repository root as they go, and the
editor draws that file rather than reading a pipe: a flash compiles every
entry and then writes the card at 60 KB/s, which is minutes, and a window
that says which entry it is on is the difference between patience and a
pulled cable. The file is one JSON object: action, state (running, done,
failed), step, the last forty log lines, and the result's own fields.

A bank is the ordered list the editor keeps (schema/bank.schema.json):

    {"schema_version": 1, "name": "Knobcon set",
     "entries": [{"name": "poly-five", "patch": "../examples/patches/poly-five.json"}]}

Entry order is MIDI Program Change order; patch paths are relative to the
bank file or absolute. Flashing bakes the bank with tools/bake-bank.py — the
same card layout, the same firmware loader — into build/bank/<bank>/ and then
writes it to the mounted card over USB. --dry-run stops after the bake.
"""

import argparse
import importlib.util
import io
import json
import os
import pathlib
import sys
import time
import traceback

HERE = pathlib.Path(__file__).resolve().parent
RIG = HERE.parent
REPO = RIG.parent.parent
sys.path.insert(0, str(RIG / "sgaxo"))
sys.path.insert(0, str(RIG / "driver"))

STATUS = REPO / "run" / "axoloti-status.json"


class Status:
    """The status file: rewritten whole at every step, atomically."""

    def __init__(self, action):
        self.data = {"action": action, "state": "running", "step": "",
                     "log": [], "started": time.time()}
        self.write()

    def step(self, text):
        self.data["step"] = text
        self.log(text)

    def log(self, line):
        line = line.rstrip()
        if not line:
            return
        self.data["log"] = (self.data["log"] + [line])[-40:]
        self.write()

    def finish(self, ok, **fields):
        self.data["state"] = "done" if ok else "failed"
        self.data.update(fields)
        self.data["finished"] = time.time()
        self.write()

    def write(self):
        STATUS.parent.mkdir(parents=True, exist_ok=True)
        text = json.dumps(self.data, indent=1)
        tmp = STATUS.with_suffix(".tmp")
        tmp.write_text(text)
        # The editor reads this file while it is being written, and on Windows a file
        # somebody has open cannot be replaced: the rename is refused for as long as
        # the reader holds it, which is a few milliseconds a few times a second. So
        # the rename is tried for a moment, and if it keeps being refused the text
        # goes in place instead — not atomic, but a reader that catches a half-written
        # file parses nothing and looks again.
        for _attempt in range(40):
            try:
                os.replace(tmp, STATUS)
                return
            except PermissionError:
                time.sleep(0.025)
        try:
            STATUS.write_text(text)
        finally:
            try:
                tmp.unlink()
            except OSError:
                pass


class Tee(io.TextIOBase):
    """Stdout that also lands in the status log, so the baker's own
    "compiling x as bank entry n" lines reach the editor unchanged."""

    def __init__(self, status, real):
        self.status = status
        self.real = real
        self.buffer_ = ""

    def write(self, text):
        self.real.write(text)
        self.real.flush()
        self.buffer_ += text
        while "\n" in self.buffer_:
            line, self.buffer_ = self.buffer_.split("\n", 1)
            self.status.log(line)
        return len(text)

    def flush(self):
        self.real.flush()


def load_bake_bank():
    spec = importlib.util.spec_from_file_location("bake_bank", HERE / "bake-bank.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def toolchain_report():
    import codegen
    return {
        "compiler": codegen.find_tool("arm-none-eabi-g++"),
        "sdk": (codegen.SDK / "axoloti.elf").exists()
               and (codegen.SDK / "ramlink.ld").exists(),
        "sg_validate": codegen.SG_VALIDATE.exists(),
    }


SHM_ADDR = 0x2001C000
SHM_MAGIC = 0x53475831  # "SGX1": an sgaxo patch is running and keeps its block
SHM_WORDS = 16          # magic..status (6), midi_count, midi_cc_count, ring[8]


def describe_midi(packed):
    """One packed message as a sentence: what the MPK's pad or knob actually sent."""
    b0, b1, b2 = (packed >> 16) & 0xFF, (packed >> 8) & 0xFF, packed & 0xFF
    kind, channel = b0 & 0xF0, (b0 & 0x0F) + 1
    if kind == 0x90 and b2 > 0:
        return f"note on {b1} vel {b2} ch {channel}"
    if kind == 0x80 or kind == 0x90:
        return f"note off {b1} ch {channel}"
    if kind == 0xB0:
        return f"CC {b1} = {b2} ch {channel}"
    if kind == 0xC0:
        return f"program {b1} ch {channel}"
    if kind == 0xE0:
        return f"bend {((b2 << 7) | b1) - 8192} ch {channel}"
    if kind == 0xA0:
        return f"aftertouch {b1} = {b2} ch {channel}"
    if kind == 0xD0:
        return f"pressure {b1} ch {channel}"
    return f"status {b0:#04x} {b1} {b2}"


def read_board_midi(board):
    """The running patch's MIDI tally, or None when what is running is not
    one of ours (or was built before the tally existed)."""
    import struct
    words = struct.unpack("<16I", board.read_mem(SHM_ADDR, SHM_WORDS * 4))
    if words[0] != SHM_MAGIC:
        return None
    count, cc_count, ring = words[6], words[7], words[8:16]
    recent = []
    for k in range(min(count, 8)):
        recent.append(describe_midi(ring[(count - 1 - k) & 7]))
    return {"count": count, "cc_count": cc_count, "recent": recent}


def scan(status):
    import codegen
    report = {"found": False, "toolchain": toolchain_report()}
    status.step("looking for an Axoloti on USB")
    try:
        from axoproto import Axoloti, BoardNotFound
    except ImportError as error:
        report["error"] = (f"driver import failed: {error} — pip install -r "
                           "embedded/axoloti/requirements.txt into the venv")
        status.finish(True, **report)
        return
    try:
        board = Axoloti()
        try:
            fw = board.fw_info()
            try:
                board.sd_info("/")  # provokes a mount attempt
            except Exception:
                pass
            ack = board.ping()
            fwid = f"0x{fw.fwid:08x}"
            try:
                report["midi"] = read_board_midi(board)
            except Exception as error:  # noqa: BLE001 — a tally is optional
                report["midi_error"] = f"{type(error).__name__}: {error}"
            report.update(
                found=True,
                firmware=".".join(str(part) for part in fw.version),
                fwid=fwid,
                fwid_ok=fwid == codegen.FWID,
                dsp_load=ack.dsp_load,
                patch_id=ack.patch_id,
                patch_index=ack.patch_index,
                sd_ready=ack.fs_ready == 1,
                voltage_50=ack.voltage_50,
                voltage_10=ack.voltage_10)
        finally:
            board.close()
    except BoardNotFound as error:
        report["error"] = str(error)
    except Exception as error:  # noqa: BLE001 — the report is the point
        report["error"] = f"{type(error).__name__}: {error}"
    status.finish(True, **report)


def load_bank(path, sanitize):
    data = json.loads(path.read_text(encoding="utf-8"))
    if int(data.get("schema_version", 0)) != 1:
        raise SystemExit(f"{path.name}: schema_version must be 1")
    entries = data.get("entries", [])
    if not entries:
        raise SystemExit(f"{path.name}: the bank has no entries")
    patches, names = [], []
    for entry in entries:
        patch = pathlib.Path(str(entry.get("patch", "")))
        if not patch.is_absolute():
            patch = (path.parent / patch).resolve()
        if not patch.exists():
            raise SystemExit(f"entry {entry.get('name')!r}: {patch} does not exist")
        patches.append(patch)
        names.append(sanitize(str(entry.get("name") or patch.stem)))
    if len(set(names)) != len(names):
        raise SystemExit(f"duplicate bank names: {names}")
    return data, patches, names


def flash(status, bank_path, dry_run):
    bake_bank = load_bake_bank()
    tools = toolchain_report()
    missing = []
    if not tools["sg_validate"]:
        missing.append("sg-validate is not built (cmake --build build --target sg-validate)")
    if not tools["sdk"]:
        missing.append("the Axoloti SDK is not fetched (embedded/axoloti/tools/fetch-sdk.sh)")
    if not tools["compiler"]:
        missing.append("arm-none-eabi-g++ is not installed or not on the path")
    if missing:
        status.finish(False, error="; ".join(missing), toolchain=tools)
        return
    status.step(f"reading {bank_path.name}")
    data, patches, names = load_bank(bank_path, bake_bank.sanitize)
    out_dir = RIG / "build" / "bank" / bake_bank.sanitize(bank_path.stem)
    status.step(f"baking {len(patches)} entries into {out_dir}")
    real_stdout = sys.stdout
    sys.stdout = Tee(status, real_stdout)
    try:
        bake_bank.bake(out_dir, [str(p) for p in patches], names, not dry_run,
                       nav=str(data.get("program_change", "midi")) == "prev-next")
    finally:
        sys.stdout = real_stdout
    total = 0
    for root, _dirs, files in os.walk(out_dir):
        for name in files:
            total += (pathlib.Path(root) / name).stat().st_size
    status.finish(True, entries=len(patches), names=names, bytes=total,
                  out_dir=str(out_dir), written=not dry_run,
                  bank=str(data.get("name", bank_path.stem)))


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("scan")
    flasher = commands.add_parser("flash")
    flasher.add_argument("bank")
    flasher.add_argument("--dry-run", action="store_true")
    watcher = commands.add_parser("midi", help="print what the running patch hears, live")
    watcher.add_argument("--seconds", type=float, default=10.0)
    args = parser.parse_args()

    if args.command == "midi":
        from axoproto import Axoloti
        board = Axoloti()
        try:
            seen = None
            deadline = time.time() + args.seconds
            print(f"watching the board's MIDI for {args.seconds:g} s; turn a knob, hit a pad")
            while time.time() < deadline:
                tally = read_board_midi(board)
                if tally is None:
                    print("the running patch is not one of ours, or was built before "
                          "the tally; flash again and retry")
                    return
                if seen is None:
                    seen = tally["count"]
                    print(f"  {tally['count']} messages so far, {tally['cc_count']} of them CC")
                fresh = tally["count"] - seen
                if fresh > 0:
                    for line in reversed(tally["recent"][:min(fresh, 8)]):
                        print(f"  {line}")
                    seen = tally["count"]
                time.sleep(0.1)
        finally:
            board.close()
        return

    status = Status(args.command)
    try:
        if args.command == "scan":
            scan(status)
        else:
            flash(status, pathlib.Path(args.bank).resolve(), args.dry_run)
    except SystemExit as stop:
        # The baker and the loader refuse with SystemExit and a sentence.
        status.finish(False, error=str(stop))
        raise
    except FileNotFoundError as error:
        status.finish(False, error=f"not found: {error.filename or error}")
        raise
    except Exception as error:  # noqa: BLE001 — everything ends in the file
        status.finish(False, error=f"{type(error).__name__}: {error}",
                      trace=traceback.format_exc()[-2000:])
        raise
    print(json.dumps(status.data, indent=1))
    if status.data["state"] != "done":
        sys.exit(1)


if __name__ == "__main__":
    main()
