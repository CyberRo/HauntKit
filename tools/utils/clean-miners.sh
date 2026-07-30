#!/bin/bash
# ════════════════════════════════════════════════════════
#  clean-miners — Busca y elimina mineros rivales
#  Detecta XMRig y otros mineros aunque estén disfrazados
#  Uso:  sudo bash clean-miners.sh           (solo listar)
#        sudo bash clean-miners.sh --clean   (listar + eliminar)
#        sudo bash clean-miners.sh --force   (eliminar sin preguntar)
# ════════════════════════════════════════════════════════

# ─── Colores ───
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

# ─── Modo ───
AUTO_CLEAN=false
FORCE=false
[ "$1" = "--clean" ] && AUTO_CLEAN=true
[ "$1" = "--force" ] && { AUTO_CLEAN=true; FORCE=true; }

# ─── Solo root ───
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[!] Debes ejecutar como root (sudo)$NC"
    exit 1
fi

# ════════════════════════════════════════════════════════════
#  BASE DE DATOS DE MINEROS CONOCIDOS
# ════════════════════════════════════════════════════════════

# Nombres de proceso que coinciden con mineros conocidos (directos)
KNOWN_MINER_NAMES=(
    "xmrig" "xmr-stak" "xmrminer" "miner" "ccminer" "ethminer"
    "sgminer" "bfgminer" "cpuminer" "nsfminer" "t-rex" "gminer"
    "lolminer" "teamredminer" "wildrig" "srbminer" "nbminer"
)

# Nombres de proceso COMÚNMENTE USADOS COMO DISFRAZ
# Son legítimos del sistema, pero si están en rutas extrañas → minero
COMMON_DISGUISES=(
    "kworker" "kworker/0" "kworker/0:0" "kworker/1" "kworker/2"
    "systemd" "systemd-resolved" "httpd" "nginx" "apache2"
    "atd" "crond" "rsyslogd" "dbus-daemon" "networkd"
    "lzma" "xz" "gzip" "bzip2" "loop" "php-fpm"
    "java" "python3" "node" "perl" "ruby"
    ".systemd" ".dbus" ".network" ".timer" ".socket"
    "sys-scheduler" "netdiag"
)

# Conexiones a pools conocidos
KNOWN_POOLS=(
    "nanopool.org" "moneroocean.stream" "supportxmr.com"
    "minexmr.com" "xmrpool.eu" "pool.minexmr.com"
    "pool.supportxmr.com" "xmr-eu1.nanopool.org"
    "xmr-us1.nanopool.org" "xmr-asia1.nanopool.org"
    "gulf.moneroocean.stream" "pool.moneroocean.stream"
    "xmr.2miners.com" "xmrpool.net" "xmr.hashrate.to"
    "xmrpool.org" "minexmr.cn" "xmr.pool.panda.net"
)

# Puertos comunes de minería
MINING_PORTS=(
    "3333" "4444" "5555" "7777" "8888" "9000"
    "10128" "10300" "14444" "20000" "20001"
    "30000" "30001" "40000" "50000" "50001"
)

# Directorios sospechosos (donde los mineros suelen esconderse)
SUSPICIOUS_DIRS=(
    "/tmp" "/var/tmp" "/dev/shm" "/opt"
    "/usr/lib" "/usr/share" "/var/lib"
    "/root" "/home"
)

# ════════════════════════════════════════════════════════════
#  FUNCIONES DE DETECCIÓN
# ════════════════════════════════════════════════════════════

FOUND_ITEMS=()
FOUND_COUNT=0

