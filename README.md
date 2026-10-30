# BreathPuck

A breathwork wearable: two magnetic discs on a short ribbon that clip through a
shirt at the neckline or the cuff. The disc against the skin holds a linear
vibration motor that swells and fades with a breathing pattern. An iPhone app
reads breathing from the motion of the chest and either paces you or follows you.

Build notes, the parts list with prices, wiring and the printable shells are at
<https://generic.tech/breath-work-wearable/>.

## What is here

- `BreathPuck/` SwiftUI iPhone app (Xcode 27, iOS 27). Breath detection from an
  accelerometer, three paced patterns, a follow mode, phone haptics, and the
  Bluetooth client for the puck. `BreathPuckTests/` checks the detector against
  synthetic chest motion.
- `firmware/` Arduino sketch for the Seeed XIAO nRF52840 Sense with a DRV2605L
  haptic driver, plus `build.sh` which compiles and flashes it, including on
  Apple Silicon where the Seeed core's bundled tools are Intel-only.

## Bluetooth contract

Service `7A0B0001-6F3C-4D2E-9B1A-0B7E47B5C001`.

| Characteristic | UUID prefix | Direction | Payload |
|---|---|---|---|
| IMU | `7A0B0002` | notify, 25 Hz | int16 ax, ay, az at 8192 counts/g, uint16 sequence, little-endian |
| Haptic | `7A0B0003` | write without response, 50 Hz | one byte, amplitude 0 to 127 |
| Battery | `0x180F` / `0x2A19` | notify | standard battery level, percent |

The app and the firmware both encode this; change it in both places.

## Status (30 October 2026)

Parts ordered. The app builds and its tests pass. The firmware compiles but has
not run on a board. Nothing has been worn yet.

## License

MIT, see `LICENSE`.
