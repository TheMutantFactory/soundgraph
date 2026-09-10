# embedded

The hardware escape. One generic firmware, many boards-as-manifests.

```text
components/soundgraph-core/   dsp-core + patch-io as an ESP-IDF component — the same
                              sources every other target compiles, no fork
esp32-s3/                     the generic S3 firmware (I2S out, serial console, NVS)
boards/<vendor>/<board>/      board.json manifests; see schema/board.schema.json
```

The firmware contains no DSP of its own and no per-board code: pins and codec details
come from a header generated out of `board.json` at build time
(`tools/board-generator/generate.py`).

## Wiring (generic DevKitC + PCM5102)

| PCM5102 module | goes to |
|----------------|---------|
| VIN            | 3V3     |
| GND            | GND     |
| BCK            | GPIO15  |
| LCK            | GPIO16  |
| DIN            | GPIO17  |
| SCK            | GND (enables the DAC's internal PLL — no master clock needed) |

Check the module's solder jumpers: FLT→GND, DEMP→GND, XSMT→3V3, FMT→GND. Most modules
ship that way.

## Build and flash

```bash
C:\Users\danie\esp-idf\export.bat
cd embedded/esp32-s3
idf.py set-target esp32s3
idf.py build flash monitor
```

A different board: `idf.py -DSG_BOARD=<id> build`, where `<id>` is a directory under
`embedded/boards/*/`. The board profile names the chip, so `set-target` is not needed
and not honoured; a board on another chip wants its own build directory:

```bash
idf.py -DSG_BOARD=esp32-p4-wifi6-touch-lcd-7b -B build-p4 build     # the 7-inch P4
```

That board's USB-to-UART bridge has no macOS driver (see docs/known-issues.md), so from a
Mac it is flashed and talked to through `tools/esp32/ch340.py` rather than a port name:

```bash
tools/esp32/ch340.py idf-flash embedded/esp32-s3/build-p4    # what idf.py flash would do
tools/esp32/ch340.py monitor                                 # boot log after a reset
tools/esp32/ch340.py cmd "screen test"                       # one console command
tools/esp32/sg-serial.py --port ch340 verify-goldens
```

Run those with the IDF virtualenv's python (it has esptool and pyusb; `pip install pyusb`
once if it does not).

The defaults assume a DevKitC-1 **N8R8** (octal PSRAM). A quad-PSRAM variant needs
`CONFIG_SPIRAM_MODE_QUAD` instead; the symptom of the wrong setting is a bootloop that
mentions PSRAM. Boards without PSRAM still run every patch that has no Delay node —
delay lines are the allocations that need it.

## On the wire

The board plays `first-synth` through its arpeggiator the moment it has power — a fresh
flash makes sound with no host attached. The serial monitor (115200) is a console:

```text
info                         what is loaded, execution order, memory
note 45 / off 45 / panic     play from the keyboard you already have
arp on|off                   the built-in arpeggiator
arp 45,52,57,60              set the arpeggio pattern and start it
bpm 140                      arpeggio tempo
vol 40                       codec output volume (codec boards only)
set filter cutoff 3000       move a knob
load <bytes>                 deploy a patch (stored in NVS, survives power cycles)
unload                       back to the embedded demo
```

Or from the host side. The repo keeps its own venv for this (gitignored):

```bash
python -m venv .venv
.venv/Scripts/python -m pip install pyserial esptool
```

```bash
.venv/Scripts/python tools/esp32/sg-serial.py --port COM3 deploy examples/patches/first-synth.json
.venv/Scripts/python tools/esp32/sg-serial.py --port COM3 note 45
```

The venv's esptool can also flash a built firmware without the IDF environment:

```bash
cd embedded/esp32-s3/build
../../../.venv/Scripts/python -m esptool --chip esp32s3 -p COM3 -b 460800 --before default_reset --after hard_reset write_flash @flash_args
```

## Verification

The exit condition for this target is the same as it was for the browser: the golden
cases, rendered on device, must match the native vectors — this time within 1e-4 (the
S3's libm differs more than a desktop's; see docs/test-matrix.md).

```bash
python tools/esp32/sg-serial.py --port COM5 verify-goldens
```

The device renders each case offline (live audio is untouched) and streams the samples
back over serial. Same patches, same events, same vectors as `ctest` and
`verify-goldens.mjs`; only the silicon differs.