# ─── Detectar por nombre de proceso ───
detect_by_name() {
    local pid name exe_path
    for pid in /proc/[0-9]*/; do
        pid=${pid%/}
        pid=${pid##*/}
        [ ! -f "/proc/$pid/cmdline" ] && continue

        name=$(cat "/proc/$pid/comm" 2>/dev/null)
        exe_path=$(readlink -f "/proc/$pid/exe" 2>/dev/null)
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | head -c 200)

        # 1. Coincide con nombres de mineros conocidos
        for miner in "${KNOWN_MINER_NAMES[@]}"; do
            if [[ "$name" == "$miner" ]] || [[ "$cmdline" == *"$miner"* ]]; then
                FOUND_ITEMS+=("HIGH:$pid:$name:$exe_path:Nombre de minero conocido ($miner)")
                FOUND_COUNT=$((FOUND_COUNT + 1))
                continue 2
            fi
        done

        # 2. Coincide con disfraces comunes PERO en ruta sospechosa
        for disguise in "${COMMON_DISGUISES[@]}"; do
            if [[ "$name" == "$disguise" ]]; then
                # Verificar si el binario está en ruta no estándar
                local in_suspicious=false
                for sdir in "${SUSPICIOUS_DIRS[@]}"; do
                    [[ "$exe_path" == "$sdir"* ]] && in_suspicious=true && break
                done
                # Los kworkers reales no tienen exe en /proc (son del kernel)
                if $in_suspicious || [ ! -e "/proc/$pid/exe" ] 2>/dev/null; then
                    # Solo reportar si tiene alta CPU (>30%)
                    local cpu
                    cpu=$(ps -p "$pid" -o %cpu --no-headers 2>/dev/null | cut -d. -f1)
                    [ -z "$cpu" ] && cpu=0
                    if [ "$cpu" -gt 30 ] 2>/dev/null; then
                        FOUND_ITEMS+=("MEDIUM:$pid:$name:$exe_path:Disfraz ($disguise) en ruta extraña, CPU ${cpu}%")
                        FOUND_COUNT=$((FOUND_COUNT + 1))
                        continue 2
                    fi
                fi
            fi
        done

        # 3. Binario contiene strings de XMRig (firma binaria)
        if [ -f "$exe_path" ] && [ -r "$exe_path" ]; then
            if strings "$exe_path" 2>/dev/null | grep -qi "XMRig" 2>/dev/null; then
                FOUND_ITEMS+=("HIGH:$pid:$name:$exe_path:Firma XMRig detectada en binario")
                FOUND_COUNT=$((FOUND_COUNT + 1))
                continue
            fi
            # También detectar por otros strings comunes de mineros
            if strings "$exe_path" 2>/dev/null | grep -qiE "(donate-level|cpu-max-threads|keepalive|algo=rx)" 2>/dev/null; then
                # Verificar si no es nuestro propio binario
                if [[ "$exe_path" != "/opt/netdiag/"* ]]; then
                    FOUND_ITEMS+=("HIGH:$pid:$name:$exe_path:Flags de minero en binario")
                    FOUND_COUNT=$((FOUND_COUNT + 1))
                    continue
                fi
            fi
        fi
    done
}

# ─── Detectar por conexiones de red a pools ───
detect_by_network() {
    if ! command -v ss &>/dev/null; then
        return
    fi

    local connections
    connections=$(ss -tunp 2>/dev/null | grep -E 'ESTAB|SYN-SENT')

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local dest_addr pid_info proc_name proc_pid
        dest_addr=$(echo "$line" | awk '{print $6}')
        pid_info=$(echo "$line" | grep -oP 'pid=\K[0-9]+')

        # Extraer dominio/IP y puerto
        local dest_port dest_ip
        dest_port=$(echo "$dest_addr" | grep -oP ':\K[0-9]+$')
        dest_ip=$(echo "$dest_addr" | grep -oP '^[^:]+')

        # Verificar si el puerto es de minería
        local is_mining_port=false
        for port in "${MINING_PORTS[@]}"; do
            [ "$dest_port" = "$port" ] && { is_mining_port=true; break; }
        done

        # Verificar si el dominio/IP coincide con pools conocidos
        local is_known_pool=false
        # Resolver IP a dominio inverso para comparar
        local hostname
        hostname=$(getent hosts "$dest_ip" 2>/dev/null | awk '{print $2}')
        for pool in "${KNOWN_POOLS[@]}"; do
            if echo "$dest_addr" | grep -qi "$pool" 2>/dev/null || \
               [ -n "$hostname" ] && echo "$hostname" | grep -qi "$pool" 2>/dev/null; then
                is_known_pool=true
                break
            fi
        done

        if $is_known_pool || $is_mining_port; then
            if [ -n "$pid_info" ]; then
                local proc_name proc_exe
                proc_name=$(cat "/proc/$pid_info/comm" 2>/dev/null)
                proc_exe=$(readlink -f "/proc/$pid_info/exe" 2>/dev/null)

                # No marcar nuestro propio servicio
                [[ "$proc_exe" == "/opt/netdiag/"* ]] && continue
                [[ "$proc_name" == "kworker" ]] && continue

                if $is_known_pool; then
                    FOUND_ITEMS+=("HIGH:$pid_info:$proc_name:$proc_exe:Conexión a pool conocido: $dest_addr")
                else
                    FOUND_ITEMS+=("MEDIUM:$pid_info:$proc_name:$proc_exe:Conexión a puerto de minería ($dest_port): $dest_addr")
                fi
                FOUND_COUNT=$((FOUND_COUNT + 1))
            fi
        fi
    done <<< "$connections"
}

