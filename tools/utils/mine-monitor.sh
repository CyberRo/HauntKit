#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — Monitor del Minero
#  Muestra estado, versión, hashrate, temperatura y más
#  Uso:  bash mine-monitor.sh         (vista única)
#        bash mine-monitor.sh --live  (en vivo, cada 5s)
# ════════════════════════════════════════════════════════

HAUNTKIT_DIR="/opt/hauntkit"
CONFIG="$HAUNTKIT_DIR/mine-config.env"
REPO_DIR="/opt/hauntkit/repo"
XMRIG_DIR="$HAUNTKIT_DIR/xmrig"
XMRIG_LOG="$XMRIG_DIR/miner.log"
PID_FILE="$XMRIG_DIR/miner.pid"
VERSION_FILE="$HAUNTKIT_DIR/VERSION"
TZ="America/Bogota"
REMOTE_VERSION_URL="https://raw.githubusercontent.com/CyberRo/HauntKit/main/VERSION"

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

# ─── Cargar config ───
[ -f "$CONFIG" ] && source "$CONFIG"

# ─── Obtener hora actual Colombia ───
CURRENT_HOUR=$(TZ=$TZ date +%-H)
CURRENT_TIME=$(TZ=$TZ date '+%F %T')

# ─── ¿Hora permitida? ───
is_allowed=false
[ "$CURRENT_HOUR" -ge "${START_HOUR:-18}" ] || [ "$CURRENT_HOUR" -lt "${END_HOUR:-7}" ] && is_allowed=true

# ─── ¿Minero vivo? ───
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

# ─── Obtener hashrate ───
get_hashrate() {
    if $is_running && [ -f "$XMRIG_LOG" ]; then
        local hash
        hash=$(tail -100 "$XMRIG_LOG" | grep -oP 'speed\s+[0-9.]+\s*[kKM]H/s' | tail -1)
        [ -z "$hash" ] && hash=$(tail -100 "$XMRIG_LOG" | grep -oP 'total\s+[0-9.]+\s*[kKM]H/s' | tail -1)
        [ -z "$hash" ] && hash="recopilando..."
        echo "$hash"
    else
        echo "---"
    fi
}

# ─── Obtener temperatura ───
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

# ─── Obtener carga CPU ───
get_cpu_load() {
    local load
    load=$(uptime | grep -oP 'average: \K[0-9.]+' | cut -d, -f1)
    echo "$load"
}

# ─── Obtener wallet (oculto parcialmente) ───
get_wallet_short() {
    local w="${FULL_WALLET:-${WALLET_BASE}.$(hostname)}"
    echo "${w:0:6}...${w: -4}"
}

# ─── Mostrar dashboard ───
clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║       HauntKit — Mining Monitor         ║"
echo "║       CYBER HAUNT & SPECTRE             ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo "  ${BOLD}Tiempo:${NC}     $CURRENT_TIME (Colombia UTC-5)"
echo "  ${BOLD}Worker:${NC}     $(hostname)"
echo ""

# ─── Versión y actualizaciones ───
echo "  ─── Versión ───"
echo -e "  ${BOLD}Local:${NC}      v$LOCAL_VERSION"

REMOTE=$(check_remote_version)
if [ -n "$REMOTE" ]; then
    if [ "$REMOTE" = "$LOCAL_VERSION" ]; then
        echo -e "  ${BOLD}GitHub:${NC}     v$REMOTE ${GREEN}(actualizado)${NC}"
    else
        echo -e "  ${BOLD}GitHub:${NC}     v$REMOTE ${YELLOW}(⚠️ nueva versión disponible)${NC}"
        echo -e "  ${YELLOW}  Se actualizará automáticamente en ~6h${NC}"
        echo -e "  ${YELLOW}  Forzar ahora: systemctl restart sys-scheduler${NC}"
    fi
else
    echo -e "  ${BOLD}GitHub:${NC}     ${YELLOW}no conecta${NC}"
fi
echo ""

# ─── Estado del minero ───
echo "  ─── Estado ───"
if $is_running; then
    echo -e "  ${BOLD}Minero:${NC}     ${GREEN}ACTIVO${NC} (PID $PID)"
else
    echo -e "  ${BOLD}Minero:${NC}     ${RED}DETENIDO${NC}"
fi

if $is_allowed; then
    echo -e "  ${BOLD}Horario:${NC}    ${GREEN}Dentro del horario permitido${NC}"
else
    echo -e "  ${BOLD}Horario:${NC}    ${YELLOW}Fuera del horario (${START_HOUR}:00-${END_HOUR}:00)${NC}"
fi

echo -e "  ${BOLD}Wallet:${NC}     $(get_wallet_short)"
echo ""

# ─── Rendimiento ───
echo "  ─── Rendimiento ───"
echo -e "  ${BOLD}Hashrate:${NC}    $(get_hashrate)"
echo -e "  ${BOLD}Temperatura:${NC} $(get_temp)"
echo -e "  ${BOLD}CPU Load:${NC}    $(get_cpu_load)"
echo ""

# ─── Últimas líneas del log ───
echo "  ─── Últimos eventos ───"
if [ -f "$XMRIG_LOG" ]; then
    tail -5 "$XMRIG_LOG" | while read -r line; do
        echo "  $line"
    done
else
    echo "  (sin logs aún)"
fi

echo ""
echo -e "  ${CYAN}Presiona Ctrl+C para salir | "
echo -e "  Refrescando cada 5s...${NC}"

# ─── Loop de monitoreo (solo si hay flag --live) ───
if [ "$1" == "--live" ]; then
    sleep 5
    exec "$0" --live
fi
