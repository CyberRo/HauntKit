#!/usr/bin/env bash
# ============================================================================
#  iniciar-ia.sh — Script robusto de reinicio para Claude Code (Spectre)
#  Diseñado para eliminar puntos de congelamiento y garantizar recuperación
# ============================================================================
set -euo pipefail

# ---------- Configuración ----------
FCC_PORT=8082
FCC_HOST="127.0.0.1"
FCC_URL="http://${FCC_HOST}:${FCC_PORT}"
FCC_TOKEN="freecc"
MAX_STARTUP_WAIT=30  # segundos máximo para esperar el proxy
HEALTH_CHECK_INTERVAL=2  # segundos entre checks
LOG_FILE="/tmp/fcc-server.log"
CLAUDE_CODE_DIR="$HOME/free-claude-code"
UV_BIN="$HOME/.local/bin/uv"

# ---------- Colores para output ----------
RED='\033[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[1;33m'
BLUE='\e[0;34m'
CYAN='\e[0;36m'
NC='\e[0m'  # No Color

log()  { echo -e "${CYAN}[ia-restart]${NC} $*"; }
success() { echo -e "${GREEN}[ia-restart]${NC} $*"; }
warning() { echo -e "${YELLOW}[ia-restart]${NC} $*"; }
error() { echo -e "${RED}[ia-restart]${NC} $*" >&2; }

# ---------- Funciones ----------

die() {
    error "$*"
    exit 1
}

cleanup_previous() {
    log "Cerrando proxies y procesos anteriores..."
    
    # Matar procesos relacionados con fcc-server
    pkill -f "fcc-server" 2>/dev/null || true
    pkill -f "uv run fcc-server" 2>/dev/null || true
    
    # Esperar a que los procesos terminen
    sleep 2
    
    # Matar forzadamente si aún están vivos
    pkill -9 -f "fcc-server" 2>/dev/null || true
    pkill -9 -f "uv run fcc-server" 2>/dev/null || true
    
    # Limpiar archivos de lock y estado
    rm -f "/tmp/fcc-server*.lock" 2>/dev/null || true
    rm -f "/tmp/uv-*.lock" 2>/dev/null || true
    
    # Liberar el puerto si está en uso por procesos zombi
    fuser -k "${FCC_PORT}/tcp" 2>/dev/null || true
    
    log "Limpieza de procesos completada."
}

check_proxy_health() {
    local max_attempts=$((MAX_STARTUP_WAIT / HEALTH_CHECK_INTERVAL))
    local attempt=1
    
    log "Esperando a que el proxy FCC esté listo (máx ${MAX_STARTUP_WAIT}s)..."
    
    while [ $attempt -le $max_attempts ]; do
        if curl -sSf --max-time 5 "${FCC_URL}/v1/models" \
           -H "Authorization: Bearer ${FCC_TOKEN}" >/dev/null 2>&1; then
            success "Proxy FCC está respondiendo correctamente en intento ${attempt}"
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            warning "Intento ${attempt}/${max_attempts} falló, reintentando en ${HEALTH_CHECK_INTERVAL}s..."
            sleep $HEALTH_CHECK_INTERVAL
        fi
        
        ((attempt++))
    done
    
    error "El proxy FCC no respondió después de ${MAX_STARTUP_WAIT} segundos"
    error "Últimas líneas del log:"
    tail -20 "${LOG_FILE}" 2>/dev/null || echo "No se pudo leer el log"
    return 1
}

start_proxy() {
    log "Iniciando servidor proxy FCC..."
    
    # Asegurarnos de estar en el directorio correcto
    cd "${CLAUDE_CODE_DIR}" || die "No se puede acceder a ${CLAUDE_CODE_DIR}"
    
    # Limpiar log anterior
    > "${LOG_FILE}"
    
    # Iniciar el servidor en background con nohup y mejor manejo de salida
    nohup "${UV_BIN}" run fcc-server \
        > "${LOG_FILE}" 2>&1 &
    
    FCC_PID=$!
    log "Servidor FCC iniciado con PID ${FCC_PID}"
    
    # Dar un pequeño tiempo para que el proceso se establezca
    sleep 2
    
    # Verificar que el proceso aún esté vivo
    if ! kill -0 "${FCC_PID}" 2>/dev/null; then
        error "El proceso FCC murió inmediatamente después de iniciar"
        error "Log de error:"
        tail -20 "${LOG_FILE}"
        return 1
    fi
    
    return 0
}

configure_environment() {
    log "Configurando variables de entorno..."
    
    export FCC_PORT="${FCC_PORT}"
    export CLAUDE_CODE_PROXY_URL="${FCC_URL}"
    export ANTHROPIC_BASE_URL="${FCC_URL}"
    export ANTHROPIC_AUTH_TOKEN="${FCC_TOKEN}"
    
    # También exportar para que los subprocess las hereden
    export FCC_PORT FCC_HOST FCC_URL FCC_TOKEN
    
    success "Variables de entorno configuradas:"
    log "  FCC_PORT=${FCC_PORT}"
    log "  CLAUDE_CODE_PROXY_URL=${FCC_URL}"
    log "  ANTHROPIC_BASE_URL=${FCC_URL}"
}

start_claude_code() {
    log "Iniciando Claude Code..."
    log "Nota: Puede tomar unos segundos en inicializarse completamente"
    
    # Ejecutar Claude Code - este proceso reemplazará al shell actual
    exec claude
}

# ---------- Main Execution ----------

main() {
    log "=== INICIANDO PROCESO DE REINICIO ROBUSTO PARA CLAUDE CODE (SPECTRE) ==="
    
    # Paso 1: Limpieza agresiva de procesos anteriores
    log "[1/5] Limpiando entorno previo..."
    cleanup_previous
    
    # Paso 2: Iniciar el proxy FCC
    log "[2/5] Iniciando servidor proxy..."
    start_proxy || die "Fallo al iniciar el servidor proxy FCC"
    
    # Paso 3: Verificar que el proxy esté saludable
    log "[3/5] Verificando salud del proxy..."
    check_proxy_health || die "El proxy FCC no alcanzó estado saludable"
    
    # Paso 4: Configurar entorno
    log "[4/5] Configurando entorno de ejecución..."
    configure_environment
    
    # Paso 5: Iniciar Claude Code
    log "[5/5] Lanzando Claude Code..."
    start_claude_code
    
    # Nunca deberíamos llegar aquí debido al exec en start_claude_code
    log "ERROR: Alcanzamos el punto final inesperado"
    return 1
}

# Ejecutar el main
main "$@"
