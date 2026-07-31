#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  EarnApp — Instalador Automático v5.2.0
#  Sin servidor ni agente propio: instala el binario oficial de EarnApp,
#  se auto-actualiza desde GitHub, mantiene el nodo 24/7 (watchdog systemd)
#  y muestra el link de activación.
#
#  Características:
#    - Auto-update vía GitHub (marker file + chequeo cada N días)
#    - Watchdog systemd (timer cada 7 días): re-arranca el nodo si se cae,
#      refresca el link y actualiza el script instalado
#    - Blindaje del servicio (Restart=always + sin límite de reintentos)
#    - Verificación de conectividad antes de instalar
#    - Logging persistente en /var/log/earnapp-install.log
#    - Instalación en modo auto (-y) sin preguntas interactivas
#    - Captura robusta del link de activación (config, log y polling)
#    - Multi-distro (apt/yum/dnf/apk/pacman)
#    - Opciones --uninstall / --force / --watchdog
#
#  Uso:
#    curl -s https://raw.githubusercontent.com/CyberRo/HauntKit/main/tools/utils/earnapp-install.sh | bash
#    curl -s https://raw.githubusercontent.com/CyberRo/HauntKit/main/tools/utils/earnapp-install.sh | bash -s -- --uninstall
#    curl -s https://raw.githubusercontent.com/CyberRo/HauntKit/main/tools/utils/earnapp-install.sh | bash -s -- --force
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Conservar argumentos originales (para re-ejecución tras auto-update)
ORIGINAL_ARGS=("$@")

# ─── URLs por defecto (sobrescribir con env vars) ───
EARNINSTALL_URL="${EARNINSTALL_URL:-https://brightdata.com/static/earnapp/install.sh}"

# ─── Auto-update: fuente de verdad en GitHub ───
SCRIPT_VERSION="5.2.0"
GITHUB_RAW_URL="${GITHUB_RAW_URL:-https://raw.githubusercontent.com/CyberRo/HauntKit/main/tools/utils/earnapp-install.sh}"

# ─── Rutas fijas ───
LINK_FILE="/tmp/earnapp_link.txt"
TEMP_DIR="/tmp/ea_inst"
VERSION_FILE="/etc/earnapp_agent.version"
INSTALLED_COPY="/usr/local/bin/earnapp-install.sh"
WATCHDOG_TIMER="earnapp-watchdog.timer"
WATCHDOG_SERVICE="earnapp-watchdog.service"
LOG_FILE="/var/log/earnapp-install.log"
UPDATE_INTERVAL="${UPDATE_INTERVAL:-7}"

# ─── Flags de modo ───
UNINSTALL_MODE=false
FORCE_MODE=false
SKIP_UPDATE=false
FORCE_UPDATE=false
WATCHDOG_MODE=false

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

# ═══════════════════════════════════════════════════════════════════════════════
#  FUNCIONES BASE
# ═══════════════════════════════════════════════════════════════════════════════

log() {
    local level="$1" msg="$2"
    case "$level" in
        ok)   echo -e "  ${GREEN}✓${NC} $msg" ;;
        warn) echo -e "  ${YELLOW}⚠${NC} $msg" ;;
        err)  echo -e "  ${RED}✗${NC} $msg" ;;
        info) echo -e "  ${CYAN}→${NC} $msg" ;;
        *)    echo "  $msg" ;;
    esac
}

