"""Oral-B SmartSeries BLE protocol: constants and pure decoders.

Nothing in this module talks to Bluetooth, so it can be tested anywhere.

Sources (community reverse engineering, not official Oral-B documentation):
  - oralb-ble 1.1.3 (MIT), the library behind Home Assistant's Oral-B integration
    https://github.com/Bluetooth-Devices/oralb-ble
  - OralBlue_python Protocol.md
    https://github.com/wise86-android/OralBlue_python/blob/15e1a03bcb3350574d438e4593bcff59608a77a7/Protocol.md
Treat every table here as "observed on some handles", and confirm it on yours.
"""

from __future__ import annotations

import datetime as dt
import struct
from dataclasses import dataclass

# Bluetooth SIG company ID 0x00DC (Procter & Gamble).
ORALB_MANUFACTURER_ID = 0x00DC

# Custom 128-bit base UUID. The tail spells "PGMS" ... "Oral-B" in ASCII.
_BASE = "a0f0{:04x}-5047-4d53-8208-4f72616c2d42"


def char_uuid(short: int) -> str:
    return _BASE.format(short)


CHAR_TOOTHBRUSH_ID = char_uuid(0xFF01)
CHAR_MODEL = char_uuid(0xFF02)
CHAR_USER_ID = char_uuid(0xFF03)
CHAR_STATUS = char_uuid(0xFF04)
CHAR_BATTERY = char_uuid(0xFF05)
CHAR_BUTTONS = char_uuid(0xFF06)
CHAR_MODE = char_uuid(0xFF07)
CHAR_BRUSHING_TIME = char_uuid(0xFF08)
CHAR_SECTOR = char_uuid(0xFF09)
CHAR_PRESSURE = char_uuid(0xFF0B)
CHAR_CONTROL = char_uuid(0xFF21)
CHAR_CURRENT_TIME = char_uuid(0xFF22)
CHAR_SIGNALS = char_uuid(0xFF24)
CHAR_AVAILABLE_MODES = char_uuid(0xFF25)
CHAR_SECTOR_TIMER = char_uuid(0xFF26)
CHAR_SESSION_INFO = char_uuid(0xFF29)

KNOWN_CHARS = {
    CHAR_TOOTHBRUSH_ID: "toothbrush id",
    CHAR_MODEL: "model / protocol / firmware",
    CHAR_USER_ID: "user id",
    CHAR_STATUS: "status",
    CHAR_BATTERY: "battery",
    CHAR_BUTTONS: "buttons",
    CHAR_MODE: "current mode",
    CHAR_BRUSHING_TIME: "brushing time",
    CHAR_SECTOR: "sector",
    CHAR_PRESSURE: "pressure",
    CHAR_CONTROL: "control (command register)",
    CHAR_CURRENT_TIME: "clock",
    CHAR_SIGNALS: "signals",
    CHAR_AVAILABLE_MODES: "available modes",
    CHAR_SECTOR_TIMER: "sector timer",
    CHAR_SESSION_INFO: "session info",
}

# Control-register commands, written to CHAR_CONTROL before the matching action.
CMD_UNLOCK_AVAILABLE_MODES = bytes([0x37, 0x29])
CMD_SELECT_SESSION = 0x02  # followed by one index byte

MODES = {
    0: "off",
    1: "daily clean",
    2: "sensitive",
    3: "massage",
    4: "whitening",
    5: "deep clean",
    6: "tongue cleaning",
    7: "turbo",
    255: "unknown / empty slot",
}

STATES = {
    0: "unknown",
    1: "initializing",
    2: "idle",
    3: "running",
    4: "charging",
    5: "setup",
    6: "flight menu",
    8: "selection menu",
    9: "off",
    10: "post brushing statistics",
    113: "final test",
    114: "pcb test",
    115: "sleeping",
    116: "transport",
}

# Factory/diagnostic states. Tools here refuse to write while the brush reports one.
FACTORY_STATES = {113, 114, 116}

# Advertisement byte 1. The "N_MODE" suffix is the number of modes the
# hardware variant shipped with; "X_MODE" variants are configurable.
MODEL_TYPES = {
    0: "D36 Triumph/Professional Care (X mode)",
    1: "D36 Triumph/Professional Care (6 mode)",
    2: "D36 Triumph/Professional Care (5 mode)",
    32: "D701 Genius (X mode)",
    33: "D701 Genius (6 mode)",
    34: "D701 Genius (5 mode)",
    39: "D700 Smart/Pro Series (5 mode)",
    40: "D700 Smart/Pro Series (4 mode)",
    41: "D700 Smart/Pro Series (6 mode)",
    48: "iO (X mode)",
    49: "iO",
    50: "iO (big Ti)",
    52: "iO Series 4",
    53: "iO Series 5",
    54: "iO (ePlatform)",
    63: "D36 (experimental)",
    64: "D21 Smart Series (X mode)",
    65: "D21 Smart Series (4 mode)",
    66: "D21 Smart Series (3a mode)",
    67: "D21 Smart Series (2a mode)",
    68: "D21 Smart Series (2b mode)",
    69: "D21 Smart Series (3 mode, whitening)",
    70: "D21 Smart Series (1 mode)",
    80: "D601 Pro (X mode)",
    81: "D601 Pro (5 mode)",
    82: "D601 Pro (4 mode)",
    83: "D601 Pro (3a mode)",
    84: "D601 Pro (2a mode)",
    85: "D601 Pro (2b mode)",
    86: "D601 Pro (3b mode)",
    87: "D601 Pro (1 mode)",
    112: "D706 Genius X (X mode)",
    113: "D706 Genius X (6 mode)",
    114: "D706 Genius X (5 mode)",
}

