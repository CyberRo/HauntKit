#!/bin/bash
# =====================================================
# HauntKit — Script de instalación
# Cyber Haunt & Spectre Arsenal
# =====================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║         Instalando HauntKit...           ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

HAUNTKIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Hacer ejecutables los scripts
chmod +x "$HAUNTKIT_DIR"/scripts/*.sh 2>/dev/null
chmod +x "$HAUNTKIT_DIR"/tools/**/*.sh 2>/dev/null

# Verificar Python
if ! command -v python3 &>/dev/null; then
    echo -e "${RED}[!] Python3 no está instalado${NC}"
    exit 1
fi
echo -e "${GREEN}[✓] Python3 detectado${NC}"

# Crear enlace simbólico en /usr/local/bin
if [ -w /usr/local/bin ]; then
    ln -sf "$HAUNTKIT_DIR/haunt.py" /usr/local/bin/haunt
    chmod +x /usr/local/bin/haunt
    echo -e "${GREEN}[✓] Enlace creado: haunt -> /usr/local/bin/haunt${NC}"
else
    echo -e "${RED}[!] No hay permisos para crear enlace en /usr/local/bin${NC}"
    echo "    Ejecuta: sudo ln -sf $HAUNTKIT_DIR/haunt.py /usr/local/bin/haunt"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     HauntKit instalado correctamente     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo "Usa: haunt --list"
