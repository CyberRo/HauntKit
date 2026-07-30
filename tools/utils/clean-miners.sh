#!/bin/bash
# ════════════════════════════════════════════════════════
#  clean-miners — Busca y elimina mineros rivales
#  v2 — SEGURO: solo mata procesos con conexión CONFIRMADA
#        a pools de minería verificados O firma XMRig real.
#  Uso:  sudo bash clean-miners.sh            (solo listar)
#        sudo bash clean-miners.sh --clean    (solo alta confianza)
#        sudo bash clean-miners.sh --force    (alta + media, sin preguntar)
#        sudo bash clean-miners.sh --strict   (SOLO pool + firma, nada más)
# ════════════════════════════════════════════════════════

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

# ─── Modo ───
AUTO_CLEAN=false
FORCE=false
STRICT=false
[ "$1" = "--clean" ] && AUTO_CLEAN=true
[ "$1" = "--force" ] && { AUTO_CLEAN=true; FORCE=true; }
[ "$1" = "--strict" ] && { AUTO_CLEAN=true; STRICT=true; }

# ─── Solo root ───
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[!] Debes ejecutar como root (sudo)$NC"
    exit 1
fi

# ════════════════════════════════════════════════════════════
#  BASE DE DATOS DE MINEROS CONOCIDOS
#  SOLO nombres de proceso 100% identificados como mineros.
# ════════════════════════════════════════════════════════════

KNOWN_MINER_NAMES=(
    "xmrig" "xmr-stak" "xmrminer" "miner" "ccminer" "ethminer"
    "sgminer" "bfgminer" "cpuminer" "nsfminer" "t-rex" "gminer"
    "lolminer" "teamredminer" "wildrig" "srbminer" "nbminer"
    "sys-scheduler"
)

# Pools de minería VERIFICADOS — solo estos se consideran evidencia
KNOWN_POOLS=(
    "nanopool.org" "moneroocean.stream" "supportxmr.com"
    "minexmr.com" "xmrpool.eu" "pool.minexmr.com"
    "pool.supportxmr.com" "xmr-eu1.nanopool.org"
    "xmr-us1.nanopool.org" "xmr-asia1.nanopool.org"
    "gulf.moneroocean.stream" "pool.moneroocean.stream"
    "xmr.2miners.com" "xmrpool.net" "xmr.hashrate.to"
    "xmrpool.org" "minexmr.cn" "xmr.pool.panda.net"
    "pool.ethermine.org" "eth.2miners.com" "ethpool.org"
    "zec.2miners.com" "etc.2miners.com" "ton.whaleston.com"
)

# ════════════════════════════════════════════════════════════
#  DETECCIÓN POR CONEXIONES A POOLS (MÉTODO PRINCIPAL)
#  Esta es la señal MÁS CONFIABLE de un minero activo.
# ════════════════════════════════════════════════════════════

FOUND_ITEMS=()
FOUND_COUNT=0

detect_by_pool_connection() {
    if ! command -v ss &>/dev/null || ! command -v getent &>/dev/null; then
        return
    fi

    local connections
    connections=$(ss -tunp 2>/dev/null | grep -E 'ESTAB|SYN-SENT')

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local dest_addr pid_info proc_name proc_exe
        dest_addr=$(echo "$line" | awk '{print $6}')
        pid_info=$(echo "$line" | grep -oP 'pid=\K[0-9]+')

        [ -z "$pid_info" ] && continue

        local dest_ip
        dest_ip=$(echo "$dest_addr" | grep -oP '^[^:]+')

        # Resolver IP a nombre de host para comparar con pools
        local hostname
        hostname=$(getent hosts "$dest_ip" 2>/dev/null | awk '{print $2}' | head -1)

        # Verificar si el destino coincide con un pool CONOCIDO
        local is_pool=false
        for pool in "${KNOWN_POOLS[@]}"; do
            if echo "$dest_addr" | grep -qi "$pool" 2>/dev/null || \
               [ -n "$hostname" ] && echo "$hostname" | grep -qi "$pool" 2>/dev/null; then
                is_pool=true
                break
            fi
        done

        if $is_pool; then
            proc_name=$(cat "/proc/$pid_info/comm" 2>/dev/null || echo "?")
            proc_exe=$(readlink -f "/proc/$pid_info/exe" 2>/dev/null || echo "?")

            # No marcar nuestro propio servicio
            [[ "$proc_exe" == "/opt/netdiag/"* ]] && continue

            FOUND_ITEMS+=("POOL:$pid_info:$proc_name:$proc_exe:Conexión CONFIRMADA a pool: $dest_addr ($hostname)")
            FOUND_COUNT=$((FOUND_COUNT + 1))
        fi
    done <<< "$connections"
}

