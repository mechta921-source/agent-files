#!/usr/bin/env bash
# install-vscode-tunnel.sh — установка VS Code Remote Tunnel для персонального AI-агента.
#
# Идемпотентный (можно перезапускать). Ставит:
#   1. code CLI (tarball с update.code.visualstudio.com) → /usr/local/bin/code
#   2. State dir /home/agent/.vscode-tunnel (chown agent:agent)
#   3. 5 systemd-юнитов из templates/vscode-tunnel/ с подставленным TUNNEL_NAME
#   4. Enable path-юнитов (agent-tunnel.service сам стартует через trigger)
#
# Использование:
#   sudo bash install-vscode-tunnel.sh <TUNNEL_NAME> [TEMPLATE_DIR] [USERNAME]
#
# TUNNEL_NAME: имя туннеля, например "agent-a1b2c3d4". Подставляется в ExecStart.
# TEMPLATE_DIR: путь к папке с шаблонами (по умолчанию = $(dirname "$0")).
# USERNAME:    под кем запускать туннель (по умолчанию "agent"). У старых установок
#              где бот работает под root — передавать "root". HOME_DIR определится
#              автоматически через getent passwd.
set -euo pipefail

TUNNEL_NAME="${1:?ERROR: TUNNEL_NAME is required (e.g. agent-a1b2c3d4)}"
TEMPLATE_DIR="${2:-$(cd "$(dirname "$0")" && pwd)}"
AGENT_USER="${3:-agent}"

# Простая валидация имени туннеля: только [a-z0-9-], 6-63 символа (ограничение Microsoft).
if ! [[ "$TUNNEL_NAME" =~ ^[a-z0-9-]{6,63}$ ]]; then
  echo "[install-vscode-tunnel] ERROR: invalid TUNNEL_NAME='$TUNNEL_NAME' (need [a-z0-9-]{6,63})" >&2
  exit 1
fi

AGENT_HOME=$(getent passwd "$AGENT_USER" 2>/dev/null | cut -d: -f6)
if [ -z "$AGENT_HOME" ] || [ ! -d "$AGENT_HOME" ]; then
  echo "[install-vscode-tunnel] ERROR: user '$AGENT_USER' not found or has no home dir" >&2
  exit 1
fi
STATE_DIR="${AGENT_HOME}/.vscode-tunnel"
RUNTIME_DIR="${AGENT_HOME}/.agent"
CODE_BIN="/usr/local/bin/code"
SYSTEMD_DIR="/etc/systemd/system"

log() { echo "[install-vscode-tunnel] $*"; }

# Требуем root (нужен для chown, /usr/local/bin/, systemd).
if [ "$(id -u)" -ne 0 ]; then
  log "ERROR: must run as root (use sudo)"; exit 1
fi

# --- 1. Установка code CLI (skip если уже стоит) ---
if [ -x "$CODE_BIN" ] && "$CODE_BIN" --version >/dev/null 2>&1; then
  log "code CLI уже установлен: $("$CODE_BIN" --version | head -1)"
else
  log "скачиваю code CLI (latest stable, linux x64)..."
  TMP_TGZ="/tmp/vscode-cli-$$.tar.gz"
  # Microsoft возвращает 302 на актуальный tarball — следуем редиректу.
  if ! curl -fsSL --max-time 120 \
        "https://update.code.visualstudio.com/latest/cli-linux-x64/stable" \
        -o "$TMP_TGZ"; then
    log "ERROR: не удалось скачать tarball — проверь сеть"
    rm -f "$TMP_TGZ"
    exit 1
  fi
  tar -xzf "$TMP_TGZ" -C /tmp
  install -m 0755 /tmp/code "$CODE_BIN"
  rm -f "$TMP_TGZ" /tmp/code
  log "установлен: $("$CODE_BIN" --version | head -1)"
fi

# --- 2. State dir под юзером agent ---
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$STATE_DIR"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$RUNTIME_DIR"

# --- 3. Systemd-юниты с подставленными плейсхолдерами ---
# Шаблоны содержат USER_PLACEHOLDER, HOME_PLACEHOLDER, TUNNEL_NAME_PLACEHOLDER.
# Подставляем через sed, проверяем что плейсхолдеры реально заменились.
#
# Для sed используем разделитель | вместо / потому что HOME_PLACEHOLDER заменяется
# на путь со слешами (/home/agent или /root). Все три плейсхолдера в одной команде.
SED_EXPR="s|USER_PLACEHOLDER|${AGENT_USER}|g;s|HOME_PLACEHOLDER|${AGENT_HOME}|g;s|TUNNEL_NAME_PLACEHOLDER|${TUNNEL_NAME}|g"

for unit in agent-tunnel.service tunnel-ctl.path tunnel-ctl.service tunnel-stop.path tunnel-stop.service; do
  src="${TEMPLATE_DIR}/${unit}"
  tmp="/tmp/${unit}.$$"
  if [ ! -f "$src" ]; then
    log "ERROR: шаблон не найден: $src"; exit 1
  fi
  sed "$SED_EXPR" "$src" > "$tmp"
  if grep -qE "(USER_PLACEHOLDER|HOME_PLACEHOLDER|TUNNEL_NAME_PLACEHOLDER)" "$tmp"; then
    log "ERROR: остались незаменённые плейсхолдеры в $unit"
    rm -f "$tmp"; exit 1
  fi
  install -m 0644 "$tmp" "${SYSTEMD_DIR}/${unit}"
  rm -f "$tmp"
done

systemctl daemon-reload
# Enable только path-юниты. agent-tunnel.service стартует через trigger (бот пишет flag).
systemctl enable tunnel-ctl.path tunnel-stop.path >/dev/null 2>&1
systemctl start tunnel-ctl.path tunnel-stop.path

log "✔ VS Code tunnel установка завершена."
log "  Tunnel name: ${TUNNEL_NAME}"
log "  Code CLI:    $(${CODE_BIN} --version | head -1)"
log "  Trigger:     touch ${RUNTIME_DIR}/.tunnel-start (бот сделает это при /connect)"
