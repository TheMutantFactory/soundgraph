#!/usr/bin/env python3
"""A serial port for a CH340 that macOS refuses to give you one for.

The 7-inch board's USB-to-UART bridge is a WCH CH340 that enumerates as 1a86:7522. Apple's
own CH34x driver (com.apple.DriverKit-AppleUSBCHCOM) matches 7523 and 55d4 and nothing
else, so the device sits on the bus fully enumerated with no /dev/cu.* node — and the
only vendor fix is a DriverKit extension that needs a password and a trip through System
Settings. This talks to the chip from user space over libusb instead. A device with no
kernel driver attached can be claimed by any process, no privileges required.

The protocol is the CH341's, as documented by nobody and implemented by Linux's ch341.c,
which is where every constant below comes from. It is small: four vendor control
requests, two registers for the baud rate, one for line control, one for the modem
lines, and raw bytes on the bulk endpoints.

Duck-typed to the parts of pyserial's Serial that esptool and sg-serial actually touch,
so both can be handed one of these instead of a port name:

    from ch340 import CH340Serial
    port = CH340Serial(115200)
    esptool.main(["--before", "no_reset", "--after", "no_reset", "write_flash", ...],
                 esp=ESP32S3ROM(port))

esptool's default reset on a Unix host goes through fcntl.ioctl on the port's file
descriptor, which this has none of, so the reset is done here (`bootloader()`,
`hard_reset()`) and esptool is told not to. Both are the same DTR/RTS dance the
auto-programming transistors on every dev board expect.

    ./ch340.py monitor                  # boot log, after a hard reset
    ./ch340.py cmd "screen test"        # one console command, print the reply
    ./ch340.py flash <esptool write_flash args...>
"""
import sys
import threading
import time

import usb.core
import usb.util

VID = 0x1A86
PIDS = (0x7522, 0x7523, 0x5523)

REQ_READ_VERSION = 0x5F
REQ_WRITE_REG = 0x9A
REQ_READ_REG = 0x95
REQ_SERIAL_INIT = 0xA1
REQ_MODEM_CTRL = 0xA4

REG_BREAK = 0x05
REG_PRESCALER = 0x12
REG_DIVISOR = 0x13
REG_LCR = 0x18
REG_LCR2 = 0x25

LCR_ENABLE_RX = 0x80
LCR_ENABLE_TX = 0x40
LCR_CS8 = 0x03

BIT_DTR = 0x20
BIT_RTS = 0x40

CLKRATE = 48_000_000
MIN_BPS = 46
MAX_BPS = 3_000_000

OUT = usb.util.CTRL_TYPE_VENDOR | usb.util.CTRL_RECIPIENT_DEVICE | usb.util.CTRL_OUT
IN = usb.util.CTRL_TYPE_VENDOR | usb.util.CTRL_RECIPIENT_DEVICE | usb.util.CTRL_IN


def _clk_div(ps, fact):
    return 1 << (12 - 3 * ps - fact)


