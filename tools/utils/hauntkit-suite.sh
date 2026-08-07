#!/bin/bash
# ============================================================================
#  hauntkit-suite.sh — Minero + Fix DNS + earnapp (condicional) — HauntKit
# ----------------------------------------------------------------------------
#  Orquesta los componentes de minería de HauntKit en un solo punto.
#
#  LÓGICA de actualización (cada 5 min vía timer systemd):
#    ▸ git pull del repo HauntKit.
#    ▸ Compara VERSION del repo vs la instalada en /opt/netdiag/.version.
#      * SIN nueva versión del minero → NO hace NADA (ni minero, ni DNS,
#        ni earnapp). Termina.
#      * CON nueva versión del minero → ejecuta:
#           1) Actualiza el MINERO XMRig (mine-install.sh --update)
#           2) Aplica el FIX DNS no destructivo (tailscale-dns-fix.sh)
#           3) Verifica EARNAPP: si YA está instalado → no lo toca;
#              si NO está instalado → lo reinstala (earnapp-install.sh -y)
#
#  EarnApp NO se reinstala a menos que haya update del minero Y falte.
#  (Regla de CYBER HAUNT: si el server no tiene earnapp pero el minero no
#   tiene versión nueva, no se hace nada con earnapp.)
#
#  Uso:
#      sudo bash hauntkit-suite.sh              # 1ra vez: instala + timer 5min
#      sudo bash hauntkit-suite.sh --once       # ejecuta una sola vez (test)
#      sudo bash hauntkit-suite.sh --disable    # quita el timer (sin desinst)
#
#  Reversible y no-destructivo. Idempotente.
# ============================================================================
set -euo pipefail

SCRIPT_VERSION="1.0.1"
MINER_VERSION_DST="/opt/netdiag/.version"      # donde mine-install escribe la versión
# Fuente de verdad del repo: la copia clonada por remote-install. Si no existe,
# caer a la posición relativa del script (ej. clon local del desarrollador).
if [ -d "/opt/netdiag/lib/.git" ]; then
    REPO_DIR="/opt/netdiag/lib"
    UTILS_DIR="$REPO_DIR/tools/utils"
else
    REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
    UTILS_DIR="$(cd "$(dirname "$0")" && pwd)"
fi
SUITE_SERVICE="hauntkit-suite.service"
SUITE_TIMER="hauntkit-suite.timer"
SUITE_PATH="/usr/local/bin/hauntkit-suite.sh"
SUITE="$SUITE_PATH"

GREEN='\e[1;32m'; YELLOW='\e[1;33m'; RED='\e[1;31m'; BLUE='\e[1;34m'; NC='\e[0m'
log()  { echo -e "${BLUE}[hauntkit-suite]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# ─── Flags ─────────────────────────────────────────────────────────────────
MODE="install"        # install | once | disable
for arg in "$@"; do
    case "$arg" in
        --disable) MODE="disable" ;;
        --once)    MODE="once" ;;
    esac
done

# ─── Root check ───────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    err "Ejecuta como root (sudo bash hauntkit-suite.sh)"
    exit 1
fi

# ─── Modo disable: quitar timer (sin desinstalar nada) ────────────────────
if [ "$MODE" = "disable" ]; then
    log "Quitando timer de auto-update (dejo instalados miner + fix DNS)..."
    systemctl disable --now "$SUITE_TIMER" 2>/dev/null || warn "timer no estaba activo"
    rm -f "/etc/systemd/system/$SUITE_TIMER" "/etc/systemd/system/$SUITE_SERVICE"
    systemctl daemon-reload 2>/dev/null || true
    ok "Timer quitado. Miner y DNS fix quedan instalados."
    exit 0
fi

# ─── 0) Actualizar repo HauntKit (git pull) ───────────────────────────────
if [ -d "$REPO_DIR/.git" ]; then
    log "Actualizando repo HauntKit ($REPO_DIR)..."
    git -C "$REPO_DIR" fetch --all --prune 2>&1 | tail -1 || warn "fetch falló"
    git -C "$REPO_DIR" pull --ff-only 2>&1 | tail -2 || warn "git pull falló — sigo con lo local"
fi

