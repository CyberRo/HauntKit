#!/bin/bash
# ============================================================================
#  tailscale-dns-fix.sh — Fix NO destructivo de DNS UDP para flota con Tailscale
#  HauntKit
# ----------------------------------------------------------------------------
#  PROBLEMA:
#    En servidores con Tailscale + earnapp, la resolución DNS externa
#    (pool de minería, GitHub, apt) falla. Causa raíz confirmada en campo:
#      - systemd-resolved + MagicDNS de Tailscale devuelve REFUSED para
#        dominios externos (pool, GitHub).
#      - earnapp abre ~650 sockets UDP bound (estado UNCONN), pero NO es
#        la causa del bloqueo: ampliar puertos no arregla nada.
#    SOLUCIÓN (sin quitar Tailscale ni earnapp, sin hardcodear IPs):
#      - /etc/resolv.conf híbrido: MagicDNS (100.100.100.100) para la tailnet
#        + DNS público (8.8.8.8/8.8.4.4) para lo externo.
#      - tailscale set --accept-dns=false  → Tailscale no pisa resolv.conf.
#      - systemd-resolved desactivado (devolvía REFUSED).
#      - Amplía rango de puertos efímeros a 64k (defensa extra, reversible).
#    IDEMPOTENTE: seguro de re-ejecutar. No borra nada del sistema.
#    REVERSIBLE: ver sección "REVERTIR" al final.
# ============================================================================
set -euo pipefail

# --- Configuración ---------------------------------------------------------
MAGICDNS_IP="${MAGICDNS_IP:-100.100.100.100}"   # MagicDNS de Tailscale
PUB_DNS1="${PUB_DNS1:-8.8.8.8}"                 # DNS público principal
PUB_DNS2="${PUB_DNS2:-8.8.4.4}"                 # DNS público secundario
SEARCH_DOMAIN="${SEARCH_DOMAIN:-taild79c7.ts.net}" # tu tailnet suffix
SYSCTL_FILE="/etc/sysctl.d/99-dns-udp-fix.conf"

log()  { echo -e "\e[1;34m[tailscale-dns-fix]\e[0m $*"; }
warn() { echo -e "\e[1;33m[tailscale-dns-fix][warn]\e[0m $*"; }
err()  { echo -e "\e[1;31m[tailscale-dns-fix][error]\e[0m $*" >&2; }

# --- Comprobación de root --------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    err "Ejecuta como root (sudo)."
    exit 1
fi

log "=== Fix DNS UDP no destructivo (Tailscale + externo) ==="

# --- 1. Detectar si hay Tailscale instalado --------------------------------
if ! command -v tailscale >/dev/null 2>&1; then
    warn "Tailscale no está instalado en este host. Aún así aplico el resolv.conf híbrido (MagicDNS no estará, pero el DNS público sí)."
else
    log "Tailscale detectado. Desactivando --accept-dns para que no pise resolv.conf..."
    tailscale set --accept-dns=false 2>/dev/null || warn "tailscale set devolvió error (puede requerir 'tailscale up --accept-dns=false')."
fi

# --- 2. Desactivar systemd-resolved (devolvía REFUSED) ----------------------
if systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
    log "Desactivando systemd-resolved (causa REFUSED en dominios externos)..."
    systemctl disable --now systemd-resolved 2>/dev/null || warn "No se pudo desactivar systemd-resolved (puede no estar activo)."
else
    log "systemd-resolved no está instalado. OK."
fi

# --- 3. Escribir /etc/resolv.conf híbrido ----------------------------------
log "Escribiendo /etc/resolv.conf híbrido (MagicDNS + DNS público)..."
cat > /etc/resolv.conf <<EOF
# Generado por HauntKit tailscale-dns-fix.sh
# MagicDNS de Tailscale resuelve la tailnet (.ts.net); DNS público resuelve el resto.
nameserver ${MAGICDNS_IP}
nameserver ${PUB_DNS1}
nameserver ${PUB_DNS2}
search ${SEARCH_DOMAIN}
EOF
echo "  Contenido:"
sed 's/^/    /' /etc/resolv.conf

# --- 4. Ampliar rango de puertos efímeros (defensa extra) ------------------
log "Ampliando rango de puertos efímeros a 1024-65535 (64k)..."
sysctl -w net.ipv4.ip_local_port_range="1024 65535" >/dev/null
echo "net.ipv4.ip_local_port_range=1024 65535" > "${SYSCTL_FILE}"
echo "  Persistido en ${SYSCTL_FILE}"

# --- 5. Verificación --------------------------------------------------------
log "Verificando resolución DNS (pool, GitHub, tailnet)..."
verify() {
    local label="$1" host="$2"
    local ip
    ip=$(getent hosts "${host}" | awk '{print $1}' | head -1)
    if [ -n "${ip}" ]; then
        echo "  ✓ ${label}: ${ip}"
    else
        echo "  ✗ ${label}: NO resuelve"
        return 1
    fi
}
verify "pool          " "gulf.moneroocean.stream" || true
verify "github        " "github.com"              || true
# tailnet: usa el DNSName real de Tailscale (Self) si está disponible
TS_OWN=""
if command -v tailscale >/dev/null 2>&1; then
    TS_OWN=$(tailscale status --json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    n = d.get("Self", {}).get("DNSName", "")
    print(n.rstrip("."))
except Exception:
    print("")
' 2>/dev/null || true)
fi
if [ -n "${TS_OWN}" ]; then
    verify "tailnet (.ts.) " "${TS_OWN}" || true
else
    verify "tailnet (.ts.) " "$(hostname).${SEARCH_DOMAIN}" || true
fi

log "=== LISTO. Fix aplicado. No se quitó Tailscale ni earnapp. ==="
log "Para REVERTIR:"
log "  tailscale set --accept-dns=true"
log "  systemctl enable --now systemd-resolved"
log "  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf"
log "  rm -f ${SYSCTL_FILE} && sysctl -w net.ipv4.ip_local_port_range=32768\ 60999"
exit 0
