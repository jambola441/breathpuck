#!/bin/sh
# Build or flash the XIAO firmware.
#
#   firmware/build.sh            compile
#   firmware/build.sh upload     compile, then flash over USB (double-tap reset if no port)
#
# On Apple Silicon the Seeed nRF52 core ships Intel-only helpers (gcc, ctags,
# adafruit-nrfutil). This script swaps in native ones under firmware/.tools,
# needs no sudo and no Rosetta, and leaves the Arduino installation untouched.
# Because the ctags step is skipped, every function in the sketch must be
# defined before its first use, which breathpuck_xiao.ino already does.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
TOOLS="$HERE/.tools"
OUT="$TOOLS/out"
FQBN=Seeeduino:nrf52:xiaonRF52840Sense
SKETCH="$HERE/breathpuck_xiao"
BOARD_URL=https://files.seeedstudio.com/arduino/package_seeeduino_boards_index.json

command -v arduino-cli >/dev/null || { echo "install arduino-cli first: brew install arduino-cli"; exit 1; }
arduino-cli core list 2>/dev/null | grep -q '^Seeeduino:nrf52' || {
  arduino-cli config add board_manager.additional_urls "$BOARD_URL" 2>/dev/null || true
  arduino-cli core update-index
  arduino-cli core install Seeeduino:nrf52
  arduino-cli lib install "Seeed Arduino LSM6DS3" "Adafruit DRV2605 Library"
}

mkdir -p "$TOOLS/ctags" "$TOOLS/bin" "$OUT"
NRFUTIL=adafruit-nrfutil
set -- "${1:-compile}" "$2"
PROPS=""
if [ "$(uname -sm)" = "Darwin arm64" ]; then
  GCC=/opt/homebrew/opt/arm-gcc-bin@13
  [ -x "$GCC/bin/arm-none-eabi-g++" ] || brew install osx-cross/arm/arm-gcc-bin@13
  printf '#!/bin/sh\nexit 0\n' > "$TOOLS/ctags/ctags"; chmod +x "$TOOLS/ctags/ctags"
  ln -sf "$(command -v python3)" "$TOOLS/bin/python"
  [ -x "$TOOLS/venv/bin/adafruit-nrfutil" ] || { python3 -m venv "$TOOLS/venv"; "$TOOLS/venv/bin/pip" -q install adafruit-nrfutil; }
  NRFUTIL="$TOOLS/venv/bin/adafruit-nrfutil"
  export PATH="$TOOLS/bin:$PATH"
  PROPS="--build-property runtime.tools.arm-none-eabi-gcc.path=$GCC \
         --build-property runtime.tools.ctags.path=$TOOLS/ctags \
         --build-property tools.nrfutil.cmd.macosx=$NRFUTIL"
fi

# shellcheck disable=SC2086
arduino-cli compile --fqbn "$FQBN" $PROPS --output-dir "$OUT" "$SKETCH"

case "$1" in
  compile) echo "built $OUT/breathpuck_xiao.ino.zip" ;;
  upload)
    PORT=${2:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)}
    [ -n "$PORT" ] || { echo "no /dev/cu.usbmodem* port. Plug the XIAO in, or double-tap its reset button."; exit 1; }
    "$NRFUTIL" --verbose dfu serial -pkg "$OUT/breathpuck_xiao.ino.zip" -p "$PORT" -b 115200 --singlebank
    ;;
  *) echo "usage: $0 [compile|upload [port]]"; exit 2 ;;
esac