fail() {
    log err "$1"
    exit 1
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "Requiere permisos de root (sudo)"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  AUTO-UPDATE (marker file + intervalo de días)
# ═══════════════════════════════════════════════════════════════════════════════

ver_num() {
    # Convierte "X.Y.Z" a entero comparable (5.2.0 -> 50200)
    echo "${1:-0.0.0}" | awk -F. '{printf "%d%02d%02d", $1?$1:0, $2?$2:0, $3?$3:0}'
}

write_version_file() {
    # Nota: 2>/dev/null ANTES de > para silenciar el error de permiso sin root
    cat 2>/dev/null > "$VERSION_FILE" << EOF || true
INSTALLER_VERSION=$SCRIPT_VERSION
LAST_UPDATE_CHECK=$(date +%F)
EOF
    chmod 644 "$VERSION_FILE" 2>/dev/null || true
}

self_update() {
    # Re-ejecución tras auto-update: solo refrescar marker y seguir
    if [ "${_SELF_UPDATED:-0}" = "1" ]; then
        write_version_file
        return 0
    fi

    # Deshabilitado manualmente (--skip-update / SKIP_UPDATE=true)
    if [ "$SKIP_UPDATE" = "true" ]; then
        log info "Auto-update desactivado (--skip-update)"
        write_version_file
        return 0
    fi

    local installed_ver="" last_check="" days_ago remote_ver remote_num local_num

    # Leer marker file si existe
    if [ -f "$VERSION_FILE" ]; then
        installed_ver=$(grep -E '^INSTALLER_VERSION=' "$VERSION_FILE" 2>/dev/null | cut -d= -f2 | head -1 || true)
        last_check=$(grep -E '^LAST_UPDATE_CHECK=' "$VERSION_FILE" 2>/dev/null | cut -d= -f2 | head -1 || true)
    fi

    # ¿Check todavía vigente? (salvo --force-update)
    if [ "$FORCE_UPDATE" != "true" ] && [ -n "$last_check" ] && [ "$installed_ver" = "$SCRIPT_VERSION" ]; then
        days_ago=$(( ( $(date +%s) - $(date -d "$last_check" +%s 2>/dev/null || echo 0) ) / 86400 ))
        if [ "$days_ago" -lt "$UPDATE_INTERVAL" ]; then
            log info "Auto-update: revisado hace ${days_ago}d (cada ${UPDATE_INTERVAL}d) — skip"
            return 0
        fi
    fi

    # Fetch de la versión remota desde GitHub
    log info "Verificando actualizaciones en GitHub..."
    remote_ver=$(curl -fsSL --connect-timeout 10 --max-time 30 "$GITHUB_RAW_URL" 2>/dev/null \
        | grep -m1 -oP 'SCRIPT_VERSION="\K[^"]+' || true)

    # Sin conexión / versión ilegible → seguir con la local
    if [ -z "$remote_ver" ]; then
        log warn "No se pudo verificar actualización (sin conexión?) — continuando"
        write_version_file
        return 0
    fi

    local_num=$(ver_num "$SCRIPT_VERSION")
    remote_num=$(ver_num "$remote_ver")

    if [ "$remote_num" -le "$local_num" ]; then
        log ok "Versión actualizada (v$SCRIPT_VERSION)"
        write_version_file
        return 0
    fi

    # Hay versión más nueva → descargarla y re-ejecutar
    log info "Nueva versión disponible: v$remote_ver (actual: v$SCRIPT_VERSION)"
    local tmp_script
    tmp_script=$(mktemp "/tmp/earnapp-update.XXXXXX" 2>/dev/null || mktemp)
    if curl -fsSL --connect-timeout 15 --max-time 60 "$GITHUB_RAW_URL" -o "$tmp_script" 2>/dev/null \
       && [ -s "$tmp_script" ]; then
        chmod +x "$tmp_script"
        # Mantener la copia instalada del script sincronizada (para el watchdog)
        cp "$tmp_script" "$INSTALLED_COPY" 2>/dev/null || true
        log ok "Actualizando a v$remote_ver y re-ejecutando..."
        exec env _SELF_UPDATED=1 bash "$tmp_script" ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
    fi

    log warn "No se pudo descargar la actualización — continuando con v$SCRIPT_VERSION"
    write_version_file
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  LIMPIEZA Y SEÑALES
# ═══════════════════════════════════════════════════════════════════════════════

cleanup() {
    rm -rf "$TEMP_DIR" 2>/dev/null || true
    rm -f /tmp/ea_output.txt 2>/dev/null || true
}
trap cleanup EXIT
trap 'echo -e "\n${YELLOW}[!] Interrumpido por el usuario${NC}"; cleanup; exit 130' INT TERM

# ═══════════════════════════════════════════════════════════════════════════════
#  DETECCIÓN DE DISTRO
# ═══════════════════════════════════════════════════════════════════════════════

install_pkg() {
    local pkg="$1"
    if command -v apt &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" 2>/dev/null
    elif command -v yum &>/dev/null; then
        yum install -y -q "$pkg" 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y -q "$pkg" 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add -q "$pkg" 2>/dev/null
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm "$pkg" 2>/dev/null
    else
        return 1
    fi
}

update_pkg_index() {
    if command -v apt &>/dev/null; then
        apt-get update -qq 2>/dev/null || true
    elif command -v apk &>/dev/null; then
        apk update -q 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  VERIFICACIÓN DE CONECTIVIDAD
# ═══════════════════════════════════════════════════════════════════════════════

check_connectivity() {
    log info "Verificando conectividad..."
    if curl -fsSL --connect-timeout 10 --max-time 15 "https://cdn-earnapp.b-cdn.net" -o /dev/null 2>/dev/null; then
        log ok "Conectividad OK (CDN earnapp accesible)"
        return 0
    fi
    # Fallback: al menos hay internet general
    if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        log warn "CDN de earnapp no accesible, pero hay internet — continuando"
        return 0
    fi
    fail "Sin conexión a internet. Verifica la red del cliente."
}

# ═══════════════════════════════════════════════════════════════════════════════
#  ESPERA INTELIGENTE (polling)
# ═══════════════════════════════════════════════════════════════════════════════

wait_for_pid() {
    local pid="$1" timeout="${2:-60}" interval="${3:-1}"
    for i in $(seq 1 "$timeout"); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        sleep "$interval"
    done
    # Timeout: matar
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MATAR SOLO PROCESOS DE EARNAPP (seguro)
# ═══════════════════════════════════════════════════════════════════════════════

kill_earnapp_procs() {
    local killed=0
    for pid in $(pgrep -f "/usr/bin/earnapp" 2>/dev/null || true); do
        kill "$pid" 2>/dev/null && killed=$((killed + 1))
    done
    for pid in $(pgrep -f "earnapp_upgrader" 2>/dev/null || true); do
        kill "$pid" 2>/dev/null && killed=$((killed + 1))
    done
    sleep 2
    # Forzar los que queden
    for pid in $(pgrep -f "/usr/bin/earnapp" 2>/dev/null || true); do
        kill -9 "$pid" 2>/dev/null || true
    done
    for pid in $(pgrep -f "earnapp_upgrader" 2>/dev/null || true); do
        kill -9 "$pid" 2>/dev/null || true
    done
    return "$killed"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  BLINDAJE DEL SERVICIO (Restart=always)
# ═══════════════════════════════════════════════════════════════════════════════

ensure_service_robust() {
    local unit="/etc/systemd/system/earnapp.service"
    if [ -f "$unit" ]; then
        log info "Blindando servicio earnapp (Restart=always)..."
        mkdir -p /etc/systemd/system/earnapp.service.d
        cat > /etc/systemd/system/earnapp.service.d/override.conf << 'EOF'
[Service]
Restart=always
RestartSec=10
StartLimitIntervalSec=0
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart earnapp 2>/dev/null || true
        log ok "Servicio blindado (Restart=always, sin límite de reintentos)"
    else
        log warn "Unit earnapp.service no encontrado — se blindará en el siguiente watchdog"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
#  WATCHDOG (timer systemd cada 7 días)
# ═══════════════════════════════════════════════════════════════════════════════

install_watchdog() {
    log info "Instalando watchdog systemd (cada $UPDATE_INTERVAL días)..."
    mkdir -p /usr/local/bin

    # Copia local del script (la usa el watchdog; se auto-actualiza vía self_update)
    curl -fsSL --connect-timeout 15 --max-time 60 "$GITHUB_RAW_URL" -o "$INSTALLED_COPY" 2>/dev/null || true
    chmod +x "$INSTALLED_COPY" 2>/dev/null || true

    # Servicio oneshot que ejecuta el script en modo watchdog
    cat > "/etc/systemd/system/$WATCHDOG_SERVICE" << EOF
[Unit]
Description=EarnApp Watchdog — verifica y repara el nodo
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '$INSTALLED_COPY --watchdog >> $LOG_FILE 2>&1'
EOF

    # Timer: arranca 10min tras boot y luego cada UPDATE_INTERVAL días
    cat > "/etc/systemd/system/$WATCHDOG_TIMER" << EOF
[Unit]
Description=EarnApp Watchdog Timer (cada $UPDATE_INTERVAL días)

[Timer]
OnBootSec=10min
OnUnitActiveSec=${UPDATE_INTERVAL}d
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable "$WATCHDOG_TIMER" 2>/dev/null || true
    systemctl start "$WATCHDOG_TIMER" 2>/dev/null || true
    # Primer chequeo inmediato
    systemctl start "$WATCHDOG_SERVICE" 2>/dev/null || true
    log ok "Watchdog programado (primer chequeo en ~10min, luego cada ${UPDATE_INTERVAL}d)"
}

do_watchdog() {
    require_root
    log info "Watchdog: verificando estado de EarnApp..."

    local restarted=false
    for svc in earnapp earnapp_upgrader; do
        if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
            log warn "Servicio $svc caído — re-arrancando..."
            systemctl start "$svc" 2>/dev/null || true
            restarted=true
        fi
    done

    if [ "$restarted" = true ]; then
        log ok "Servicios re-arrancados"
        sleep 3
    else
        log ok "Servicios operativos"
    fi

    # Blindaje por si el instalador no lo dejó agresivo
    ensure_service_robust

    # Refrescar link
    local link
    link=$(get_earnapp_link)
    if [ -n "$link" ]; then
        echo "$link" > "$LINK_FILE" 2>/dev/null || true
        log ok "Link vigente: $link"
    fi

    write_version_file
    log ok "Watchdog completado — nodo operativo"
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  MODO DESINSTALAR
# ═══════════════════════════════════════════════════════════════════════════════

do_uninstall() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Desinstalando EarnApp             ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    require_root

    log info "Deteniendo servicios..."
    systemctl stop "$WATCHDOG_TIMER" "$WATCHDOG_SERVICE" 2>/dev/null || true
    systemctl disable "$WATCHDOG_TIMER" 2>/dev/null || true
    systemctl stop earnapp 2>/dev/null || true
    systemctl stop earnapp_upgrader 2>/dev/null || true
    systemctl disable earnapp 2>/dev/null || true
    systemctl disable earnapp_upgrader 2>/dev/null || true

    log info "Matando procesos..."
    kill_earnapp_procs

    log info "Eliminando archivos..."
    rm -f /etc/systemd/system/earnapp*.service
    rm -f /etc/systemd/system/earnapp*.timer
    rm -rf /etc/systemd/system/earnapp.service.d
    rm -rf "$VERSION_FILE" "$INSTALLED_COPY" "$LOG_FILE" /tmp/earnapp*.txt /tmp/ea_install.log
    systemctl daemon-reload 2>/dev/null || true

    # Desinstalar earnapp oficial si existe
    if [ -f /usr/bin/earnapp ]; then
        log info "Desinstalando EarnApp oficial..."
        /usr/bin/earnapp --uninstall 2>/dev/null || true
        rm -f /usr/bin/earnapp 2>/dev/null || true
    fi

    log ok "EarnApp desinstalado"
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  VALIDACIÓN DE DESCARGA
# ═══════════════════════════════════════════════════════════════════════════════

download_verify() {
    local url="$1" dest="$2" expected_hash="${3:-}"
    log info "Descargando: $(basename "$dest")..."

    if ! curl -fsSL --connect-timeout 15 --max-time 60 "$url" -o "$dest" 2>/dev/null; then
        return 1
    fi

    if [ ! -s "$dest" ]; then
        return 1
    fi

    # Verificar SHA256 si se proporcionó
    if [ -n "$expected_hash" ]; then
        local actual_hash
        actual_hash=$(sha256sum "$dest" | awk '{print $1}')
        if [ "$actual_hash" != "$expected_hash" ]; then
            rm -f "$dest"
            return 2
        fi
    fi

    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
#  CAPTURA DEL LINK DE ACTIVACIÓN
# ═══════════════════════════════════════════════════════════════════════════════

get_earnapp_link() {
    local link=""

    # 1) Config persistente (reinstalación conserva el nodo)
    [ -f /etc/earnapp/config ] && \
        link=$(grep -oP 'https://earnapp\.com/r/[a-zA-Z0-9_\-]+' /etc/earnapp/config 2>/dev/null | head -1)

    # 2) Log del instalador (instalación nueva)
    [ -z "$link" ] && [ -f /tmp/ea_install.log ] && \
        link=$(grep -oP 'https://earnapp\.com/r/[a-zA-Z0-9_\-]+' /tmp/ea_install.log 2>/dev/null | head -1)

    # 3) Preguntar al binario (varias formas, por si alguna lo muestra)
    if [ -z "$link" ] && [ -x /usr/bin/earnapp ]; then
        for cmd in "status" "--status" "daemon status"; do
            link=$(timeout 10 /usr/bin/earnapp $cmd 2>/dev/null \
                | grep -oP 'https://earnapp\.com/r/[a-zA-Z0-9_\-]+' | head -1 || true)
            [ -n "$link" ] && break
        done
    fi

    # 4) Polling: el daemon puede tardar en generar el link al primer arranque
    if [ -z "$link" ]; then
        log info "Esperando a que el daemon genere el link..."
        for i in $(seq 1 15); do
            [ -f /etc/earnapp/config ] && \
                link=$(grep -oP 'https://earnapp\.com/r/[a-zA-Z0-9_\-]+' /etc/earnapp/config 2>/dev/null | head -1)
            [ -n "$link" ] && break
            sleep 2
        done
    fi

    echo "$link"
}

# ═══════════════════════════════════════════════════════════════════════════════
#  INSTALACIÓN
# ═══════════════════════════════════════════════════════════════════════════════

do_install() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        EarnApp — Instalador v5.2.0       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    require_root

    # ─── PASO 1: LIMPIAR ───
    echo -e "\n${BOLD}[1/5]${NC} ${YELLOW}Limpiando instalación anterior...${NC}"

    systemctl stop "$WATCHDOG_TIMER" "$WATCHDOG_SERVICE" 2>/dev/null || true
    systemctl disable "$WATCHDOG_TIMER" 2>/dev/null || true
    systemctl stop earnapp 2>/dev/null || true
    systemctl stop earnapp_upgrader 2>/dev/null || true
    systemctl disable earnapp 2>/dev/null || true
    systemctl disable earnapp_upgrader 2>/dev/null || true

    kill_earnapp_procs || true
    sleep 1

    rm -f /etc/systemd/system/earnapp*.service 2>/dev/null || true
    rm -f /etc/systemd/system/earnapp*.timer 2>/dev/null || true
    rm -rf /etc/systemd/system/earnapp.service.d 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log ok "Limpieza completada"

    # ─── PASO 2: VERIFICAR (herramientas + conectividad) ───
    echo -e "\n${BOLD}[2/5]${NC} ${YELLOW}Verificando entorno...${NC}"

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        log info "curl/wget no encontrado, instalando curl..."
        update_pkg_index
        if ! install_pkg curl; then
            fail "No se pudo instalar curl. Instálalo manualmente y reintenta."
        fi
    fi

    check_connectivity
    log ok "Entorno listo"

    # ─── PASO 3: INSTALAR EARNAPP OFICIAL ───
    echo -e "\n${BOLD}[3/5]${NC} ${YELLOW}Instalando EarnApp oficial...${NC}"

    if [ -f /usr/bin/earnapp ] && [ "$FORCE_MODE" = false ]; then
        log ok "EarnApp ya instalado ($(/usr/bin/earnapp --version 2>/dev/null || true))"
    else
        mkdir -p "$TEMP_DIR"
        log info "Descargando instalador oficial..."

        if ! download_verify "$EARNINSTALL_URL" "$TEMP_DIR/install.sh"; then
            fail "No se pudo descargar el instalador oficial de EarnApp"
        fi

        log info "Ejecutando instalador oficial (-y auto)..."
        # -y activa el modo automático del instalador oficial (AUTO=1),
        # evita preguntas interactivas y el binario queda en /usr/bin/earnapp
        bash "$TEMP_DIR/install.sh" -y > /tmp/ea_install.log 2>&1 &
        INSTALLER_PID=$!

        # Esperar con timeout de 120s
        if wait_for_pid "$INSTALLER_PID" 120 5; then
            log ok "Instalador finalizado"
        else
            log warn "Instalador tomó más de 120s, el proceso puede seguir en background"
        fi

        # Verificar binario
        if [ ! -f /usr/bin/earnapp ]; then
            log err "Binario earnapp no encontrado. Últimas líneas del instalador:"
            tail -10 /tmp/ea_install.log 2>/dev/null || true
            if [ "$FORCE_MODE" = false ]; then
                fail "No se pudo instalar EarnApp"
            fi
        fi
    fi

    # Asegurar que el servicio esté activo
    if systemctl is-active --quiet earnapp 2>/dev/null; then
        log ok "Servicio earnapp activo"
    else
        log info "Arrancando servicio earnapp..."
        systemctl start earnapp 2>/dev/null || true
        sleep 2
    fi

    # ─── PASO 4: BLINDAR + WATCHDOG ───
    echo -e "\n${BOLD}[4/5]${NC} ${YELLOW}Configurando persistencia (24/7)...${NC}"

    ensure_service_robust
    install_watchdog

    # ─── PASO 5: CAPTURAR LINK DE ACTIVACIÓN ───
    echo -e "\n${BOLD}[5/5]${NC} ${YELLOW}Obteniendo link de activación...${NC}"

    LINK=$(get_earnapp_link)

    if [ -n "$LINK" ]; then
        echo "$LINK" > "$LINK_FILE"
        log ok "Link obtenido"
    else
        log warn "Link aún no disponible. Verifícalo luego con: /usr/bin/earnapp status"
        log info "O revisa tu cuenta en earnapp.com"
    fi

    # Refrescar marker de versión instalada
    write_version_file

    # ─── RESUMEN ───
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      INSTALACIÓN COMPLETADA             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  EarnApp:"
    echo "    Estado: $(systemctl is-active earnapp 2>/dev/null || echo '?')"
    echo "    Versión: $(/usr/bin/earnapp --version 2>/dev/null | head -1 || echo '?')"
    echo "    Watchdog: $(systemctl is-active $WATCHDOG_TIMER 2>/dev/null || echo '?')"
    echo ""

    if [ -n "$LINK" ]; then
        echo -e "  ${YELLOW}╔══════════════════════════════════════════════╗${NC}"
        echo -e "  ${YELLOW}║   ACTIVA TU NODO EN EARNAPP.COM CON ESTE LINK ║${NC}"
        echo -e "  ${YELLOW}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}$LINK${NC}"
        echo ""
        echo "  Abre este enlace, inicia sesión o crea tu cuenta,"
        echo "  y el nodo quedará vinculado automáticamente."
    fi

    echo ""
    echo -e "  ${YELLOW}💡 Para maximizar ganancias: ajusta el % de ancho de banda${NC}"
    echo -e "  ${YELLOW}   compartido en el panel de earnapp.com.${NC}"
    echo ""
    echo "  El nodo queda corriendo 24/7 y se repara solo cada 7 días (watchdog)."
    echo "--------------------------------------------------------------------"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
#  PARSEAR ARGUMENTOS
# ═══════════════════════════════════════════════════════════════════════════════

for arg in "$@"; do
    case "$arg" in
        --uninstall)    UNINSTALL_MODE=true ;;
        --force)        FORCE_MODE=true ;;
        --skip-update)  SKIP_UPDATE=true ;;
        --force-update) FORCE_UPDATE=true ;;
        --watchdog)     WATCHDOG_MODE=true ;;
        --version|-V)
            echo "EarnApp Installer v$SCRIPT_VERSION"
            exit 0
            ;;
        --help|-h)
            echo "Uso: curl -s https://raw.githubusercontent.com/CyberRo/HauntKit/main/tools/utils/earnapp-install.sh | bash [--] [opciones]"
            echo ""
            echo "Opciones:"
            echo "  --uninstall     Desinstalar completa"
            echo "  --force         Reinstalar aunque ya exista"
            echo "  --skip-update   Saltar la verificación de actualizaciones"
            echo "  --force-update  Forzar verificación aunque esté reciente"
            echo "  --watchdog      Modo interno del timer (verifica y repara el nodo)"
            echo "  --version       Mostrar versión del instalador"
            echo ""
            echo "Variables de entorno:"
            echo "  EARNINSTALL_URL URL del instalador oficial de EarnApp"
            echo "  UPDATE_INTERVAL Días entre revisiones de auto-update y watchdog (defecto: 7)"
            echo "  GITHUB_RAW_URL  URL raw del instalador en GitHub"
            exit 0
            ;;
    esac
done

# ═══════════════════════════════════════════════════════════════════════════════
#  EJECUTAR
# ═══════════════════════════════════════════════════════════════════════════════

# Verificar auto-update antes de cualquier acción
self_update

if $UNINSTALL_MODE; then
    do_uninstall
fi

if $WATCHDOG_MODE; then
    do_watchdog
fi

do_install
