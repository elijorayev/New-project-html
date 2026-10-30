# Hardware identification, missing-modes analysis, risks

## What is known about Type 3767

| Claim | Status | Source |
|---|---|---|
| "Type 3767" is a handle type shared by many retail models (iFixit lists GumCare 3, Smart 1000–6000, Smart 4, Smart 5, Smart Junior, Smart Professional, Smart Teen) | Documented | [iFixit: Braun Oral-B Type 3767](https://www.ifixit.com/Device/Braun_Oral-B_Type_3767) |
| Type 3757 is the matching charger, not the handle | Documented | Braun Oral-B Teen manual ([manualmachine](https://manualmachine.com/braun/oralbteen/6755235-user-manual)) |
| Li-ion battery, 49 mm × 14 mm | Documented | iFixit (above) |
| Brushing modes depend on the retail model | Documented | Braun 3767 manual ([manualslib](https://www.manualslib.com/manual/3299312/Braun-3767.html)) |
| FCC ID USQ3767 grantee is Braun GmbH | Plausible; not verified here, because fccid.io was blocked from this environment | check fccid.io/USQ3767 yourself |
| Your exact retail model | **Unknown** until the BLE model-type byte is read | Phase 1 |

**Most reliable identification:** byte 1 of the advertisement (or the first byte of
characteristic `FF02`) is a model-type code. The suffix says how many modes the hardware variant
was built with: "D601 Pro (5 mode)", "D700 (6 mode)", "(X mode)" = configurable. That code comes
from the brush itself, so it beats any guess from the type number.

The "AB0205610" code on the bottom is probably a production or date code. Nothing here depends on it.

## Why did modes disappear?

Four explanations, each with a test that tells them apart:

| # | Hypothesis | How likely | Test | Fix |
|---|---|---|---|---|
| A | **The app update removed or hid controls** for older handles. The brush is unchanged. | Most common pattern; unverified for your case | Phase 0: the handle's own mode button still cycles all your old modes | Nothing to restore on the brush. Use LocalBrush to see and log modes. |
| B | **The handle's available-modes list (`FF25`) was rewritten** by the app (setup, reset, or a new default) | Plausible: `FF25` is documented as writable and reorderable | Phase 2: `FF25` lists fewer modes than the model-type suffix allows | Write a fuller list with LocalBrush. **[Experimental, reversible]** |
| C | **A firmware update removed modes** | Unlikely but not ruled out. No public source documents app-delivered firmware updates for these SmartSeries handles. | The firmware byte changes, *and* the model suffix allows more modes than `FF25` accepts | None safe. Firmware reflashing is out of scope. |
| D | **The hardware variant never had them** (e.g. a 3-mode Smart 4 vs a 5-mode Smart 5 in the same 3767 housing) | Plausible, given how many models share 3767 | Model-type suffix matches the modes you have now | None needed. Modes the motor driver doesn't support can't be added. |

The mode IDs in the community tables (Daily Clean, Sensitive, Whitening…) may be named
differently on your handle. Some manuals list "Pro Clean". Match IDs to lights or icons by
observing byte 7 while you select each mode.

## Safety boundaries

The available-modes list selects among the handle's **factory-defined** motor profiles. Speed,
pressure-sensor limits, auto-shutoff, charging and thermal protection are handled by firmware
and hardware that this project never touches.

| Action | Label |
|---|---|
| Passive scanning, GATT reads, subscribing to notifications | Documented, no risk to the device |
| Reading stored sessions (writes a "select record N" command) | Documented; changes no settings |
| Rewriting the available-modes list, after a backup | Experimental, reversible |
| Setting the clock, user ID or sector timers | Documented as writable, but not implemented here: not needed for your goals |
| Writing unknown characteristics (`FF0A`, `FF2x`, `FF8x`), replaying captured bytes you don't understand | **Not recommended** |
| Entering factory or test states (state codes 113, 114, 116) | **Not recommended** |
| Firmware dumping or flashing, SWD/JTAG probing, opening the sealed handle | **Not recommended**: breaks the water seal, Li-ion battery hazard, no documented recovery |
| Downgrading firmware | Not supported by any public source |

## Recovery plan

1. **Bad available-modes write:** LocalBrush › Brushing modes › Restore backup.
   Or: `python3 oralb.py restore <address> --backup snapshot.json --i-understand`.
2. **No backup, and the list looks wrong:** pair the brush with the official Oral-B app again.
   It writes its own default configuration.
3. **The brush stops responding over Bluetooth:** put it on the charger for a few minutes, then press
   the power button. The toothbrush still works without any app.
4. Nothing in this project can affect brushing safety, because none of it writes motor,
   sensor or firmware settings.