def _divisor(speed):
    """The prescaler/divisor word for a baud rate, as ch341_get_divisor works it out.

    The chip runs a 48 MHz clock through one of four prescalers and a further halving,
    then an 8-bit divisor. The search prefers the highest base clock that keeps the
    divisor in range, rounds to whichever neighbour is nearer the asked-for rate, then
    drops to the lower base clock when the divisor is even — the receiver tolerates
    error better there, and it changes nothing about the rate.
    """
    speed = max(MIN_BPS, min(MAX_BPS, speed))
    fact = 1
    ps = 3
    while ps >= 0:
        if speed > CLKRATE // (_clk_div(ps, 1) * 512):
            break
        ps -= 1
    if ps < 0:
        raise ValueError(f"baud {speed} out of range")
    clk_div = _clk_div(ps, fact)
    div = CLKRATE // (clk_div * speed)
    if div < 9 or div > 255:
        div //= 2
        clk_div *= 2
        fact = 0
    if div < 2:
        raise ValueError(f"baud {speed} out of range")
    if (16 * CLKRATE // (clk_div * div) - 16 * speed
            >= 16 * speed - 16 * CLKRATE // (clk_div * (div + 1))):
        div += 1
    if fact == 1 and div % 2 == 0:
        div //= 2
        fact = 0
    return ((0x100 - div) << 8) | (fact << 2) | ps


class CH340Serial:
    def __init__(self, baudrate=115200, timeout=1.0, write_timeout=1.0):
        self._dev = None
        for pid in PIDS:
            self._dev = usb.core.find(idVendor=VID, idProduct=pid)
            if self._dev is not None:
                break
        if self._dev is None:
            raise IOError("no CH340 on the bus (looked for 1a86:%s)"
                          % "/".join("%04x" % p for p in PIDS))
        # macOS has nothing attached to detach, but on a Linux bench the kernel's
        # ch341 driver would own the interface and has to let go first.
        try:
            if self._dev.is_kernel_driver_active(0):
                self._dev.detach_kernel_driver(0)
        except (NotImplementedError, usb.core.USBError):
            pass
        try:
            if self._dev.get_active_configuration() is None:
                self._dev.set_configuration()
        except usb.core.USBError:
            self._dev.set_configuration()
        usb.util.claim_interface(self._dev, 0)

        intf = self._dev.get_active_configuration()[(0, 0)]
        self._ep_in = self._ep_out = None
        for ep in intf:
            kind = usb.util.endpoint_type(ep.bmAttributes)
            direction = usb.util.endpoint_direction(ep.bEndpointAddress)
            if kind == usb.util.ENDPOINT_TYPE_BULK:
                if direction == usb.util.ENDPOINT_IN:
                    self._ep_in = ep
                else:
                    self._ep_out = ep
        if self._ep_in is None or self._ep_out is None:
            raise IOError("CH340 interface has no bulk endpoints; wrong interface?")

        self.name = "ch340:%04x" % self._dev.idProduct
        self.port = self.name
        self._timeout = timeout
        self._write_timeout = write_timeout
        self._baudrate = baudrate
        self._mcr = 0
        self._pending = bytearray()
        self._lock = threading.Lock()
        self._arrived = threading.Event()
        self._running = True
        self.is_open = True

        version = self._dev.ctrl_transfer(IN, REQ_READ_VERSION, 0, 0, 2, 1000)
        self._version = version[0] if len(version) else 0
        self._control_out(REQ_SERIAL_INIT, 0, 0)
        self._apply_line()
        self._apply_modem()
        self._thread = threading.Thread(target=self._reader, daemon=True)
        self._thread.start()

    # ---- the chip -------------------------------------------------------------------
    def _control_out(self, request, value, index):
        self._dev.ctrl_transfer(OUT, request, value, index, None, 1000)

    def _apply_line(self):
        val = _divisor(self._baudrate)
        # Bit 7 of the low byte: deliver bytes as they arrive rather than waiting for a
        # full 32-byte packet. Without it a one-line console reply sits in the chip
        # until 31 more bytes follow it, which for "OK" is never.
        if self._version > 0x27:
            val |= 0x80
        self._control_out(REQ_WRITE_REG, (REG_DIVISOR << 8) | REG_PRESCALER, val)
        if self._version >= 0x30:
            lcr = LCR_ENABLE_RX | LCR_ENABLE_TX | LCR_CS8
            self._control_out(REQ_WRITE_REG, (REG_LCR2 << 8) | REG_LCR, lcr)

    def _apply_modem(self):
        # The chip wants the lines inverted: a set bit drives the pin low, which for a
        # modem line is "asserted".
        self._control_out(REQ_MODEM_CTRL, (~self._mcr) & 0xFFFF, 0)

    # ---- pyserial's surface, the parts that get used ---------------------------------
    @property
    def baudrate(self):
        return self._baudrate

    @baudrate.setter
    def baudrate(self, value):
        self._baudrate = int(value)
        self._apply_line()

    @property
    def timeout(self):
        return self._timeout

    @timeout.setter
    def timeout(self, value):
        self._timeout = value

    @property
    def write_timeout(self):
        return self._write_timeout

    @write_timeout.setter
    def write_timeout(self, value):
        self._write_timeout = value

    @property
    def dtr(self):
        return bool(self._mcr & BIT_DTR)

    @dtr.setter
    def dtr(self, state):
        self.setDTR(state)

    @property
    def rts(self):
        return bool(self._mcr & BIT_RTS)

    @rts.setter
    def rts(self, state):
        self.setRTS(state)

    def setDTR(self, state):
        self._mcr = (self._mcr | BIT_DTR) if state else (self._mcr & ~BIT_DTR)
        self._apply_modem()

    def setRTS(self, state):
        self._mcr = (self._mcr | BIT_RTS) if state else (self._mcr & ~BIT_RTS)
        self._apply_modem()

    def set_dtr_rts(self, dtr, rts):
        """Both lines in one transfer, which the chip allows and pyserial does not.

        The reset circuit decodes DTR and RTS together, so two separate writes pass
        through a state neither side asked for. One transfer means one state.
        """
        self._mcr = (BIT_DTR if dtr else 0) | (BIT_RTS if rts else 0)
        self._apply_modem()

    # Reads happen on their own thread, always.
    #
    # The chip holds very little: pull from its bulk endpoint on demand and a boot log at
    # 115200 arrives with every fifth character missing, because whenever nobody is
    # asking the chip drops what the UART gave it. A thread that never stops asking is
    # the whole fix — the first version read only when read() was called and produced
    # "ESP-ROM:esp32p4-eco2" followed by confetti.
    def _reader(self):
        while self._running:
            try:
                data = self._ep_in.read(4096, 100)
            except usb.core.USBTimeoutError:
                continue
            except usb.core.USBError as error:
                if error.errno in (110, 60):
                    continue
                if not self._running:
                    return
                raise
            if len(data):
                with self._lock:
                    self._pending.extend(data)
                    self._arrived.set()

    def _wait_for(self, count, deadline):
        """Block until `count` bytes are pending or the deadline passes."""
        while True:
            with self._lock:
                if len(self._pending) >= count:
                    return True
                self._arrived.clear()
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                return False
            self._arrived.wait(0.05 if remaining is None else min(remaining, 0.05))

    @property
    def in_waiting(self):
        with self._lock:
            return len(self._pending)

    def inWaiting(self):
        return self.in_waiting

    def read(self, size=1):
        deadline = None if self._timeout is None else time.monotonic() + self._timeout
        self._wait_for(size, deadline)
        with self._lock:
            out = bytes(self._pending[:size])
            del self._pending[:size]
        return out

    def read_all(self):
        with self._lock:
            out = bytes(self._pending)
            self._pending.clear()
        return out

    def write(self, data):
        data = bytes(data)
        # The OUT endpoint takes 32 bytes a packet; libusb splits larger writes, but a
        # bounded chunk keeps a stalled chip from swallowing a whole firmware block
        # before anyone notices.
        sent = 0
        while sent < len(data):
            chunk = data[sent:sent + 4096]
            sent += self._ep_out.write(chunk, int(self._write_timeout * 1000))
        return sent

    def flush(self):
        pass

    def reset_input_buffer(self):
        # Let the reader drain whatever the chip is holding first, or the first read
        # after a reset returns the tail of the previous boot.
        time.sleep(0.02)
        with self._lock:
            self._pending.clear()

    flushInput = reset_input_buffer

    def reset_output_buffer(self):
        pass

    flushOutput = reset_output_buffer

    def close(self):
        self._running = False
        if self._dev is not None:
            self._thread.join(0.5)
            try:
                usb.util.release_interface(self._dev, 0)
                usb.util.dispose_resources(self._dev)
            except usb.core.USBError:
                pass
            self._dev = None
        self.is_open = False

    def isOpen(self):
        return self.is_open

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    # ---- the ESP32's auto-reset circuit ----------------------------------------------
    # Two transistors turn DTR/RTS into EN/IO0 such that asserting both does nothing,
    # asserting one pulls its pin low. So: RTS alone holds the chip in reset, DTR alone
    # holds IO0 low, and the order below is esptool's ClassicReset written for a chip
    # that can set both lines at once.
    def hard_reset(self):
        self.set_dtr_rts(False, True)    # EN low: in reset
        time.sleep(0.1)
        self.set_dtr_rts(False, False)   # EN high: run

    def bootloader(self, delay=0.05):
        self.set_dtr_rts(False, True)    # EN low, IO0 high
        time.sleep(0.1)
        self.set_dtr_rts(True, False)    # EN high, IO0 low: boots into the ROM loader
        time.sleep(delay)
        self.set_dtr_rts(False, False)   # IO0 released


# ---- command line --------------------------------------------------------------------
def _monitor(port, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        data = port.read_all()
        if data:
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()
        else:
            time.sleep(0.02)


def main(argv):
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        print(__doc__)
        return 0
    verb = argv[1]
    if verb == "monitor":
        seconds = float(argv[2]) if len(argv) > 2 else 8.0
        with CH340Serial(115200, timeout=0.2) as port:
            print(f"# {port.name} chip version 0x{port._version:02x}; resetting", flush=True)
            port.reset_input_buffer()
            port.hard_reset()
            _monitor(port, seconds)
        return 0
    if verb == "listen":
        seconds = float(argv[2]) if len(argv) > 2 else 8.0
        with CH340Serial(115200, timeout=0.2) as port:
            _monitor(port, seconds)
        return 0
    if verb == "cmd":
        text = argv[2]
        seconds = float(argv[3]) if len(argv) > 3 else 2.0
        with CH340Serial(115200, timeout=0.2) as port:
            port.reset_input_buffer()
            port.write((text + "\n").encode())
            _monitor(port, seconds)
        return 0
    if verb in ("flash", "idf-flash"):
        import esptool
        extra = argv[2:]
        if verb == "idf-flash":
            # What `idf.py flash` would send, read from the file it reads. The offsets
            # differ per chip (the P4's bootloader sits at 0x2000, the S3's at 0x0) and
            # the model partition is a fourth file; none of that is worth retyping.
            import json
            from pathlib import Path
            build = Path(argv[2]).resolve()
            args = json.loads((build / "flasher_args.json").read_text())
            extra = ["-b", "921600", "write_flash"] + list(args["write_flash_args"])
            for offset, name in sorted(args["flash_files"].items(),
                                       key=lambda item: int(item[0], 16)):
                extra += [offset, str(build / name)]
        with CH340Serial(115200, timeout=1.0) as port:
            port.bootloader()
            esp = esptool.detect_chip(port, 115200, "no_reset")
            print(f"# {esp.CHIP_NAME}", flush=True)
            esptool.main(["--before", "no_reset", "--after", "no_reset"] + extra, esp=esp)
            port.hard_reset()
        return 0
    print(f"ch340: unknown verb {verb!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
