# BreathPuck firmware (XIAO nRF52840 Sense)

One sketch, `breathpuck_xiao/breathpuck_xiao.ino`. It streams the XIAO's
accelerometer to the phone and drives the LRA from the amplitude the phone sends.

## Build and flash

```sh
brew install arduino-cli
firmware/build.sh            # compile
firmware/build.sh upload     # compile and flash over USB
```

The script installs the Seeed core and the two libraries on first run. On an
Apple Silicon Mac the Seeed core's bundled compiler, ctags and `adafruit-nrfutil`
are Intel-only; the script swaps in native copies under `firmware/.tools`
(Homebrew's `osx-cross/arm/arm-gcc-bin@13`, a Python venv for nrfutil) with no
sudo and no Rosetta. The Arduino IDE itself would need Rosetta for this core.

If upload cannot find the port, double-tap the XIAO's reset button to enter the
bootloader (the LED breathes) and try again.

Arduino IDE instead: board manager URL
`https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json`,
core **Seeed nRF52 Boards** (not "mbed-enabled"), libraries **Seeed Arduino
LSM6DS3** and **Adafruit DRV2605 Library**, board **Seeed XIAO nRF52840 Sense**.

## Wiring

| XIAO pin | goes to |
|---|---|
| 3V3 | DRV2605L VIN |
| GND | DRV2605L GND |
| D4 (SDA) | DRV2605L SDA |
| D5 (SCL) | DRV2605L SCL |
| BAT+ / BAT− pads (underside) | 100 mAh LiPo, red to +, black to − |
| | LRA leads to the DRV2605L motor terminals (+ and −, polarity does not matter for an LRA) |

The IMU is inside the XIAO on its own I2C bus; nothing to wire.

## First power-on

1. Open a serial monitor at 115200. You should see `DRV2605L ok` and `IMU ok`.
   `DRV2605L not found` means SDA/SCL or power to the breakout; the red LED stays on.
2. Mount the LRA in its disc, then send `c`. The driver runs its auto-calibration
   (about a second of buzzing) and stores the result in flash. Do this once per
   motor, and again if you change the shell.
3. Send `t` for a one-second test buzz at 60 %, `i` to print the accelerometer,
   `b` for battery volts and percent.
4. The blue LED blinks while advertising as **BreathPuck** and goes dark when the
   phone connects. The app's Puck tab shows packets received and dropped.

## What to check against the datasheets

The three constants at the top of the sketch set the drive voltage:
`LRA_RATED_VRMS`, `LRA_CLAMP_VPEAK`, `LRA_FREQ_HZ`. They are filled in from
memory for the Vybronics VLV101040A. Confirm the rated voltage on the datasheet
before the first calibration; over-driving an LRA shortens its life.

## Power

- The driver goes to standby after two seconds at zero amplitude and wakes on
  the next non-zero write, so idle current is the radio plus the IMU.
- Amplitude drops to zero one second after the last write from the phone, and
  on disconnect, so a crashed app never leaves the motor running.
- Charge current is set to 50 mA, correct for a 100 mAh cell. Do not change
  `PIN_CHARGING_CURRENT` to LOW (100 mA) with this battery.
