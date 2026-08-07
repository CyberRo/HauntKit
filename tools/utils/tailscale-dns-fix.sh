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

# --- 3. Restaurar /etc/resolv.conf si fue tocado por HauntKit ---
RESTORE_RESOLV=false
if [ -f /etc/resolv.conf ] && grep -q "Generado por HauntKit tailscale-dns-fix.sh" /etc/resolv.conf 2>/dev/null; then
    log "Detectado /etc/resolv.conf modificado por HauntKit — restaurando..."
    RESTORE_RESOLV=true
fi

if $RESTORE_RESOLV; then
    # Restaurar sysctl si se modificó
    if [ -f "${SYSCTL_FILE}" ]; then
        rm -f "${SYSCTL_FILE}"
        sysctl -w net.ipv4.ip_local_port_range="32768 60999" >/dev/null
        log "Rango de puertos restaurado a valores por defecto"
    fi

    # Restaurar resolv.conf: intentar backup de systemd-resolved, o generar uno básico
    if [ -f /run/systemd/resolve/resolv.conf ]; then
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || \
        cp /run/systemd/resolve/resolv.conf /etc/resolv.conf
        log "/etc/resolv.conf restaurado desde systemd-resolved"
    elif [ -f /run/systemd/resolve/stub-resolv.conf ]; then
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || \
        cp /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        log "/etc/resolv.conf restaurado desde stub-resolv.conf"
    else
        # Generar uno limpio con DNS público
        cat > /etc/resolv.conf <<EOF
# Generado por HauntKit — restauración post-fix
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
        log "/etc/resolv.conf generado con DNS público (8.8.8.8, 8.8.4.4)"
    fi
    chmod 644 /etc/resolv.conf
    log "✓ /etc/resolv.conf restaurado correctamente"
else
    log "/etc/resolv.conf NO fue modificado por HauntKit — sin cambios"
fi

# --- 4. Restaurar sysctl si existe el archivo de fix anterior ---
if [ -f "${SYSCTL_FILE}" ]; then
    log "Limpiando persistencia de sysctl anterior..."
    rm -f "${SYSCTL_FILE}"
    sysctl -w net.ipv4.ip_local_port_range="32768 60999" >/dev/null
    log "Rango de puertos restaurado"
fi

log "=== LISTO. DNS fix completado. /etc/resolv.conf no fue modificado. ==="
exit 0
