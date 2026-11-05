#!/bin/bash
set -euo pipefail

config_dir="$HOME/.hammerspoon"
init_file="$config_dir/init.lua"
state_file="$config_dir/.codex-sidecar-install-state"
agent_file="$HOME/Library/LaunchAgents/com.codex.computer-use-sidecar.plist"
marker="codex-computer-use-sidecar-loader v1"
source_dir="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$init_file" ]] || ! /usr/bin/grep -Fq "$marker" "$init_file"; then
  echo "停止：当前 init.lua 不是本项目自动分配入口，未修改任何文件。" >&2
  exit 2
fi

if [[ ! -f "$state_file" ]]; then
  echo "停止：找不到安装前状态记录，未改动配置。" >&2
  exit 3
fi

# Remove only the unchanged block owned by this project. If another task edited
# it, stop before changing Hammerspoon and preserve that work.
python3 "$source_dir/../config/install_global_window_routing.py" --remove

stamp="$(/bin/date +%Y%m%d-%H%M%S)"
uid="$(/usr/bin/id -u)"
if [[ -f "$agent_file" ]] && /usr/bin/grep -Fq 'com.codex.computer-use-sidecar' "$agent_file"; then
  /bin/launchctl bootout "gui/$uid" "$agent_file" >/dev/null 2>&1 || true
  /bin/mv "$agent_file" "$agent_file.disabled-$stamp"
fi
/bin/mv "$init_file" "$config_dir/init.lua.sidecar-disabled-$stamp"
state="$(/bin/cat "$state_file")"

if [[ "$state" == "absent" ]]; then
  echo "已恢复：安装前没有 init.lua，自动分配入口已停用。"
elif [[ -f "$state" ]]; then
  /bin/cp -p "$state" "$init_file"
  echo "已恢复安装前配置：$state"
else
  echo "已停用自动分配入口；备份路径不可用：$state" >&2
  exit 4
fi

/bin/mv "$state_file" "$state_file.restored-$stamp"
if /usr/bin/pgrep -x Hammerspoon >/dev/null 2>&1; then
  /opt/homebrew/bin/hs -c 'hs.reload()' >/dev/null 2>&1 || true
  echo "已通知 Hammerspoon 重新加载配置。"
fi
