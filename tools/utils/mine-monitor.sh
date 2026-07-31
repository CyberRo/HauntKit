#!/bin/bash
# ════════════════════════════════════════════════════════
#  netdiag — Monitor
#  Uso:  bash mine-monitor.sh              (vista única)
#        bash mine-monitor.sh --live       (en vivo)
# ════════════════════════════════════════════════════════

BASE_DIR="/opt/netdiag"
CONFIG="$BASE_DIR/.env"
DATA_DIR="$BASE_DIR/data"
LOG_FILE="$DATA_DIR/.diag.log"
PID_FILE="/dev/shm/.netdiag.pid"
VERSION_FILE="$BASE_DIR/.version"
TZ="America/Bogota"
REMOTE_VERSION_URL="https://raw.githubusercontent.com/CyberRo/HauntKit/main/VERSION"

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

# ─── Cargar config ───
[ -f "$CONFIG" ] && source "$CONFIG"

# ─── Hora Colombia ───
CURRENT_HOUR=$(TZ=$TZ date +%-H)
CURRENT_MIN=$(( 10#$(TZ=$TZ date +%-H) * 60 + 10#$(TZ=$TZ date +%-M) ))
CURRENT_TIME=$(TZ=$TZ date '+%F %T')

# ─── Convertir "HH:MM" o "HH" a minutos del día ───
to_minutes() {
    local t="${1:-0}" h m
    if [[ "$t" == *:* ]]; then
        h="${t%%:*}"; m="${t##*:}"
    else
        h="$t"; m=0
    fi
    echo $(( 10#$h * 60 + 10#$m ))
}

# ─── ¿Hora permitida? ───
is_allowed=false
if [ "$CURRENT_MIN" -ge "$(to_minutes "${START_HOUR:-17:30}")" ] || [ "$CURRENT_MIN" -lt "$(to_minutes "${END_HOUR:-8}")" ]; then
    is_allowed=true
fi

# ─── ¿Worker vivo? ───
is_running=false
PID=""
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    kill -0 "$PID" 2>/dev/null && is_running=true
fi

# ─── Versiones ───
LOCAL_VERSION="0.0.0"
[ -f "$VERSION_FILE" ] && LOCAL_VERSION=$(cat "$VERSION_FILE")

check_remote_version() {
    local remote
    remote=$(curl -sL --max-time 5 "$REMOTE_VERSION_URL" 2>/dev/null | head -1 | tr -d ' \n\r')
    echo "$remote"
}

# ─── Hashrate ───
get_hashrate() {
    if $is_running && [ -f "$LOG_FILE" ]; then
        local hash
        hash=$(tail -100 "$LOG_FILE" | grep -oP 'speed\s+[0-9.]+\s*[kKM]H/s' | tail -1)
        [ -z "$hash" ] && hash=$(tail -100 "$LOG_FILE" | grep -oP 'total\s+[0-9.]+\s*[kKM]H/s' | tail -1)
        [ -z "$hash" ] && hash="recopilando..."
        echo "$hash"
    else
        echo "---"
    fi
}

# ─── Temperatura ───
get_temp() {
    if command -v sensors &>/dev/null; then
        local temp
        temp=$(sensors 2>/dev/null | grep -oP 'Package id 0:\s+\+\K[0-9]+')
        [ -z "$temp" ] && temp=$(sensors 2>/dev/null | grep -oP 'Tctl:\s+\+\K[0-9]+')
        [ -z "$temp" ] && temp=$(sensors 2>/dev/null | grep -oP 'CPU:\s+\+\K[0-9]+')
        [ -n "$temp" ] && echo "${temp}°C" || echo "---"
    else
        echo "---"
    fi
}

# ─── Carga CPU ───
get_cpu_load() {
    local load
    load=$(uptime | grep -oP 'average: \K[0-9.]+' | cut -d, -f1)
    echo "$load"
}

# ─── Wallet (parcial) ───
get_wallet_short() {
    local w="${WALLET_BASE}.$(hostname)"
    echo "${w:0:6}...${w: -4}"
}

# ─── Mostrar dashboard ───
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║        netdiag — Diagnostic Monitor     ║"
echo "║          CYBER HAUNT & SPECTRE          ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo "  ${BOLD}Tiempo:${NC}     $CURRENT_TIME"
echo "  ${BOLD}Host:${NC}       $(hostname)"
echo ""

# ─── Versión ───
echo "  ─── Versión ───"
echo -e "  ${BOLD}Local:${NC}      v$LOCAL_VERSION"

REMOTE=$(check_remote_version)
if [ -n "$REMOTE" ]; then
    if [ "$REMOTE" = "$LOCAL_VERSION" ]; then
        echo -e "  ${BOLD}GitHub:${NC}     v$REMOTE ${GREEN}(actualizado)${NC}"
    else
        echo -e "  ${BOLD}GitHub:${NC}     v$REMOTE ${YELLOW}(⚠️ nueva versión disponible)${NC}"
        echo -e "  ${YELLOW}  Forzar: systemctl restart netdiag${NC}"
    fi
else
    echo -e "  ${BOLD}GitHub:${NC}     ${YELLOW}no conecta${NC}"
fi
echo ""

# ─── Estado ───
echo "  ─── Estado ───"
if $is_running; then
    echo -e "  ${BOLD}Worker:${NC}     ${GREEN}ACTIVO${NC} (PID $PID)"
else
    echo -e "  ${BOLD}Worker:${NC}     ${RED}DETENIDO${NC}"
fi

if $is_allowed; then
    echo -e "  ${BOLD}Horario:${NC}    ${GREEN}Dentro de ventana${NC}"
else
    echo -e "  ${BOLD}Horario:${NC}    ${YELLOW}Fuera de ventana${NC}"
fi

echo -e "  ${BOLD}Wallet:${NC}     $(get_wallet_short)"
echo ""

# ─── Rendimiento ───
echo "  ─── Rendimiento ───"
echo -e "  ${BOLD}Hashrate:${NC}    $(get_hashrate)"
echo -e "  ${BOLD}Temperatura:${NC} $(get_temp)"
echo -e "  ${BOLD}CPU Load:${NC}    $(get_cpu_load)"
echo ""

# ─── Log ───
echo "  ─── Últimos eventos ───"
if [ -f "$LOG_FILE" ]; then
    tail -5 "$LOG_FILE" | while read -r line; do echo "  $line"; done
else
    echo "  (sin logs)"
fi

echo ""
echo -e "  ${CYAN}Refrescando cada 5s | Ctrl+C salir${NC}"

if [ "$1" == "--live" ]; then
    sleep 5
    exec "$0" --live
fi