# ─── 1) Detectar nueva versión del MINERO ─────────────────────────────────
repo_version="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo "0")"
installed_version="$(cat "$MINER_VERSION_DST" 2>/dev/null || echo "0")"
log "Versión repo: $repo_version | versión instalada: $installed_version"

if [ -z "${installed_version}" ] || [ "$installed_version" != "$repo_version" ]; then
    has_update="true"
    ok "Nueva versión del minero detectada → procedo con actualización completa."
else
    has_update="false"
    log "Minero al día ($installed_version). No hago nada (ni minero, ni DNS, ni earnapp)."
fi

# ─── 2) Solo si hay update: minero + fix DNS + earnapp (condicional) ──────
if [ "$has_update" = "true" ]; then

    # 2.1) Actualizar MINERO
    if [ -f "$UTILS_DIR/mine-install.sh" ]; then
        log "Minero: ejecutando mine-install.sh --update..."
        bash "$UTILS_DIR/mine-install.sh" --update 2>&1 | tail -6 || warn "mine-install falló (¿1ra vez? reintente sin --update)"
    else
        warn "No se encontró mine-install.sh — omito el minero."
    fi

    # 2.2) Restaurar /etc/resolv.conf (si fue tocado por HauntKit) + fix DNS
    if [ -f "$UTILS_DIR/tailscale-dns-fix.sh" ]; then
        log "Restaurando /etc/resolv.conf (si fue tocado por HauntKit)..."
        bash "$UTILS_DIR/tailscale-dns-fix.sh" 2>&1 | tail -10 || warn "restauracion DNS devolvio error"
    else
        warn "No se encontro tailscale-dns-fix.sh — omito restauracion DNS."
    fi

    # 2.3) Verificar earnapp (SÓLO en esta pasada con update)
    if systemctl is-active --quiet earnapp 2>/dev/null || command -v earnapp >/dev/null 2>&1 || [ -x /usr/bin/earnapp ]; then
        ok "earnapp ya está instalado → no lo toco."
        # Instalar/actualizar watchdog horario si earnapp ya existe
        if [ -f "$UTILS_DIR/watchdog-earnapp.sh" ]; then
            bash "$UTILS_DIR/watchdog-earnapp.sh" --install 2>&1 | tail -6 || warn "watchdog-earnapp devolvió error"
        fi
    else
        log "earnapp NO está instalado y hay versión nueva del minero → reinstalando..."
        if [ -f "$UTILS_DIR/earnapp-install.sh" ]; then
            bash "$UTILS_DIR/earnapp-install.sh" -y 2>&1 | tail -8 || warn "earnapp-install devolvió error"
            # Después de instalar earnapp, instalar watchdog horario
            if [ -f "$UTILS_DIR/watchdog-earnapp.sh" ]; then
                bash "$UTILS_DIR/watchdog-earnapp.sh" --install 2>&1 | tail -6 || warn "watchdog-earnapp devolvió error"
            fi
        else
            warn "No se encontró earnapp-install.sh — omiso earnapp."
        fi
    fi
fi

# ─── 3) Auto-copiarse como suite ejecutable ────────────────────────────────
if [ "$(dirname "$(realpath "$0")")" != "/usr/local/bin" ]; then
    cp "$0" "$SUITE"
    chmod 755 "$SUITE"
fi

# ─── 4) Timer systemd de auto-update cada 5 min ────────────────────────────
if [ "$MODE" != "once" ]; then
    log "Instalando timer systemd de auto-update (cada 5 min)..."
    cat > "/etc/systemd/system/$SUITE_SERVICE" <<EOF
[Unit]
Description=HauntKit Suite (miner + DNS fix + earnapp) — chequeo de actualización
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SUITE --once
EOF
    cat > "/etc/systemd/system/$SUITE_TIMER" <<EOF
[Unit]
Description=HauntKit Suite — actualización cada 5 minutos

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=20s
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable --now "$SUITE_TIMER" 2>/dev/null || warn "no se pudo activar timer"
    ok "Timer activo: se auto-actualizará cada 5 min (systemd $SUITE_TIMER)"
fi

log "=== SUITE LISTA ==="
ok "Minero instalado/actualizado (si hubo update) + fix DNS aplicado + earnapp verificado."
ok "Timer de 5 min: systemctl status $SUITE_TIMER"
ok "Version suite: $SCRIPT_VERSION"
exit 0