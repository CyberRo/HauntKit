#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  watchdogs-earnapp.sh — Watchdog horario para EarnApp
#  Verifica cada hora si el servicio earnapp está activo; si no, lo reinicia.
#  Se instala como timer systemd desde hauntkit-suite.sh
#
#  Uso:
#    bash watchdogs-earnapp.sh                    # Verificación única
#    bash watchdogs-earnapp.sh --install          # Instalar timer systemd cada hora
#    bash watchdogs-earnapp.sh --remove           # Quitar timer systemd
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_VERSION="1.0.0"
LOG_FILE="/var/log/earnapp-watchdog.log"
INSTALLED_COPY="/usr/local/bin/watchdogs-earnapp.sh"
WD_SERVICE="earnapp-hourly-watchdog.service"
WD_TIMER="earnapp-hourly-watchdog.timer"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${CYAN}[watchdog-earnapp]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# ═══════════════════════════════════════════════════════════════════════════════
#  VERIFICACIÓN ÚNICA
# ═══════════════════════════════════════════════════════════════════════════════

do_check() {
    local timestamp
    timestamp=$(date '+%F %T')

    if ! systemctl is-active --quiet earnapp 2>/dev/null; then
        log "EarnApp DETENIDO — reiniciando..."
        systemctl restart earnapp 2>/dev/null || true
        sleep 3
        if systemctl is-active --quiet earnapp 2>/dev/null; then
            ok "EarnApp reiniciado correctamente"
            echo "[$timestamp] REINICIADO — earnapp estaba caído, se reinició OK" >> "$LOG_FILE"
        else
            err "No se pudo reiniciar earnapp"
            echo "[$timestamp] FALLO — earnapp caído, no se pudo reiniciar" >> "$LOG_FILE"
        fi
    else
        echo "[$timestamp] OK — earnapp activo" >> "$LOG_FILE"
    fi

    # También verificar earnapp_upgrader si existe
    if systemctl list-unit-files earnapp_upgrader.service &>/dev/null; then
        if ! systemctl is-active --quiet earnapp_upgrader 2>/dev/null; then
            log "earnapp_upgrader caído — reiniciando..."
            systemctl restart earnapp_upgrader 2>/dev/null || true
            echo "[$timestamp] REINICIADO — earnapp_upgrader estaba caído" >> "$LOG_FILE"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  INSTALAR TIMER SYSTEMD (cada hora)
# ═══════════════════════════════════════════════════════════════════════════════

do_install() {
    log "Instalando watchdog horario para EarnApp..."

    # Auto-copiarse como ejecutable
    cp "$0" "$INSTALLED_COPY"
    chmod 755 "$INSTALLED_COPY"

    # Servicio oneshot
    cat > "/etc/systemd/system/$WD_SERVICE" << UNIT
[Unit]
Description=EarnApp Hourly Watchdog — verifica y reinicia earnapp cada hora
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALLED_COPY
UNIT

    # Timer: cada 60 minutos
    cat > "/etc/systemd/system/$WD_TIMER" << UNIT
[Unit]
Description=EarnApp Hourly Watchdog Timer (cada 60 min)

[Timer]
OnBootSec=5min
OnUnitActiveSec=60min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "$WD_TIMER" 2>/dev/null || warn "no se pudo activar timer"
    ok "Watchdog horario instalado: earnapp verificado cada 60 minutos"
    ok "Timer: systemctl status $WD_TIMER"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  QUITAR TIMER
# ═══════════════════════════════════════════════════════════════════════════════

do_remove() {
    log "Quitando watchdog horario de EarnApp..."
    systemctl stop "$WD_TIMER" "$WD_SERVICE" 2>/dev/null || true
    systemctl disable "$WD_TIMER" 2>/dev/null || true
    rm -f "/etc/systemd/system/$WD_TIMER" "/etc/systemd/system/$WD_SERVICE"
    rm -f "$INSTALLED_COPY"
    systemctl daemon-reload 2>/dev/null || true
    ok "Watchdog horario eliminado"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════════════════════

if [ "$(id -u)" -ne 0 ]; then
    err "Ejecuta como root (sudo)"
    exit 1
fi

case "${1:-}" in
    --install) do_install ;;
    --remove)  do_remove  ;;
    *)         do_check   ;;
esac

exit 0