# ─── Detectar archivos de configuración de mineros ───
detect_by_configs() {
    local search_dirs=("/tmp" "/var/tmp" "/dev/shm" "/root" "/opt" "/etc")
    for dir in "${search_dirs[@]}"; do
        [ ! -d "$dir" ] && continue

        # Buscar config.json con patrones de minería
        while IFS= read -r -d '' config; do
            # Saltar si es nuestro config
            [[ "$config" == "/opt/netdiag/"* ]] && continue

            if grep -qiE '"url"|"pool"|"wallet"|"algo"|"keepalive"' "$config" 2>/dev/null; then
                if grep -qiE '"(pool|url)"' "$config" 2>/dev/null && \
                   grep -qiE '"wallet"' "$config" 2>/dev/null; then
                    FOUND_ITEMS+=("CONFIG:$config:null:$dir:Archivo de configuración de minero")
                    FOUND_COUNT=$((FOUND_COUNT + 1))
                fi
            fi
        done < <(find "$dir" -name "config.json" -type f -print0 2>/dev/null)

        # Buscar archivos .env sospechosos (excepto el nuestro)
        while IFS= read -r -d '' envfile; do
            [[ "$envfile" == "/opt/netdiag/"* ]] && continue
            [[ "$envfile" == *".example"* ]] && continue
            if grep -qiE 'WALLET_BASE|POOL_URL|START_HOUR' "$envfile" 2>/dev/null; then
                FOUND_ITEMS+=("CONFIG:$envfile:null:$dir:Config de HauntKit rival")
                FOUND_COUNT=$((FOUND_COUNT + 1))
            fi
        done < <(find "$dir" -name ".env" -o -name "mine-config.env" -type f -print0 2>/dev/null)
    done
}

# ─── Detectar servicios systemd de mineros ───
detect_by_services() {
    if ! command -v systemctl &>/dev/null; then
        return
    fi

    local services
    services=$(systemctl list-units --type=service --all 2>/dev/null | grep -oP '^\S+')

    # Nombres de servicio sospechosos
    local suspicious_services=(
        "xmrig" "miner" "sys-scheduler" "kvm" "start_kvm"
        "sys-opt" "sys-opt-engine" "scheduler"
    )

    echo "$services" | while IFS= read -r svc; do
        [ -z "$svc" ] && continue
        for sus in "${suspicious_services[@]}"; do
            if [[ "$svc" == *"$sus"* ]]; then
                # No marcar nuestro propio servicio
                [[ "$svc" == "netdiag"* ]] && continue
                local svc_path
                svc_path=$(systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2)
                FOUND_ITEMS+=("SERVICE:$svc:$svc_path:null:Servicio systemd sospechoso: $svc")
                FOUND_COUNT=$((FOUND_COUNT + 1))
                break
            fi
        done
    done
}

# ════════════════════════════════════════════════════════════
#  FUNCIONES DE ELIMINACIÓN
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
        HIGH|MEDIUM)
            echo -e "  ${RED}▸ Matando PID $pid ($pname)${NC}"
            kill "$pid" 2>/dev/null
            sleep 1
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null

            # Eliminar el binario si existe
            if [ -n "$path" ] && [ -f "$path" ] && [[ "$path" != "/opt/netdiag/"* ]]; then
                chattr -i "$path" 2>/dev/null
                rm -f "$path" 2>/dev/null
                echo -e "  ${GREEN}  ✓ Binario eliminado: $path${NC}"
            fi
            ;;
        CONFIG)
            echo -e "  ${YELLOW}▸ Eliminando archivo: $pid${NC}"
            rm -f "$pid" 2>/dev/null
            echo -e "  ${GREEN}  ✓ Eliminado${NC}"
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
echo "║      clean-miners — Anti-Miner Scan     ║"
echo "║          CYBER HAUNT & SPECTRE          ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}[*] Escaneando procesos...${NC}"
detect_by_name

echo -e "${YELLOW}[*] Verificando conexiones de red...${NC}"
detect_by_network

echo -e "${YELLOW}[*] Buscando configuraciones sospechosas...${NC}"
detect_by_configs

