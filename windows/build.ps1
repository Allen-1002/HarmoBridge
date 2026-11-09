# 在 Windows 上编译，产物：windows\dist\NotiBridge.exe（单文件，自带 .NET 运行时）。需要 .NET 10 SDK。
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
dotnet test tests/NotiBridge.Core.Tests -c Release
dotnet publish src/NotiBridge.Windows -c Release -r win-x64 --self-contained `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:EnableCompressionInSingleFile=true `
  -p:DebugType=none -o dist
Write-Host "完成：$PSScriptRoot\dist\NotiBridge.exe"
