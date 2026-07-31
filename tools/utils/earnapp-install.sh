#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
#  EarnApp Panel — Instalador Automático v5 (mejorado)
#  Mejoras sobre v4.2 original:
#    - Señalización (trap) para limpieza en Ctrl+C
#    - Multi-distro: detecta apt/yum/apk/pacman automáticamente
#    - Polling en vez de sleep hardcodeados
#    - SHA256 de descargas para verificar integridad
#    - Limpieza automática de temporales
#    - URLs configurables por variable de entorno
#    - Opción --uninstall
#    - Colores y logging con timestamp
#    - Mata solo procesos propios (no por nombre genérico)
#    - Auto-update vía GitHub (marker file + chequeo cada N días)
#
#  Uso:
#    curl -s http://181.206.125.11:8090/panel/install_agent.sh | bash
#    curl -s http://181.206.125.11:8090/panel/install_agent.sh | bash -s -- --uninstall
#    curl -s http://181.206.125.11:8090/panel/install_agent.sh | bash -s -- --force
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# Conservar argumentos originales (para re-ejecución tras auto-update)
ORIGINAL_ARGS=("$@")

# ─── URLs por defecto (sobrescribir con env vars) ───
PANEL_URL="${PANEL_URL:-http://181.206.125.11:8090/panel}"
AGENT_URL="${AGENT_URL:-http://181.206.125.11:8090/earnapp_agent.py}"
EARNINSTALL_URL="${EARNINSTALL_URL:-https://brightdata.com/static/earnapp/install.sh}"

# ─── Auto-update: fuente de verdad en GitHub ───
SCRIPT_VERSION="5.0.0"
GITHUB_RAW_URL="${GITHUB_RAW_URL:-https://raw.githubusercontent.com/CyberRo/HauntKit/main/tools/utils/earnapp-install.sh}"

# ─── SHA256 esperado del agente Python (opcional, si se conoce) ───
AGENT_EXPECTED_HASH=""

# ─── Rutas fijas ───
AGENT_DEST="/usr/local/bin/earnapp_agent.py"
CONFIG_FILE="/etc/earnapp_agent.json"
SERVICE_NAME="earnapp-agent"
LINK_FILE="/tmp/earnapp_link.txt"
TEMP_DIR="/tmp/ea_inst"
VERSION_FILE="/etc/earnapp_agent.version"
UPDATE_INTERVAL="${UPDATE_INTERVAL:-7}"

# ─── Flags de modo ───
UNINSTALL_MODE=false
FORCE_MODE=false
SKIP_UPDATE=false
FORCE_UPDATE=false

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
    # Convierte "X.Y.Z" a entero comparable (5.0.0 -> 50000)
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