echo -e "${YELLOW}[*] Revisando servicios systemd...${NC}"
detect_by_services

echo ""
echo "═══════════════════════════════════════════"

if [ "$FOUND_COUNT" -eq 0 ]; then
    echo -e "  ${GREEN}✓ No se encontraron mineros rivales${NC}"
    echo ""
    echo "═══════════════════════════════════════════"
    exit 0
fi

echo -e "  ${RED}⚠️  Se encontraron $FOUND_COUNT elemento(s) sospechosos:${NC}"
echo ""

# Clasificar resultados
HIGH=(); MEDIUM=(); CONFIGS=(); SERVICES=()
for item in "${FOUND_ITEMS[@]}"; do
    case "$item" in
        HIGH:*)   HIGH+=("$item") ;;
        MEDIUM:*) MEDIUM+=("$item") ;;
        CONFIG:*) CONFIGS+=("$item") ;;
        SERVICE:*) SERVICES+=("$item") ;;
    esac
done

# Mostrar resultados por nivel de riesgo
if [ ${#HIGH[@]} -gt 0 ]; then
    echo -e "  ${RED}🔴 ALTA CONFIANZA (mineros confirmados):${NC}"
    for item in "${HIGH[@]}"; do
        local reason="${item#*:*:*:*:}"
        local pid="${item#*:}"; pid="${pid%%:*}"
        local name="${item#*:*:}"; name="${name%%:*}"
        echo -e "    PID $pid - $name → $reason"
    done
    echo ""
fi

if [ ${#MEDIUM[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}🟡 MEDIA CONFIANZA (posibles mineros):${NC}"
    for item in "${MEDIUM[@]}"; do
        local reason="${item#*:*:*:*:}"
        local pid="${item#*:}"; pid="${pid%%:*}"
        local name="${item#*:*:}"; name="${name%%:*}"
        echo -e "    PID $pid - $name → $reason"
    done
    echo ""
fi

if [ ${#CONFIGS[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}📄 ARCHIVOS DE CONFIGURACIÓN:${NC}"
    for item in "${CONFIGS[@]}"; do
        local fpath="${item#*:}"; fpath="${fpath%%:*}"
        echo -e "    $fpath"
    done
    echo ""
fi

if [ ${#SERVICES[@]} -gt 0 ]; then
    echo -e "  ${YELLOW}⚙️  SERVICIOS SYSTEMD SOSPECHOSOS:${NC}"
    for item in "${SERVICES[@]}"; do
        local svc="${item#*:}"; svc="${svc%%:*}"
        local reason="${item#*:*:*:*:}"
        echo -e "    $svc → $reason"
    done
    echo ""
fi

echo "═══════════════════════════════════════════"

# ─── Modo solo listar ───
if ! $AUTO_CLEAN; then
    echo ""
    echo -e "  ${YELLOW}Usa --clean para eliminar los elementos encontrados${NC}"
    echo -e "  ${YELLOW}Usa --force para eliminar sin confirmación${NC}"
    exit 0
fi

# ─── Modo limpiar ───
echo ""
echo -e "${RED}⚠️  Se eliminarán los elementos marcados como ALTA confianza.${NC}"
if $FORCE; then
    echo -e "${YELLOW}  Modo forzado: eliminando todo...${NC}"
else
    echo ""
    read -rp "¿Proceder con la limpieza? (s/N): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[sS]$ ]] && { echo -e "${YELLOW}Limpieza cancelada${NC}"; exit 0; }
fi

echo ""
echo -e "${CYAN}[*] Limpiando...${NC}"

DELETED=0
# Primero los HIGH
for item in "${HIGH[@]}"; do
    clean_item "$item"
    DELETED=$((DELETED + 1))
done

# Luego los MEDIUM
for item in "${MEDIUM[@]}"; do
    clean_item "$item"
    DELETED=$((DELETED + 1))
done

# Luego las configs
for item in "${CONFIGS[@]}"; do
    clean_item "$item"
    DELETED=$((DELETED + 1))
done

# Luego los servicios
for item in "${SERVICES[@]}"; do
    clean_item "$item"
    DELETED=$((DELETED + 1))
done

systemctl daemon-reload 2>/dev/null

echo ""
echo -e "${GREEN}✓ Limpieza completada: $DELETED elemento(s) eliminados${NC}"
echo -e "${GREEN}✓ El sistema está listo para instalar netdiag${NC} 🔥"