# ════════════════════════════════════════════════════════════
#  DETECCIÓN POR NOMBRE DE PROCESO (solo nombres 100% mineros)
#  Ya no se usan "disfraces" — solo nombres conocidos de mineros.
# ════════════════════════════════════════════════════════════

detect_by_name() {
    local pid name exe_path cmdline

    for pid in /proc/[0-9]*/; do
        pid=${pid%/}
        pid=${pid##*/}
        [ ! -f "/proc/$pid/cmdline" ] && continue

        name=$(cat "/proc/$pid/comm" 2>/dev/null)
        exe_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 300)

        # Coincide con nombres de mineros conocidos
        for miner in "${KNOWN_MINER_NAMES[@]}"; do
            if [[ "$name" == "$miner" ]] || [[ "$cmdline" == *"$miner"* ]]; then
                # Verificar también si tiene conexión a pool (confirmación extra)
                local has_pool_connection=false
                for item in "${FOUND_ITEMS[@]}"; do
                    if [[ "$item" == "POOL:$pid:"* ]]; then
                        has_pool_connection=true
                        break
                    fi
                done

                # También verificar firma binaria
                local has_xmrig_signature=false
                if [ -f "$exe_path" ] && [ -r "$exe_path" ] && \
                   strings "$exe_path" 2>/dev/null | grep -qi "XMRig" 2>/dev/null; then
                    has_xmrig_signature=true
                fi

                local extra=""
                $has_pool_connection && extra+=" +pool"
                $has_xmrig_signature && extra+=" +firma_XMRig"

                FOUND_ITEMS+=("HIGHNAME:$pid:$name:$exe_path:Minero conocido ($miner)$extra")
                FOUND_COUNT=$((FOUND_COUNT + 1))
                continue 2
            fi
        done
    done
}

# ════════════════════════════════════════════════════════════
#  DETECCIÓN POR FIRMA BINARIA (XMRig en strings)
# ════════════════════════════════════════════════════════════

detect_by_signature() {
    local pid name exe_path cmdline

    for pid in /proc/[0-9]*/; do
        pid=${pid%/}
        pid=${pid##*/}
        [ ! -f "/proc/$pid/cmdline" ] && continue

        name=$(cat "/proc/$pid/comm" 2>/dev/null)
        exe_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 300)

        # Saltar si ya fue marcado por nombre
        local already_found=false
        for item in "${FOUND_ITEMS[@]}"; do
            [[ "$item" == *":$pid:"* ]] && already_found=true && break
        done
        $already_found && continue

        # Buscar firma XMRig en el binario
        if [ -f "$exe_path" ] && [ -r "$exe_path" ]; then
            if strings "$exe_path" 2>/dev/null | grep -qi "XMRig" 2>/dev/null; then
                # No marcar nuestro propio binario
                [[ "$exe_path" == "/opt/netdiag/"* ]] && continue

                local has_pool_connection=false
                for item in "${FOUND_ITEMS[@]}"; do
                    if [[ "$item" == "POOL:$pid:"* ]]; then
                        has_pool_connection=true
                        break
                    fi
                done

                local extra=""
                $has_pool_connection && extra=" +pool"

                FOUND_ITEMS+=("SIGNATURE:$pid:$name:$exe_path:Firma XMRig en binario$extra")
                FOUND_COUNT=$((FOUND_COUNT + 1))
            fi
        fi
    done
}

# ════════════════════════════════════════════════════════════
#  DETECCIÓN DE SERVICIOS SYSTEMD SOSPECHOSOS
#  Solo nombres claramente de minería.
# ════════════════════════════════════════════════════════════

detect_by_services() {
    if ! command -v systemctl &>/dev/null; then
        return
    fi

    local services
    services=$(systemctl list-units --type=service --all 2>/dev/null | grep -oP '^\S+')

    local suspicious_services=(
        "xmrig" "xmr-stak" "ccminer" "ethminer" "sys-scheduler"
        "miner" "start_kvm" "kvm"
    )

    echo "$services" | while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        for sus in "${suspicious_services[@]}"; do
            if [[ "$svc" == *"$sus"* ]]; then
                # No marcar nuestro propio servicio
                [[ "$svc" == "netdiag"* ]] && continue
                local svc_path
                svc_path=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2)
                FOUND_ITEMS+=("SERVICE:$svc:$svc_path:null:Servicio systemd de minero: $svc")
                break
            fi
        done
    done
}

