#!/bin/bash
# 编译 ESP32 固件，并合并成一个镜像（从 0x1000 开始）放到 prebuilt/，供 Mac / Windows App 打包刷写。
# 需要 ESP-IDF v5.4：默认在 ~/esp/esp-idf（可用 IDF_PATH 指定）。
set -euo pipefail
cd "$(dirname "$0")"
./test/run_tests.sh
IDF_PATH="${IDF_PATH:-$HOME/esp/esp-idf}"
# shellcheck disable=SC1091
. "$IDF_PATH/export.sh" >/dev/null
idf.py set-target esp32 >/dev/null 2>&1 || true
idf.py build
mkdir -p prebuilt
cd build
python -m esptool --chip esp32 merge_bin -o ../prebuilt/notibridge-esp32.bin --target-offset 0x1000 @flash_args
cd ..
ls -l prebuilt/notibridge-esp32.bin
