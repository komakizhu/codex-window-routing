#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")" && pwd)"
config_dir="$HOME/.hammerspoon"
init_file="$config_dir/init.lua"
state_file="$config_dir/.codex-sidecar-install-state"
agent_source="$source_dir/com.codex.computer-use-sidecar.plist"
agent_dir="$HOME/Library/LaunchAgents"
agent_file="$agent_dir/com.codex.computer-use-sidecar.plist"
marker="codex-computer-use-sidecar-loader v1"
agent_marker="com.codex.computer-use-sidecar"
stamp="$(/bin/date +%Y%m%d-%H%M%S)"

if [[ ! -d /Applications/Hammerspoon.app ]]; then
  echo "找不到 /Applications/Hammerspoon.app；请先安装 Hammerspoon。" >&2
  exit 1
fi

for module in computer_use_sidecar.lua computer_use_observer.lua external_window_router.lua window_gateway.lua; do
  if [[ ! -f "$source_dir/$module" ]]; then
    echo "停止：缺少模块 $source_dir/$module" >&2
    exit 3
  fi
done
if [[ ! -f "$agent_source" ]]; then
  echo "停止：缺少登录启动配置 $agent_source" >&2
  exit 3
fi
if [[ -e "$agent_file" ]] && ! /usr/bin/grep -Fq "$agent_marker" "$agent_file"; then
  echo "停止：登录启动配置已存在且不属于本项目，未覆盖。" >&2
  exit 4
fi

/usr/bin/install -d "$config_dir" "$config_dir/backups"

if [[ -f "$init_file" ]] && /usr/bin/grep -Fq "$marker" "$init_file"; then
  echo "自动分配入口已经安装；继续更新 Lua 模块。"
elif [[ -f "$state_file" ]]; then
  echo "停止：发现安装状态文件但入口不是自动分配入口；未改动配置。" >&2
  exit 2
elif [[ ! -e "$init_file" ]]; then
  /usr/bin/printf 'absent\n' > "$state_file"
elif /usr/bin/grep -Eq 'codex-computer-use-observer-loader v1|Temporary native Computer Use acceptance harness' "$init_file"; then
  backup="$config_dir/backups/init.lua.$stamp.bak"
  /bin/cp -p "$init_file" "$backup"
  /usr/bin/printf '%s\n' "$backup" > "$state_file"
else
  echo "停止：发现不是本项目创建的 init.lua，未覆盖它。" >&2
  exit 2
fi

for module in computer_use_sidecar.lua computer_use_observer.lua external_window_router.lua window_gateway.lua; do
  source_file="$source_dir/$module"
  target_file="$config_dir/$module"
  if [[ -f "$target_file" ]] && ! /usr/bin/cmp -s "$source_file" "$target_file"; then
    /bin/cp -p "$target_file" "$config_dir/backups/$module.$stamp.bak"
  fi
  /bin/cp -p "$source_file" "$target_file"
done

if [[ -f "$init_file" ]] && ! /usr/bin/cmp -s "$source_dir/init.lua" "$init_file"; then
  /bin/cp -p "$init_file" "$config_dir/backups/init.lua.$stamp.update.bak"
fi
/bin/cp -p "$source_dir/init.lua" "$init_file"
python3 "$source_dir/../config/install_global_window_routing.py"
/usr/bin/install -d "$agent_dir"
/bin/cp -p "$agent_source" "$agent_file"
uid="$(/usr/bin/id -u)"
/bin/launchctl bootout "gui/$uid" "$agent_file" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$uid" "$agent_file"
echo "已安装：可在菜单栏“CU副屏”中选择跟随焦点或固定副屏，已有选项会保留。"
echo "已设置 Hammerspoon 在你登录 macOS 时自动启动。"
echo "回滚：运行 $source_dir/restore_hammerspoon_config.sh"
