#!/usr/bin/env python3
"""Local, cloud-free tool for Oral-B SmartSeries toothbrushes.

  scan       passive: listen to advertisements (no connection, no writes)
  inspect    connect, list every GATT service/characteristic, read what is readable,
             save a JSON snapshot (your backup)
  watch      connect and print notifications live while you brush
  modes      show the handle's "available modes" list
  sessions   read stored brushing sessions
  set-modes  WRITE a new available-modes list (needs a backup and --i-understand)
  restore    WRITE the available-modes list back from a snapshot

Everything except set-modes/restore is read-only. `sessions` writes one
"select session N" command to the control register, which changes no settings.
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import datetime as dt
import json
import sys
from pathlib import Path

from bleak import BleakClient, BleakScanner

import oralb_protocol as p


def now() -> str:
    return dt.datetime.now().isoformat(timespec="seconds")


# --- scan --------------------------------------------------------------------

async def cmd_scan(args: argparse.Namespace) -> None:
    writer = None
    if args.csv:
        fh = open(args.csv, "a", newline="")
        writer = csv.writer(fh)
    last: dict[str, bytes] = {}

    def on_adv(device, adv) -> None:
        data = adv.manufacturer_data.get(p.ORALB_MANUFACTURER_ID)
        if data is None:
            return
        if not args.all and last.get(device.address) == data:
            return  # only print changes
        last[device.address] = data
        parsed = p.parse_advertisement(data)
        if parsed is None:
            print(f"{now()} {device.address} rssi={adv.rssi} unparsed raw={data.hex(' ')}")
            return
        s = parsed.summary()
        print(f"{now()} {device.address} rssi={adv.rssi} " + " | ".join(f"{k}={v}" for k, v in s.items()))
        if writer:
            writer.writerow([now(), device.address, adv.rssi, data.hex()])
            fh.flush()

    print("Listening for Oral-B advertisements (Ctrl+C to stop). Press a button on the brush to wake it.")
    async with BleakScanner(on_adv):
        await asyncio.sleep(args.seconds if args.seconds else 10**9)


# --- inspect -----------------------------------------------------------------

def decode_known(uuid: str, data: bytes):
    try:
        if uuid == p.CHAR_MODEL:
            return p.decode_model_char(data)
        if uuid == p.CHAR_BATTERY:
            return p.decode_battery(data)
        if uuid == p.CHAR_CURRENT_TIME:
            return p.decode_time(data)
        if uuid == p.CHAR_AVAILABLE_MODES:
            return p.decode_available_modes(data)
        if uuid == p.CHAR_MODE:
            return p.mode_name(data[0])
        if uuid == p.CHAR_STATUS:
            return p.state_name(data[0])
    except (IndexError, ValueError) as err:
        return f"decode failed: {err}"
    return None


async def snapshot(client: BleakClient) -> dict:
    snap = {"taken": now(), "address": client.address, "services": []}
    for service in client.services:
        svc = {"uuid": service.uuid, "description": service.description, "characteristics": []}
        for ch in service.characteristics:
            entry = {
                "uuid": ch.uuid,
                "handle": ch.handle,
                "properties": ch.properties,
                "known_as": p.KNOWN_CHARS.get(ch.uuid),
            }
            if "read" in ch.properties:
                try:
                    data = bytes(await client.read_gatt_char(ch))
                    entry["value_hex"] = data.hex()
                    entry["decoded"] = decode_known(ch.uuid, data)
                except Exception as err:  # some chars refuse reads; record and continue
                    entry["read_error"] = str(err)
            svc["characteristics"].append(entry)
        snap["services"].append(svc)
    return snap


def snapshot_value(snap: dict, uuid: str) -> bytes | None:
    for svc in snap["services"]:
        for ch in svc["characteristics"]:
            if ch["uuid"] == uuid and "value_hex" in ch:
                return bytes.fromhex(ch["value_hex"])
    return None


async def cmd_inspect(args: argparse.Namespace) -> None:
    async with BleakClient(args.address, timeout=20) as client:
        snap = await snapshot(client)
    for svc in snap["services"]:
        print(f"\n[service] {svc['uuid']}  {svc['description']}")
        for ch in svc["characteristics"]:
            line = f"  {ch['uuid']}  {','.join(ch['properties']):<40}"
            if ch["known_as"]:
                line += f" ({ch['known_as']})"
            if "value_hex" in ch:
                line += f"\n      = {ch['value_hex']}"
                if ch["decoded"] is not None:
                    line += f"  -> {ch['decoded']}"
            if "read_error" in ch:
                line += f"\n      ! {ch['read_error']}"
            print(line)
    out = Path(args.out or f"snapshot-{args.address.replace(':', '')}-{dt.datetime.now():%Y%m%d-%H%M%S}.json")
    out.write_text(json.dumps(snap, indent=2))
    print(f"\nSnapshot saved to {out}  (keep it: it is your backup)")


# --- watch -------------------------------------------------------------------

async def cmd_watch(args: argparse.Namespace) -> None:
    async with BleakClient(args.address, timeout=20) as client:
        def handler(ch, data: bytearray) -> None:
            name = p.KNOWN_CHARS.get(ch.uuid, ch.uuid)
            decoded = decode_known(ch.uuid, bytes(data))
            print(f"{now()} {name}: {bytes(data).hex(' ')}" + (f" -> {decoded}" if decoded is not None else ""))

        count = 0
        for service in client.services:
            for ch in service.characteristics:
                if "notify" in ch.properties or "indicate" in ch.properties:
                    try:
                        await client.start_notify(ch, handler)
                        count += 1
                    except Exception as err:
                        print(f"could not subscribe to {ch.uuid}: {err}")
        print(f"Subscribed to {count} characteristics. Brush, press buttons; Ctrl+C to stop.")
        await asyncio.sleep(args.seconds if args.seconds else 10**9)


# --- modes / sessions --------------------------------------------------------

async def read_header(client: BleakClient) -> tuple[dict, int]:
    model = p.decode_model_char(bytes(await client.read_gatt_char(p.CHAR_MODEL)))
    state = (await client.read_gatt_char(p.CHAR_STATUS))[0]
    return model, state


async def cmd_modes(args: argparse.Namespace) -> None:
    async with BleakClient(args.address, timeout=20) as client:
        model, state = await read_header(client)
        data = bytes(await client.read_gatt_char(p.CHAR_AVAILABLE_MODES))
    print(f"model: {model}\nstate: {p.state_name(state)}")
    print(f"available modes raw: {data.hex(' ')}")
    for slot, b in enumerate(data):
        print(f"  slot {slot}: {b:3d}  {p.mode_name(b)}")


async def cmd_sessions(args: argparse.Namespace) -> None:
    async with BleakClient(args.address, timeout=20) as client:
        model, _ = await read_header(client)
        protocol = model.get("protocol", 1)
        for i in range(args.count):
            await client.write_gatt_char(p.CHAR_CONTROL, bytes([p.CMD_SELECT_SESSION, i]), response=True)
            data = bytes(await client.read_gatt_char(p.CHAR_SESSION_INFO))
            try:
                decoded = p.decode_session(data, protocol)
            except Exception as err:
                decoded = f"decode failed: {err}"
            print(f"#{i:02d} {data.hex()}  {decoded}")


# --- writes ------------------------------------------------------------------

async def write_available_modes(address: str, backup: dict, mode_ids: list[int] | None = None) -> None:
    """Write mode_ids, or the backed-up value when mode_ids is None."""
    async with BleakClient(address, timeout=20) as client:
        model, state = await read_header(client)
        if state in p.FACTORY_STATES:
            sys.exit(f"Refusing: brush reports factory state '{p.state_name(state)}'.")
        if state == 3:
            sys.exit("Refusing: brush is running. Stop it and try again.")
        if model["model_type"] != backup_model_type(backup):
            sys.exit("Refusing: the backup was taken from a different model type.")
        current = bytes(await client.read_gatt_char(p.CHAR_AVAILABLE_MODES))
        if mode_ids is None:
            payload = snapshot_value(backup, p.CHAR_AVAILABLE_MODES)
        else:
            try:
                payload = p.encode_available_modes(mode_ids, current)
            except ValueError as err:
                sys.exit(f"Refusing: {err}")
        if len(payload) != len(current):
            sys.exit(f"Refusing: handle uses {len(current)} slots, payload has {len(payload)}.")
        print(f"current : {current.hex(' ')}  {p.decode_available_modes(current)}")
        print(f"new     : {payload.hex(' ')}  {p.decode_available_modes(payload)}")
        await client.write_gatt_char(p.CHAR_CONTROL, p.CMD_UNLOCK_AVAILABLE_MODES, response=True)
        await client.write_gatt_char(p.CHAR_AVAILABLE_MODES, payload, response=True)
        after = bytes(await client.read_gatt_char(p.CHAR_AVAILABLE_MODES))
        print(f"readback: {after.hex(' ')}  {p.decode_available_modes(after)}")
        if after != payload:
            print("Readback differs: the handle rejected or adjusted the value. Nothing else was changed.")
        else:
            print("Done. Press the mode button on the handle to confirm.")


def backup_model_type(snap: dict) -> int | None:
    data = snapshot_value(snap, p.CHAR_MODEL)
    return data[0] if data else None


def load_backup(path: str, address: str) -> dict:
    snap = json.loads(Path(path).read_text())
    if snap.get("address", "").upper() != address.upper():
        sys.exit("Refusing: backup was taken from a different address.")
    if snapshot_value(snap, p.CHAR_AVAILABLE_MODES) is None:
        sys.exit("Refusing: backup does not contain the available-modes value.")
    return snap


async def cmd_set_modes(args: argparse.Namespace) -> None:
    if not args.i_understand:
        sys.exit("This writes to the handle. Re-run with --i-understand once you have a backup.")
    backup = load_backup(args.backup, args.address)
    await write_available_modes(args.address, backup, [int(m) for m in args.modes.split(",")])


async def cmd_restore(args: argparse.Namespace) -> None:
    if not args.i_understand:
        sys.exit("This writes to the handle. Re-run with --i-understand.")
    backup = load_backup(args.backup, args.address)
    await write_available_modes(args.address, backup)


# --- main --------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan")
    s.add_argument("--seconds", type=float)
    s.add_argument("--all", action="store_true", help="print every advertisement, not just changes")
    s.add_argument("--csv", help="append raw advertisements to this CSV file")
    s.set_defaults(func=cmd_scan)

    for name, func in (("inspect", cmd_inspect), ("watch", cmd_watch), ("modes", cmd_modes), ("sessions", cmd_sessions)):
        s = sub.add_parser(name)
        s.add_argument("address", help="MAC address (Linux/Windows) or UUID (macOS) from `scan`")
        s.set_defaults(func=func)
        if name == "inspect":
            s.add_argument("--out", help="snapshot file name")
        if name == "watch":
            s.add_argument("--seconds", type=float)
        if name == "sessions":
            s.add_argument("--count", type=int, default=30)

    s = sub.add_parser("set-modes")
    s.add_argument("address")
    s.add_argument("modes", help="comma-separated mode ids in button order, e.g. 1,2,4,5")
    s.add_argument("--backup", required=True, help="snapshot JSON from `inspect`")
    s.add_argument("--i-understand", action="store_true")
    s.set_defaults(func=cmd_set_modes)

    s = sub.add_parser("restore")
    s.add_argument("address")
    s.add_argument("--backup", required=True)
    s.add_argument("--i-understand", action="store_true")
    s.set_defaults(func=cmd_restore)

    args = ap.parse_args()
    try:
        asyncio.run(args.func(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
