#!/bin/bash
# ════════════════════════════════════════════════════════
#  HauntKit — bump-version
#  Actualiza la versión de TODO el proyecto en un comando.
#  Aplica la MISMA versión al archivo VERSION (raíz) y a la
#  cabecera de todos los scripts que la muestran.
#  Uso: bash tools/utils/bump-version.sh <nueva_version>
# ════════════════════════════════════════════════════════

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─── Validar argumento ───
NEW_VERSION="${1:-}"
if [ -z "$NEW_VERSION" ]; then
    echo -e "${RED}[!] Uso: $0 <version>   (ej. 1.9.4)${NC}"
    exit 1
fi

# ─── Validar formato de versión (x.y.z) ───
if ! echo "$NEW_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo -e "${RED}[!] Versión inválida '$NEW_VERSION'. Debe ser MAJOR.MINOR.PATCH (ej. 1.9.4)${NC}"
    exit 1
fi

# ─── Repo root ───
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

VERSION_FILE="VERSION"
if [ ! -f "$VERSION_FILE" ]; then
    echo -e "${RED}[!] No se encuentra $VERSION_FILE en $ROOT${NC}"
    exit 1
fi

CURRENT="$(cat "$VERSION_FILE" | tr -d ' \n\r')"
echo -e "${CYAN}HauntKit bump: $CURRENT → $NEW_VERSION${NC}"
echo

# ─── 1) Actualizar VERSION (raíz) ───
echo "$NEW_VERSION" > "$VERSION_FILE"
echo -e "  ${GREEN}✓${NC} VERSION → $NEW_VERSION"

# ─── 2) Propagar a cabeceras de todos los scripts ───
# Busca patrones como 'v1.9.0' o '1.9.0' en las N primeras líneas de comentario
# de los scripts, y los reemplaza por la nueva versión.
UPDATED=0
while IFS= read -r file; do
    # sólo si menciona la versión actual en alguna cabecera
    if grep -qE "(v?)$CURRENT" "$file" 2>/dev/null; then
        # Reemplaza 'v<VERSION>' (ej. v1.9.0 -> v1.9.4)
        sed -i -E "s/v${CURRENT}/v${NEW_VERSION}/g" "$file" 2>/dev/null
        # Reemplaza '<VERSION>' sin prefijo (ej. 1.9.0 -> 1.9.4), pero no el VERSION propio
        sed -i -E "s/(^|[^.0-9])${CURRENT}([^.0-9]|$)/\1${NEW_VERSION}\2/g" "$file" 2>/dev/null
        echo -e "  ${GREEN}✓${NC} $file → $NEW_VERSION"
        UPDATED=$((UPDATED + 1))
    fi
done < <(find scripts tools -type f \( -name '*.sh' -o -name '*.conf' -o -name '*.md' \) 2>/dev/null)

if [ "$UPDATED" -eq 0 ]; then
    echo -e "  ${YELLOW}→ No se hallaron cabeceras con la versión $CURRENT en scripts/tools${NC} (solo VERSION actualizado)"
fi

echo
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ bump a $NEW_VERSION completo  ${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo
echo "  Revisa el diff y commitea:"
echo "  git add -A && git commit -m \"chore: bump v$NEW_VERSION\" && git push origin main"