EPOCH_2000 = dt.datetime(2000, 1, 1, tzinfo=dt.timezone.utc)


def mode_name(mode: int) -> str:
    return MODES.get(mode, f"unknown mode {mode}")


def state_name(state: int) -> str:
    return STATES.get(state, f"unknown state {state}")


def decode_pressure_flags(value: int) -> str:
    """Advertisement byte 4 is a bit field; button presses win over pressure."""
    if value & 0x08:
        return "power button pressed"
    if value & 0x04:
        return "button pressed"
    if value & 0x80:
        return "high"
    return "normal"


def decode_sector(sector: int, sector_count: int | None) -> str:
    quadrant = sector & 0x07
    if quadrant == 0:
        return "no sector"
    if quadrant == 7:
        return f"sector {(sector_count or 0) & 0x07 or 4}"
    return f"sector {quadrant}"


@dataclass
class Advertisement:
    raw: bytes
    protocol_version: int
    model_type: int
    firmware: int
    state: int
    pressure_flags: int
    brush_seconds: int
    mode: int
    sector: int
    sector_timer: int | None
    sector_count: int | None

    @property
    def model_name(self) -> str:
        return MODEL_TYPES.get(self.model_type, f"unknown model type {self.model_type}")

    def summary(self) -> dict:
        return {
            "model": self.model_name,
            "model_type": self.model_type,
            "protocol": self.protocol_version,
            "firmware": self.firmware,
            "state": state_name(self.state),
            "pressure": decode_pressure_flags(self.pressure_flags),
            "time": f"{self.brush_seconds // 60}:{self.brush_seconds % 60:02d}",
            "mode": mode_name(self.mode),
            "sector": decode_sector(self.sector, self.sector_count),
            "raw": self.raw.hex(" "),
        }


def parse_advertisement(data: bytes) -> Advertisement | None:
    """Parse manufacturer data for company 0x00DC (the company ID already stripped,
    which is how bleak and Home Assistant hand it over)."""
    if len(data) not in (9, 11):
        return None
    return Advertisement(
        raw=bytes(data),
        protocol_version=data[0],
        model_type=data[1],
        firmware=data[2],
        state=data[3],
        pressure_flags=data[4],
        brush_seconds=data[5] * 60 + data[6],
        mode=data[7],
        sector=data[8],
        sector_timer=data[9] if len(data) == 11 else None,
        sector_count=data[10] if len(data) == 11 else None,
    )


def decode_model_char(data: bytes) -> dict:
    out = {"model_type": data[0], "model": MODEL_TYPES.get(data[0], "unknown")}
    if len(data) >= 3:
        out.update(protocol=data[1], firmware=data[2])
    return out


def decode_battery(data: bytes) -> dict:
    out = {"percent": data[0]}
    if len(data) >= 3:
        out["seconds_left"] = int.from_bytes(data[1:3], "little")
    return out


def decode_time(data: bytes) -> str:
    seconds = int.from_bytes(data[:4], "little")
    return (EPOCH_2000 + dt.timedelta(seconds=seconds)).isoformat()


def decode_available_modes(data: bytes) -> list[str]:
    return [mode_name(b) for b in data]


def empty_slot_byte(current: bytes) -> int | None:
    """The filler byte the handle itself uses for unused slots, if it uses one."""
    fillers = {b for b in current if b not in MODES or b in (0, 255)}
    return fillers.pop() if len(fillers) == 1 else None


def encode_available_modes(mode_ids: list[int], current: bytes) -> bytes:
    """Build a new available-modes value shaped like the one read from the handle.

    Rejects anything outside the documented mode table so a typo can't put an
    arbitrary byte into the handle's configuration, and refuses to guess the
    filler for unused slots: it must already appear in the handle's value.
    """
    if not mode_ids:
        raise ValueError("at least one mode is required")
    if len(mode_ids) > len(current):
        raise ValueError(f"at most {len(current)} modes fit")
    if len(set(mode_ids)) != len(mode_ids):
        raise ValueError("duplicate modes")
    for m in mode_ids:
        if m not in MODES or m in (0, 255):
            raise ValueError(f"mode {m} is not a documented brushing mode")
    pad = len(current) - len(mode_ids)
    if pad:
        filler = empty_slot_byte(current)
        if filler is None:
            raise ValueError("can't tell which byte marks an empty slot on this handle; list exactly "
                             f"{len(current)} modes or report the raw value")
        return bytes(mode_ids) + bytes([filler]) * pad
    return bytes(mode_ids)


def decode_session(data: bytes, protocol: int) -> dict:
    """Decode one stored session record from CHAR_SESSION_INFO."""
    start, duration, events, mode, pressure_time, warnings, battery = struct.unpack_from(
        "<IHBBHBB", data
    )
    out = {
        "start": (EPOCH_2000 + dt.timedelta(seconds=start)).isoformat(),
        "duration_s": duration,
        "events": events,
        "mode": mode_name(mode),
        "pressure_time_s": pressure_time / 10 if protocol >= 4 else pressure_time,
        "pressure_warnings": warnings,
        "battery_end_pct": battery,
    }
    if len(data) >= 16 and protocol >= 2:
        a, b = struct.unpack_from("<HH", data, 12)
        out.update(sectors=a & 0x07, target_time_s=a >> 3, user_id=b & 0x07, session_id=b >> 3)
    return out
