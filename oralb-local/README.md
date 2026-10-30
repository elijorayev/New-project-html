# LocalBrush: local, cloud-free control for an Oral-B SmartSeries (Type 3767)

An iPhone-first guide and toolkit to identify the toothbrush, inspect its Bluetooth LE
protocol without changing anything, find out why brushing modes disappeared, and control
it from your own app with no Oral-B account and no internet.

| Folder | What it is |
|---|---|
| [`docs/HARDWARE.md`](docs/HARDWARE.md) | Identification report, missing-modes analysis, risks and recovery |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | BLE protocol reference with a source for every entry |
| [`ios/`](ios/) | `OralBKit` Swift package (protocol + tests) and the `LocalBrush` SwiftUI app |
| [`python/`](python/) | The same protocol as a Python/bleak CLI for a Mac, Linux or Raspberry Pi |

## Evidence labels

Each step and claim below carries one of these labels:

- **[Tested]**: confirmed by tests in this repo (decoders only; nothing has run against your brush yet)
- **[Documented]**: from public sources: open-source projects, manuals, iFixit
- **[Experimental, reversible]**: works per community notes, unverified on Type 3767, can be undone
- **[Not recommended]**: high risk; this project doesn't do it

---

## Phase 0: no tools at all (2 minutes)

1. **Read the handle.** The bottom of the handle says "Type 3767". A box that says "Type 3757"
   is the charger, not the brush. **[Documented]**
2. **Count the modes on the handle itself, with the Oral-B app closed.** Turn the brush on, then
   press the mode button (if there is one) repeatedly. Write down each mode the lights or icons show.
   *This is the single most important test.* If the handle still cycles through your old modes,
   the firmware didn't remove them: only the app's controls changed.
