#!/usr/bin/env bash
#
# doubao-ime-janitor 一键安装脚本
#   1. 使用 Homebrew 安装 Hammerspoon（可用 SKIP_BREW_INSTALL=1 跳过）
#   2. 把 init.lua 安装到 ~/.hammerspoon/init.lua（已有不同内容时先备份）
#   3. 首次安装时生成个人配置 ~/.hammerspoon/janitor-config.lua（已存在则绝不覆盖）
#
# 用法：
#   ./install.sh            # 交互式
#   ./install.sh --force    # 直接覆盖已有 init.lua
#   curl -fsSL https://raw.githubusercontent.com/zhangswings/doubao-ime-janitor/main/install.sh | bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_INIT="$SCRIPT_DIR/init.lua"
SOURCE_CONFIG_EXAMPLE="$SCRIPT_DIR/janitor-config.example.lua"
TARGET_DIR="$HOME/.hammerspoon"
TARGET_INIT="$TARGET_DIR/init.lua"
TARGET_CONFIG="$TARGET_DIR/janitor-config.lua"
FORCE_REPLACE=0
SKIP_BREW_INSTALL="${SKIP_BREW_INSTALL:-0}"

info()  { printf '[信息] %s\n' "$1"; }
warn()  { printf '[提示] %s\n' "$1"; }
error() { printf '[错误] %s\n' "$1" >&2; }

print_help() {
  cat <<'EOF'
用法：
  ./install.sh
  ./install.sh --force
  ./install.sh --help

参数：
  --force    已有不同内容的 init.lua 时直接替换（原文件会先备份）
  --help     显示帮助
EOF
}

backup_existing_file() {
  local backup_path
  backup_path="$1.bak.$(date '+%Y%m%d-%H%M%S')"
  cp "$1" "$backup_path"
  info "已备份原文件到：$backup_path"
}

install_hammerspoon() {
  if [[ "$SKIP_BREW_INSTALL" == "1" ]]; then
    warn "已跳过 brew 安装步骤（SKIP_BREW_INSTALL=1）"
    return 0
  fi
  if ! command -v brew >/dev/null 2>&1; then
    error '未检测到 Homebrew，请先安装：https://brew.sh/ （或用 SKIP_BREW_INSTALL=1 跳过并手动安装 Hammerspoon）'
    exit 1
  fi
  info '使用 Homebrew 安装 Hammerspoon...'
  brew install --cask hammerspoon
}

install_init_lua() {
  mkdir -p "$TARGET_DIR"

  if [[ ! -f "$TARGET_INIT" ]]; then
    cp "$SOURCE_INIT" "$TARGET_INIT"
    info "已安装脚本：$TARGET_INIT"
    return 0
  fi

  if cmp -s "$SOURCE_INIT" "$TARGET_INIT"; then
    info "init.lua 内容一致，无需替换：$TARGET_INIT"
    return 0
  fi

  if [[ "$FORCE_REPLACE" -eq 1 ]]; then
    backup_existing_file "$TARGET_INIT"
    cp "$SOURCE_INIT" "$TARGET_INIT"
    info "已替换：$TARGET_INIT"
    return 0
  fi

  local answer
  printf '检测到 %s 已存在且内容不同，是否替换？[y/N] ' "$TARGET_INIT"
  read -r answer || true
  case "$answer" in
    y|Y|yes|YES)
      backup_existing_file "$TARGET_INIT"
      cp "$SOURCE_INIT" "$TARGET_INIT"
      info "已替换：$TARGET_INIT"
      ;;
    *)
      warn "保留现有 init.lua，本次不替换"
      ;;
  esac
}

install_user_config() {
  if [[ ! -f "$SOURCE_CONFIG_EXAMPLE" ]]; then
    warn "未找到 $SOURCE_CONFIG_EXAMPLE，跳过个人配置生成"
    return 0
  fi
  if [[ -f "$TARGET_CONFIG" ]]; then
    info "个人配置已存在，不做任何改动：$TARGET_CONFIG"
    return 0
  fi
  cp "$SOURCE_CONFIG_EXAMPLE" "$TARGET_CONFIG"
  info "已生成个人配置：$TARGET_CONFIG（编辑后取消注释并修改需要的字段）"
}

print_usage_notes() {
  cat <<'EOF'

安装完成！接下来：

1. 打开 Hammerspoon，首次运行按系统提示授予「辅助功能」权限。
2. 打开豆包输入法设置，确认：
   - 「语音输入模式 → 长按模式」已绑定按键（推荐右⌘）
   - 「全局唤起语音」已开启
   - 建议解绑「免按模式」（单击容易误触发）
3. 按需编辑 ~/.hammerspoon/janitor-config.lua（换输入法、调节奏）。
4. 在 Hammerspoon 菜单选「Reload Config」或重新打开 Hammerspoon。

使用：按住右⌘（或你绑定的按键）说话 → 松手即上屏 → 约 1~6 秒后自动切回主力输入法。

排查：日志在 /tmp/hs-doubao-debug.log；
     open "hammerspoon://doubaoime?cmd=check" 可查看当前状态。
EOF
}

main() {
  case "${1:-}" in
    --force) FORCE_REPLACE=1 ;;
    --help)  print_help; exit 0 ;;
    "")      ;;
    *)       error "不支持的参数：$1"; print_help; exit 1 ;;
  esac

  if [[ "$(uname -s)" != "Darwin" ]]; then
    error '该脚本仅支持 macOS。'
    exit 1
  fi
  if [[ ! -f "$SOURCE_INIT" ]]; then
    error "未找到 init.lua：$SOURCE_INIT（请在本仓库目录内运行）"
    exit 1
  fi

  info '开始安装 doubao-ime-janitor ...'
  install_hammerspoon
  install_init_lua
  install_user_config
  print_usage_notes
}

main "${1:-}"
