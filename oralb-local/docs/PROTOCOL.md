# Oral-B SmartSeries BLE protocol (community reverse engineering)

Sources: [oralb-ble](https://github.com/Bluetooth-Devices/oralb-ble) 1.1.3 (MIT, used by Home
Assistant), and [OralBlue_python Protocol.md](https://github.com/wise86-android/OralBlue_python/blob/15e1a03bcb3350574d438e4593bcff59608a77a7/Protocol.md).
None of this is official. **Verify on your handle**: fill in the "Your value" column from
nRF Connect, or from the LocalBrush inspector export.

The tables are implemented in `ios/Sources/OralBKit/OralBProtocol.swift` and
`python/oralb_protocol.py`, which are kept in sync.

## Advertisement

Manufacturer-specific data, company ID `0x00DC`. iOS includes the two ID bytes (`DC 00`) at the
front; bleak and Home Assistant strip them. After the ID, the payload is 9 or 11 bytes:

| Byte | Field | Notes | Your value |
|---|---|---|---|
| 0 | protocol version | 1–4 seen | |
| 1 | model type | table below | |
| 2 | firmware byte | | |
| 3 | state | 2 idle, 3 running, 4 charging, 115 sleeping; 113/114/116 factory states | |
| 4 | flags | bit 7 high pressure, bit 3 power button, bit 2 mode button | |
| 5, 6 | brushing time | minutes, seconds | |
| 7 | mode | 1 Daily Clean, 2 Sensitive, 3 Massage, 4 Whitening, 5 Deep Clean, 6 Tongue, 7 Turbo | |
| 8 | sector | low 3 bits; 7 = last sector | |
| 9 | sector timer | 11-byte form only | |
| 10 | sector count | 11-byte form only | |

### Model-type codes (byte 1)

0–2 D36 Triumph/Professional Care (X/6/5 mode) · 32–34 D701 Genius (X/6/5) ·
39/40/41 D700 Smart/Pro Series (5/4/6) · 48–54 iO family · 63 D36 experimental ·
64–70 D21 Smart Series (X, 4, 3a, 2a, 2b, 3-whitening, 1) ·
80–87 D601 Pro (X, 5, 4, 3a, 2a, 2b, 3b, 1) · 112–114 D706 Genius X (X/6/5).

## GATT characteristics

Base UUID: `A0F0xxxx-5047-4D53-8208-4F72616C2D42`

| Short | Name | Access | Format | Your value |
|---|---|---|---|---|
| FF01 | toothbrush ID | R | uint32 LE | |
| FF02 | model | R | [model type, protocol, firmware] (last two only if protocol ≥ 3) | |
| FF03 | user ID | R/W | 1 byte | |
| FF04 | status | R | [state, ?] | |
| FF05 | battery | R | [%, seconds left LE16, ?] | |
| FF06 | buttons | R/N | [power, mode], 1 = pressed | |
| FF07 | current mode | R/N | 1 byte (writability **not documented**) | |
| FF08 | brushing time | R/N | [min, sec] | |
| FF09 | sector | R/N | 1 byte | |
| FF0B | pressure | R | 0 low, 1 normal, 2 high (oralb-ble) | |
| FF21 | control | W | command register (below) | |
| FF22 | clock | R/W | uint32 LE seconds since 2000-01-01 | |
| FF24 | signals | R/W | vibration/light feedback bits (write reported as not working) | |
| FF25 | **available modes** | R/W | 8 bytes, one mode ID per slot, in button order | |
| FF26 | sector timer | R/W | 8 × uint16 LE | |
| FF29 | session info | R | one stored session (below) | |
| FF0A, FF0C, FF0D, FF23, FF2A–FF2D, FF81–FF85 | unknown | | **do not write** | |

### Control register commands (write to FF21)

| Bytes | Effect | Used by LocalBrush |
|---|---|---|
| `02 nn` | select stored session `nn` before reading FF29 | yes (read-only effect) |
| `37 26` | unlock clock write | no |
| `37 28` | unlock signals write | no |
| `37 29` | unlock available-modes write | yes, after backup + confirmation |
| `37 2A` | unlock sector-timer write | no |

### Session record (FF29)

`start u32 LE (s since 2000)` · `duration u16 LE` · `events u8` · `mode u8` ·
`pressure time u16 LE (1/10 s when protocol = 4)` · `pressure warnings u8` · `battery % u8` ·
then 4 bytes whose meaning depends on the protocol version. LocalBrush keeps the raw hex, because
the bit packing of those last 4 bytes is not confirmed.

Up to 20 stored sessions on protocol 1, and 30 on protocols 2–4.

## Open questions to answer with your handle

1. Does FF25 exist and accept reads? What is the empty-slot byte?
2. Does the model-type suffix match the modes the handle cycles through?
3. Does the Oral-B app write FF25 when you change mode settings? Check with PacketLogger (README Phase 3).
4. Does FF07 advertise the write property? If so, it is still not used until a capture shows the official app writing it.