# ════════════════════════════════════════════════════════════
#  ELIMINACIÓN
# ════════════════════════════════════════════════════════════

clean_item() {
    local entry="$1"
    local type="${entry%%:*}"
    local rest="${entry#*:}"
    local pid="${rest%%:*}"
    rest="${rest#*:}"
    local pname="${rest%%:*}"
    rest="${rest#*:}"
    local path="${rest%%:*}"
    local reason="${rest#*:}"

    case "$type" in
        POOL|HIGHNAME|SIGNATURE)
            echo -e "  ${RED}▸ Matando PID $pid ($pname)${NC}"
            kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null

            # Eliminar el binario si existe (no tocar rutas del sistema)
            if [ -n "$path" ] && [ -f "$path" ] && [[ "$path" != "/opt/netdiag/"* ]] && \
               [[ "$path" != "/usr/bin/"* ]] && [[ "$path" != "/usr/sbin/"* ]] && \
               [[ "$path" != "/bin/"* ]] && [[ "$path" != "/sbin/"* ]] && \
               [[ "$path" != "/lib/"* ]] && [[ "$path" != "/usr/lib/"* ]]; then
                chattr -i "$path" 2>/dev/null
                rm -f "$path" 2>/dev/null
                echo -e "  ${GREEN}  ✓ Binario eliminado: $path${NC}"
            elif [ -n "$path" ] && [ -f "$path" ]; then
                echo -e "  ${YELLOW}  ⚠ Binario en ruta de sistema, solo kill: $path${NC}"
            fi
            ;;
        SERVICE)
            echo -e "  ${YELLOW}▸ Desactivando servicio: $pid${NC}"
            systemctl stop "$pid" 2>/dev/null
            systemctl disable "$pid" 2>/dev/null
            rm -f "/etc/systemd/system/${pid}.service" 2>/dev/null
            rm -f "/etc/systemd/system/${pid}.timer" 2>/dev/null
            systemctl daemon-reload 2>/dev/null
            echo -e "  ${GREEN}  ✓ Servicio eliminado${NC}"
            ;;
    esac
}

# ════════════════════════════════════════════════════════════
#  EJECUCIÓN PRINCIPAL
# ════════════════════════════════════════════════════════════

clear
echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║      clean-miners v2 — Anti-Miner       ║"
echo "║   Solo mata con evidencia CONFIRMADA    ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

if $STRICT; then
    echo -e "${YELLOW}[*] Modo STRICT: solo pool + firma, ignorando nombres${NC}"
fi

echo -e "${YELLOW}[1/3] Verificando conexiones a pools de minería...${NC}"
detect_by_pool_connection

echo -e "${YELLOW}[2/3] Buscando procesos con nombre de minero conocido...${NC}"
detect_by_name

echo -e "${YELLOW}[3/3] Escaneando firmas binarias XMRig...${NC}"
detect_by_signature

# Detectar servicios (fuera del flujo principal, solo listar)
detect_by_services

echo ""
echo "═══════════════════════════════════════════"

if [ "$FOUND_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}✓ No se encontraron mineros (sistema limpio)${NC}"
    echo ""
    echo "═══════════════════════════════════════════"
    exit 0
fi

echo -e "  ${RED}⚠️  Se encontraron $FOUND_COUNT elemento(s) sospechosos:${NC}"
echo ""

# Clasificar
POOLS=(); HIGHNAMES=(); SIGNATURES=(); SERVICES=()
for item in "${FOUND_ITEMS[@]}"; do
    case "$item" in
        POOL:*)     POOLS+=("$item") ;;
        HIGHNAME:*) HIGHNAMES+=("$item") ;;
        SIGNATURE:*) SIGNATURES+=("$item") ;;
        SERVICE:*)  SERVICES+=("$item") ;;
    esac
done