3. Note your Oral-B app version (iPhone Settings › Apps › Oral-B, or the app's About screen) and
   the date it updated, if you know it.

## Phase 1: passive scan on iPhone (read-only)

Install **nRF Connect for Mobile** (Nordic Semiconductor, free). LightBlue works too.

1. Force-quit the Oral-B app. The brush accepts only one connection at a time.
2. Open nRF Connect › Scanner. Press the brush's power button to wake it.
3. Find the device whose manufacturer data shows company **0x00DC** (Procter & Gamble).
   Tap the row to expand it. **[Documented]**
4. Screenshot the **Manufacturer data** bytes. The bytes after the company ID decode as:

   | Byte | Meaning | Example |
   |---|---|---|
   | 0 | protocol version | `03` |
   | 1 | **model type**: the strongest hardware clue (see `docs/PROTOCOL.md`) | `29` = 41 = D700 6-mode |
   | 2 | firmware byte | `04` |
   | 3 | state (idle 2, running 3, charging 4…) | |
   | 4 | pressure / button flags | |
   | 5–6 | brushing time, min:sec | |
   | 7 | current mode | |
   | 8 | sector | |

   Take the screenshot once while the brush is idle and once while it's running in each mode
   you can select. **[Documented]**

Nothing is sent to the brush in this phase.

## Phase 2: GATT read-only inspection on iPhone

1. In nRF Connect, tap **Connect**.
2. Find the custom service whose characteristic UUIDs look like
   `A0F0FFxx-5047-4D53-8208-4F72616C2D42`.
3. Use only the **read (↓)** and **subscribe (↓↓↓)** buttons. **Do not tap the write (↑) button.**
4. Read and screenshot these:
   - `…FF02` model / protocol / firmware
   - `…FF05` battery (first byte = %)
   - `…FF07` current mode
   - `…FF25` **available modes**: the key value for the missing-modes question
5. Subscribe to everything that offers notify, then brush for 30 s and press the mode button.
   Screenshot the log.

**Send me:** the Phase 0 mode count, the Phase 1 manufacturer data, the `FF02` and `FF25` values,
and the app version. That's enough to tell which explanation in
[`docs/HARDWARE.md`](docs/HARDWARE.md#why-did-modes-disappear) applies.

## Phase 3: see what the Oral-B app sends (needs a Mac, optional)

iPhones can't capture Bluetooth traffic by themselves without a jailbreak, and this project
doesn't jailbreak. Apple's supported route **[Documented]**:

1. On the iPhone, install Apple's **Bluetooth logging profile** (developer.apple.com › Bug Reporting › Profiles and Logs).
2. Reproduce the action in the Oral-B app, such as changing the mode settings.
3. Trigger a sysdiagnose (press both volume buttons and the side button briefly) and AirDrop it to the Mac.
4. Open the Bluetooth log in **PacketLogger** (Xcode's *Additional Tools* download).
   Look for ATT Write Requests to `A0F0FF21` (control) followed by `A0F0FF25`.

That's the only way to see the official app's exact writes. Use it before trusting any write.

## Phase 4: the LocalBrush iPhone app (needs a Mac with Xcode)

**What it does:**
- Shows live state, mode, brushing time, pressure and sector from advertisements, without connecting.
- Shows battery and model once connected.
- Shows and backs up the handle's **available-modes** list; changes it only after you confirm, then reads it back to verify.
- Reads the sessions stored on the brush and keeps local history in a JSON file (visible in the Files app).
- Has an inspector that reads every characteristic and exports a JSON snapshot.

It needs no account and no internet.

**What it deliberately doesn't do:** set motor speed, change the pressure or timer behaviour,
write the current-mode characteristic (no source documents it as writable), touch factory or
test states, or update firmware.

### Build and install

You need a Mac with Xcode 15 or later and a free Apple ID. Apple offers no way to build an app
on the iPhone itself and install it there.

```sh
brew install xcodegen
cd oralb-local/ios/App
xcodegen                      # creates LocalBrush.xcodeproj
open LocalBrush.xcodeproj
```

In Xcode: select the LocalBrush target › Signing & Capabilities › Team = your Apple ID.
Plug in the iPhone, choose it as the run destination, then press Run. On the phone, approve the
developer profile under Settings › General › VPN & Device Management. With a free account the app
expires after 7 days; press Run again to renew it.

Run the protocol tests on the Mac:

```sh
cd oralb-local/ios && swift test
```

The Simulator has no Bluetooth, so test the app on a real iPhone.

### Changing modes (only after Phase 2 says it's warranted)

Brushing modes › **Save backup** (the first backup is never overwritten) › tap the modes in
button order › **Write** › confirm. Then check the handle's mode button. If anything looks wrong,
tap **Restore backup**. **[Experimental, reversible]**

Before writing, the app checks that a backup exists for this brush, that the model type matches
the backup, that the brush is idle and not in a factory state, and that every mode ID is a
documented one. It never guesses the byte used for empty slots: it reuses the one already on the handle.

## Phase 5: Raspberry Pi and Home Assistant (optional, read-mostly)

```
Toothbrush ──BLE adverts──▶ Raspberry Pi / ESP32 proxy ──▶ Home Assistant (local)
```

- **Home Assistant has a built-in Oral-B integration** (it uses the `oralb-ble` library). On a Pi with
  Bluetooth, or with an ESPHome `bluetooth_proxy` near the bathroom, the brush is auto-discovered.
  You get state, mode, time, pressure and sector from advertisements, plus battery from occasional
  polling. It runs locally with no cloud. **[Documented]** This is the easiest route to a dashboard.
- Without Home Assistant: `python/oralb.py scan --csv log.csv` on a Pi logs every state change.
- **Remote motor control is not possible** with any documented command. The handle's buttons
  start and stop the motor; Bluetooth only reports and configures.

```sh
cd oralb-local/python
python3 -m venv .venv && . .venv/bin/activate && pip install -r requirements.txt
python3 oralb.py scan                    # passive
python3 oralb.py inspect <address>       # read-only, saves a JSON snapshot (your backup)
python3 oralb.py modes <address>
python3 -m unittest -v test_oralb_protocol
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| Brush doesn't show in scans | Press the power button: it advertises for a short time after waking. Lift it off and back onto the charger. |
| Connect fails or times out | Force-quit the Oral-B app, turn the phone's Bluetooth off and on, move closer. |
| "Unrecognized advertisement format" | Send the raw bytes. Your handle uses a layout not in the tables. |
| Available-modes read fails | Your variant may not expose it. That's a finding, not an error: see `HARDWARE.md`. |
| Write says "can't tell which byte marks an empty slot" | Select every slot, or send the raw value so the filler can be identified. |
| App expired after 7 days | Free signing limit: re-run it from Xcode. |
