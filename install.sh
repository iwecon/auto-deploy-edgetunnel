#!/bin/sh

set -eu

repository="iwecon/auto-deploy-edgetunnel"
install_ref="${EDGETUNNEL_REF:-main}"
install_dir="${EDGETUNNEL_INSTALL_DIR:-${HOME}/.local/bin}"

case "$install_ref" in
  *[!A-Za-z0-9._-]* | "")
    printf '%s\n' "EDGETUNNEL_REF 只能包含字母、数字、点、下划线或连字符。" >&2
    exit 1
    ;;
esac

operating_system="$(uname -s)"
case "$operating_system" in
  Darwin | Linux) ;;
  *)
    printf '%s\n' "此安装脚本仅支持 macOS 和 Linux；Windows 请使用 install.ps1。" >&2
    exit 1
    ;;
esac

for command_name in curl tar swift install mktemp; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf '%s\n' "缺少必需命令：$command_name" >&2
    exit 1
  fi
done

if [ "$operating_system" = "Darwin" ]; then
  macos_major="$(sw_vers -productVersion | cut -d. -f1)"
  if [ "$macos_major" -lt 13 ]; then
    printf '%s\n' "EdgeTunnel 需要 macOS 13 或更高版本。" >&2
    exit 1
  fi
fi

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/edgetunnel-install.XXXXXX")"
cleanup() {
  rm -rf "$temp_dir"
}
trap cleanup EXIT HUP INT TERM

archive_url="https://github.com/${repository}/archive/${install_ref}.tar.gz"
archive_path="$temp_dir/source.tar.gz"

printf '%s\n' "正在下载 EdgeTunnel (${install_ref})…"
curl --proto '=https' --tlsv1.2 -fsSL "$archive_url" -o "$archive_path"
tar -xzf "$archive_path" -C "$temp_dir"

set -- "$temp_dir"/auto-deploy-edgetunnel-*
source_dir="$1"
if [ ! -f "$source_dir/Package.swift" ]; then
  printf '%s\n' "下载内容不是预期的 Swift Package。" >&2
  exit 1
fi

printf '%s\n' "正在构建 release 可执行文件…"
swift build --package-path "$source_dir" --configuration release

install -d "$install_dir"
install -m 0755 "$source_dir/.build/release/edgetunnel" "$install_dir/edgetunnel"

printf '\n%s\n' "✓ edgetunnel 已安装到 $install_dir/edgetunnel"
case ":${PATH}:" in
  *":${install_dir}:"*) ;;
  *)
    printf '%s\n' "请把 $install_dir 加入 PATH，然后运行 edgetunnel --help。"
    ;;
esac