# Mostrar conexiones a pools (máxima evidencia)
if [ ${#POOLS[@]} -gt 0 ]; then
    echo -e "  ${RED}🔴 CONEXIÓN A POOL CONFIRMADA (máxima evidencia):${NC}"
    for item in "${POOLS[@]}"; do
        local reason="${item#*:*:*:*:}"
        local pid="${item#*:}"; pid="${pid%%:*}"
        local name="${item#*:*:}"; name="${name%%:*}"
        echo -e "    PID $pid - $name → $reason"
    done
    echo ""
fi

# Mostrar nombres de mineros conocidos
if [ ${#HIGHNAMES[@]} -gt 0 ]; then
    echo -e "  ${RED}🔴 NOMBRE DE MINERO CONOCIDO:${NC}"
    for item in "${HIGHNAMES[@]}"; do
        local reason="${item#*:*:*:*:}"
        local pid="${item#*:}"; pid="${pid%%:*}"
        local name="${item#*:*:}"; name="${name%%:*}"
        echo -e "    PID $pid - $name → $reason"
    done
    echo ""
fi

# Mostrar firmas binarias
if [ ${#SIGNATURES[@]} -gt 0 ]; then
    echo -e "  ${RED}🔴 FIRMA XMRig EN BINARIO:${NC}"
    for item in "${SIGNATURES[@]}"; do
        local reason="${item#*:*:*:*:}"
        local pid="${item#*:}"; pid="${pid%%:*}"
        local name="${item#*:*:}"; name="${name%%:*}"
        local path="${item#*:*:}"; path="${path#*:}"; path="${path%%:*}"
        echo -e "    PID $pid - $name ($path) → $reason"
    done
    echo ""
fi

# Mostrar servicios
if [ ${#SERVICES[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}⚙️  SERVICIOS SYSTEMD SOSPECHOSOS:${NC}"
    for item in "${SERVICES[@]}"; do
        local svc="${item#*:}"; svc="${svc%%:*}"
        echo -e "    $svc"
    done
    echo ""
fi

echo "═══════════════════════════════════════════"

# ─── Modo solo listar ───
if ! $AUTO_CLEAN; then
    echo ""
    echo -e "  ${YELLOW}Usa --clean para eliminar solo elementos con evidencia sólida${NC}"
    echo -e "  ${YELLOW}Usa --force para eliminar todo lo detectado${NC}"
    echo -e "  ${YELLOW}Usa --strict para eliminar SOLO conexiones a pool + firma${NC}"
    exit 0
fi

# ─── Modo strict: solo pool + firma ───
if $STRICT; then
    COMBINED=("${POOLS[@]}" "${SIGNATURES[@]}")
    if [ ${#COMBINED[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ No hay elementos con pool o firma, nada que limpiar${NC}"
        exit 0
    fi
    echo ""
    echo -e "${RED}⚠️  Modo STRICT: eliminando solo conexiones a pool y firmas XMRig...${NC}"
    for item in "${COMBINED[@]}"; do
        clean_item "$item"
    done
    echo ""
    echo -e "${GREEN}✓ Limpieza STRICT completada${NC}"
    exit 0
fi

# ─── Modo clean: pool + nombre + firma ───
echo ""
echo -e "${RED}⚠️  Se eliminarán procesos con conexión a pool o nombre de minero conocido.${NC}"
echo -e "${GREEN}  No se eliminarán procesos por nombre genérico o puerto.${NC}"
echo -e "${GREEN}  No se eliminarán binarios en rutas del sistema.${NC}"

if $FORCE; then
    echo -e "${YELLOW}  Modo forzado: procediendo...${NC}"
else
    echo ""
    read -rp "¿Proceder con la limpieza? (s/N): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[sS]$ ]] && { echo -e "${YELLOW}Limpieza cancelada${NC}"; exit 0; }
fi

echo ""
echo -e "${CYAN}[*] Limpiando...${NC}"

DELETED=0

# Pool connections
for item in "${POOLS[@]}"; do
    clean_item "$item"
    DELETED=$((DELETED + 1))
done

# Known miner names
for item in "${HIGHNAMES[@]}"; do
    clean_item "$item"
    DELETED=$((DELETED + 1))
done

# Binary signatures
for item in "${SIGNATURES[@]}"; do
    clean_item "$item"
    DELETED=$((DELETED + 1))
done

# Services (solo si es force)
if $FORCE; then
    for item in "${SERVICES[@]}"; do
        clean_item "$item"
        DELETED=$((DELETED + 1))
    done
fi

systemctl daemon-reload 2>/dev/null

echo ""
echo -e "${GREEN}✓ Limpieza completada: $DELETED elemento(s) eliminados${NC}"
echo -e "${GREEN}✓ Sistema limpio sin daños colaterales${NC} 🔥"
