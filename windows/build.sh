#!/usr/bin/env bash
# 在 macOS / Linux / Windows(Git Bash) 上交叉编译 Windows 版，产物：windows/dist/HarmoBridge.exe（单文件，自带 .NET 运行时）
# 需要 .NET 10 SDK：macOS 上 `brew install --cask dotnet-sdk`
set -euo pipefail
cd "$(dirname "$0")"
dotnet test tests/HarmoBridge.Core.Tests -c Release
dotnet publish src/HarmoBridge.Windows -c Release -r win-x64 --self-contained \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true \
  -p:DebugType=none -o dist
echo "完成：$(pwd)/dist/HarmoBridge.exe"