wait_for_file() {
    local file="$1" timeout="${2:-30}"
    for i in $(seq 1 "$timeout"); do
        [ -f "$file" ] && return 0
        sleep 1
    done
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
    for pid in $(pgrep -f "earnapp_agent.py" 2>/dev/null || true); do
        kill "$pid" 2>/dev/null && killed=$((killed + 1))
    done
    sleep 2
    # Forzar los que queden
    for pid in $(pgrep -f "/usr/bin/earnapp" 2>/dev/null || true); do
        kill -9 "$pid" 2>/dev/null || true
    done
    for pid in $(pgrep -f "earnapp_agent.py" 2>/dev/null || true); do
        kill -9 "$pid" 2>/dev/null || true
    done
    return "$killed"
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
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl stop earnapp 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable earnapp 2>/dev/null || true

    log info "Matando procesos..."
    kill_earnapp_procs

    log info "Eliminando archivos..."
    rm -f /etc/systemd/system/earnapp*.service
    rm -rf "$AGENT_DEST" "$CONFIG_FILE" "$VERSION_FILE" /var/log/earnapp_agent.log* /tmp/earnapp*.txt
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
#  INSTALACIÓN
# ═══════════════════════════════════════════════════════════════════════════════

do_install() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║     EarnApp Panel — Instalador v5       ║${NC}"
    echo -e "${CYAN}║     Panel: $PANEL_URL${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""

    require_root

    # ─── PASO 1: LIMPIAR ───
    echo -e "\n${BOLD}[1/5]${NC} ${YELLOW}Limpiando instalación anterior...${NC}"

    # Solo detener servicios previos
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl stop earnapp 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable earnapp 2>/dev/null || true

    kill_earnapp_procs || true
    sleep 1

    rm -f /etc/systemd/system/earnapp*.service 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log ok "Limpieza completada"

    # ─── PASO 2: DEPENDENCIAS ───
    echo -e "\n${BOLD}[2/5]${NC} ${YELLOW}Instalando dependencias...${NC}"

    if ! command -v python3 &>/dev/null; then
        log info "Python3 no encontrado, instalando..."
        update_pkg_index
        if ! install_pkg python3; then
            fail "No se pudo instalar python3. Instálalo manualmente y reintenta."
        fi
    fi

    # pip + requests
    if ! python3 -c "import requests" 2>/dev/null; then
        log info "Instalando requests..."
        python3 -m pip install requests -q 2>/dev/null \
            || python3 -m pip install requests --break-system-packages -q 2>/dev/null \
            || log warn "No se pudo instalar requests (se instalará más tarde)"
    fi

    log ok "Dependencias listas"

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

        log info "Ejecutando instalador oficial..."

        # El instalador oficial de earnapp es interactivo
        # Enviamos "yes" a las preguntas usando un enfoque controlado
        # Redirigir a expect-like para evitar sleeps hardcodeados
        {
            echo "yes"
            sleep 2
            echo "yes"
        } | bash "$TEMP_DIR/install.sh" > /tmp/ea_install.log 2>&1 &
        INSTALLER_PID=$!

        # Esperar con timeout de 120s en vez de sleep 60
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

    # ─── PASO 4: CAPTURAR LINK DE REFERRAL ───
    echo -e "\n${BOLD}[4/5]${NC} ${YELLOW}Capturando link...${NC}"

    LINK=""

    # Buscar en el log del instalador
    if [ -f /tmp/ea_install.log ]; then
        LINK=$(grep -oP 'https://earnapp\.com/r/sdk-node-[a-zA-Z0-9]+' /tmp/ea_install.log 2>/dev/null | head -1)
    fi

    # Buscar en config de earnapp
    if [ -z "$LINK" ] && [ -f /etc/earnapp/config ]; then
        LINK=$(grep -oP 'https://earnapp\.com/r/sdk-node-[a-zA-Z0-9]+' /etc/earnapp/config 2>/dev/null | head -1)
    fi

    if [ -n "$LINK" ]; then
        echo "$LINK" > "$LINK_FILE"
        log ok "Link capturado: ${CYAN}$LINK${NC}"
    else
        log warn "Link no encontrado en logs. Se detectará automáticamente al conectar."
        log info "Puedes verificarlo luego con: cat $LINK_FILE"
    fi

    # ─── PASO 5: INSTALAR AGENTE PYTHON ───
    echo -e "\n${BOLD}[5/5]${NC} ${YELLOW}Instalando agente...${NC}"

    if ! download_verify "$AGENT_URL" "$AGENT_DEST" "$AGENT_EXPECTED_HASH"; then
        fail "No se pudo descargar el agente desde $AGENT_URL"
    fi
    chmod +x "$AGENT_DEST"

    # Validar sintaxis Python
    if ! python3 -c "import ast; ast.parse(open('${AGENT_DEST}').read())" 2>/dev/null; then
        rm -f "$AGENT_DEST"
        fail "El agente descargado no es un Python válido"
    fi
    log ok "Agente validado (sintaxis correcta)"

    # Crear servicio systemd
    cat > "/etc/systemd/system/${SERVICE_NAME}.service" << 'SERVICE'
[Unit]
Description=EarnApp Panel Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/tmp
ExecStart=/usr/bin/python3 /usr/local/bin/earnapp_agent.py
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal
Environment="PYTHONUNBUFFERED=1"

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl start "$SERVICE_NAME"

    # Verificar con polling
    for i in 1 2 3; do
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            log ok "Servicio iniciado"
            break
        fi
        sleep 1
    done

    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log err "El agente no inició. Últimas líneas del log:"
        journalctl -u "$SERVICE_NAME" -n 5 --no-pager 2>/dev/null || true
        exit 1
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
    echo ""
    echo "  Agente:"
    echo "    Estado: $(systemctl is-active ${SERVICE_NAME} 2>/dev/null || echo '?')"
    echo "    PID:    $(systemctl show -p MainPID -v ${SERVICE_NAME} 2>/dev/null | cut -d= -f2 || echo '?')"
    echo "    Config: $CONFIG_FILE"
    echo ""

    if [ -f "$LINK_FILE" ]; then
        echo -e "  Link: ${CYAN}$(cat "$LINK_FILE")${NC}"
        echo ""
    fi

    echo -e "  ${YELLOW}En 60 segundos aparecerá en el panel${NC}"
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
        --version|-V)
            echo "EarnApp Panel Installer v$SCRIPT_VERSION"
            exit 0
            ;;
        --help|-h)
            echo "Uso: curl -s http://181.206.125.11:8090/panel/install_agent.sh | bash [--] [opciones]"
            echo ""
            echo "Opciones:"
            echo "  --uninstall     Desinstalar completa"
            echo "  --force         Reinstalar aunque ya exista"
            echo "  --skip-update   Saltar la verificación de actualizaciones"
            echo "  --force-update  Forzar verificación aunque esté reciente"
            echo "  --version       Mostrar versión del instalador"
            echo ""
            echo "Variables de entorno:"
            echo "  PANEL_URL       URL del panel (defecto: http://95.111.231.63:8090/panel)"
            echo "  AGENT_URL       URL del agente Python (defecto: http://95.111.231.63:8090/earnapp_agent.py)"
            echo "  UPDATE_INTERVAL Días entre revisiones de auto-update (defecto: 7)"
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

do_install
