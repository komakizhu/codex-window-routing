#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
config_dir="$HOME/.hammerspoon"
init_file="$config_dir/init.lua"
marker="codex-computer-use-observer-loader v1"

if [[ ! -d /Applications/Hammerspoon.app ]]; then
  echo "找不到 /Applications/Hammerspoon.app；请先安装 Hammerspoon。" >&2
  exit 1
fi

if [[ -f "$init_file" ]] && ! /usr/bin/grep -Fq "$marker" "$init_file"; then
  echo "停止：发现现有 init.lua，未覆盖。请先合并配置或手动备份后再安装。" >&2
  exit 2
fi

/usr/bin/install -d "$config_dir"
/bin/cp -p "$source_dir/init.lua" "$init_file"
/bin/cp -p "$source_dir/computer_use_observer.lua" "$config_dir/computer_use_observer.lua"
echo "已安装只读观察器配置；没有启动 Hammerspoon。"
echo "在方便时手动启动 Hammerspoon，再从菜单栏点击“开始窗口观察”。"
