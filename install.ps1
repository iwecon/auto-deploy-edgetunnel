[CmdletBinding()]
param(
  [string]$Ref = $(if ($env:EDGETUNNEL_REF) { $env:EDGETUNNEL_REF } else { "main" }),
  [string]$InstallDir = $(if ($env:EDGETUNNEL_INSTALL_DIR) { $env:EDGETUNNEL_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA "Programs\EdgeTunnel" })
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$Repository = "iwecon/auto-deploy-edgetunnel"
if ($Ref -notmatch '^[A-Za-z0-9._-]+$') {
  throw "EDGETUNNEL_REF 只能包含字母、数字、点、下划线或连字符。"
}
if (-not (Get-Command swift -ErrorAction SilentlyContinue)) {
  throw "缺少 Swift 5.9 或更高版本。请先按照 https://www.swift.org/install/windows/ 安装 Swift。"
}

$TemporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("edgetunnel-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TemporaryDirectory | Out-Null

try {
  $ArchivePath = Join-Path $TemporaryDirectory "source.zip"
  $ArchiveURL = "https://github.com/$Repository/archive/$Ref.zip"
  Write-Host "正在下载 EdgeTunnel ($Ref)…"
  Invoke-WebRequest -UseBasicParsing -Uri $ArchiveURL -OutFile $ArchivePath
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $TemporaryDirectory

  $SourceDirectory = Get-ChildItem -LiteralPath $TemporaryDirectory -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "Package.swift") } |
    Select-Object -First 1
  if (-not $SourceDirectory) {
    throw "下载内容不是预期的 Swift Package。"
  }

  Write-Host "正在构建 release 可执行文件…"
  & swift build --package-path $SourceDirectory.FullName --configuration release
  if ($LASTEXITCODE -ne 0) {
    throw "Swift release 构建失败。"
  }

  $Executable = Join-Path $SourceDirectory.FullName ".build\release\edgetunnel.exe"
  if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) {
    throw "构建完成，但没有找到 edgetunnel.exe。"
  }

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  Copy-Item -Force -LiteralPath $Executable -Destination (Join-Path $InstallDir "edgetunnel.exe")

  Write-Host ""
  Write-Host "✓ edgetunnel 已安装到 $(Join-Path $InstallDir 'edgetunnel.exe')"
  $PathEntries = $env:PATH -split ';'
  if ($PathEntries -notcontains $InstallDir) {
    Write-Host "请把 $InstallDir 加入 PATH，然后运行 edgetunnel --help。"
  }
}
finally {
  Remove-Item -LiteralPath $TemporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
}
