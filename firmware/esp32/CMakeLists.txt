cmake_minimum_required(VERSION 3.16)
# 固件版本独立于 App 版本：单独发布为 GitHub Release firmware-v<版本>（scripts/release_firmware.sh）
set(PROJECT_VER "1.2.2")
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(notibridge_esp32)
