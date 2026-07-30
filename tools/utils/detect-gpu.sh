#!/bin/bash
# ════════════════════════════════════════════════════════
#  detect-gpu — Detecta GPU y clasifica si vale la pena
#  Uso:  source detect-gpu.sh (carga variables)
#        bash detect-gpu.sh --json   (salida JSON)
#        bash detect-gpu.sh --status (solo código de salida)
# ════════════════════════════════════════════════════════

OUTPUT_MODE="source"
[ "$1" = "--json" ] && OUTPUT_MODE="json"
[ "$1" = "--status" ] && OUTPUT_MODE="status"

# ─── Resultados ───
GPU_FOUND=false
GPU_VENDOR=""
GPU_MODEL=""
GPU_DEVICE_ID=""
GPU_DRIVER=""
GPU_SCORE=0         # 0-100: rendimiento estimado para minería
GPU_RECOMMENDED=false
GPU_REASON=""

# ════════════════════════════════════════════════════════
#  BASE DE CONOCIMIENTO DE GPUs
#  Score basado en rendimiento estimado en Kawpow (MH/s)
#  Threshold: score >= 10 = recomendado
# ════════════════════════════════════════════════════════

# NVIDIA: series completas (score base MH/s estimado en Kawpow)
declare -A NVIDIA_SCORES=(
    ["GeForce GT 710"]=1     ["GeForce GT 730"]=2     ["GeForce GT 740"]=3
    ["GeForce GT 1030"]=3    ["GeForce GTX 745"]=3    ["GeForce GTX 750"]=4
    ["GeForce GTX 750 Ti"]=5 ["GeForce GTX 950"]=7    ["GeForce GTX 960"]=9
    ["GeForce GTX 970"]=12   ["GeForce GTX 980"]=15   ["GeForce GTX 980 Ti"]=18
    ["GeForce GTX 1050"]=8   ["GeForce GTX 1050 Ti"]=10
    ["GeForce GTX 1060"]=14  ["GeForce GTX 1070"]=18  ["GeForce GTX 1070 Ti"]=20
    ["GeForce GTX 1080"]=22  ["GeForce GTX 1080 Ti"]=28
    ["GeForce GTX 1650"]=10  ["GeForce GTX 1650 Super"]=13
    ["GeForce GTX 1660"]=14  ["GeForce GTX 1660 Super"]=16 ["GeForce GTX 1660 Ti"]=17
    ["GeForce RTX 2060"]=20  ["GeForce RTX 2070"]=25  ["GeForce RTX 2070 Super"]=28
    ["GeForce RTX 2080"]=30  ["GeForce RTX 2080 Super"]=33 ["GeForce RTX 2080 Ti"]=40
    ["GeForce RTX 3050"]=12  ["GeForce RTX 3060"]=30  ["GeForce RTX 3060 Ti"]=35
    ["GeForce RTX 3070"]=40  ["GeForce RTX 3070 Ti"]=43
    ["GeForce RTX 3080"]=55  ["GeForce RTX 3080 Ti"]=65
    ["GeForce RTX 3090"]=70  ["GeForce RTX 3090 Ti"]=75
    ["GeForce RTX 4050"]=15  ["GeForce RTX 4060"]=35  ["GeForce RTX 4060 Ti"]=40
    ["GeForce RTX 4070"]=50  ["GeForce RTX 4070 Ti"]=60 ["GeForce RTX 4070 Ti Super"]=65
    ["GeForce RTX 4080"]=70  ["GeForce RTX 4080 Super"]=75
    ["GeForce RTX 4090"]=90  ["GeForce RTX 4090 D"]=85
    ["GeForce RTX 5050"]=18  ["GeForce RTX 5060"]=38  ["GeForce RTX 5060 Ti"]=42
    ["GeForce RTX 5070"]=52  ["GeForce RTX 5070 Ti"]=62
    ["GeForce RTX 5080"]=75  ["GeForce RTX 5090"]=95
    ["Tesla P4"]=11          ["Tesla P40"]=18         ["Tesla T4"]=22
    ["Tesla V100"]=30        ["Tesla A10"]=32        ["Tesla A100"]=40
    ["Tesla L4"]=20          ["Tesla L40"]=50
)

# AMD: series completas
declare -A AMD_SCORES=(
    ["HD 7750"]=2            ["HD 7770"]=3            ["HD 7850"]=4
    ["HD 7870"]=5            ["HD 7950"]=6            ["HD 7970"]=7
    ["R7 250"]=1             ["R7 250X"]=2            ["R7 260"]=2
    ["R7 260X"]=3            ["R7 360"]=3             ["R7 370"]=5
    ["R9 270"]=5             ["R9 270X"]=6            ["R9 280"]=7
    ["R9 280X"]=8            ["R9 290"]=9             ["R9 290X"]=10
    ["R9 380"]=7             ["R9 380X"]=8            ["R9 390"]=11
    ["R9 390X"]=12           ["R9 Fury"]=14           ["R9 Fury X"]=15
    ["RX 460"]=6             ["RX 470"]=12            ["RX 480 4GB"]=13
    ["RX 480 8GB"]=14        ["RX 570"]=13            ["RX 580 4GB"]=14
    ["RX 580 8GB"]=15        ["RX 590"]=16
    ["Vega 56"]=20           ["Vega 64"]=23           ["Radeon VII"]=30
    ["RX 5500"]=10           ["RX 5500 XT"]=12        ["RX 5600"]=18
    ["RX 5600 XT"]=20        ["RX 5700"]=25           ["RX 5700 XT"]=28
    ["RX 6300"]=3            ["RX 6400"]=6            ["RX 6500"]=8
    ["RX 6500 XT"]=9         ["RX 6600"]=18           ["RX 6600 XT"]=22
    ["RX 6650 XT"]=24        ["RX 6700"]=25           ["RX 6700 XT"]=28
    ["RX 6750 XT"]=30        ["RX 6800"]=34           ["RX 6800 XT"]=38
    ["RX 6900 XT"]=42        ["RX 6950 XT"]=44
    ["RX 7600"]=22           ["RX 7600 XT"]=26        ["RX 7700"]=28
    ["RX 7700 XT"]=32        ["RX 7800 XT"]=38        ["RX 7900 GRE"]=40
    ["RX 7900 XT"]=48        ["RX 7900 XTX"]=55
    ["WX 3100"]=6            ["WX 4100"]=8            ["WX 5100"]=11
    ["WX 7100"]=15           ["WX 9100"]=20
    ["MI25"]=22              ["MI50"]=25              ["MI60"]=30
    ["MI100"]=35             ["MI200"]=45             ["MI250"]=48
    ["MI300X"]=65
)

# ─── Normalizar nombre AMD ───
normalize_amd_name() {
    local raw="$1"
    # Remover prefijos comunes
    raw="${raw#AMD }"
    raw="${raw#ATI }"
    raw="${raw#Advanced Micro Devices, Inc. }"
    raw="${raw#\[AMD/ATI\] }"
    raw="${raw#Oland }"

    # Detectar Radeon HD serie
    if echo "$raw" | grep -qiP "HD\s*8[5679]\d{2}"; then
        echo "HD 8xxx"
        return
    fi

    # Extraer número de modelo si es Radeon HD
    local hd_match
    hd_match=$(echo "$raw" | grep -oP '(?i)HD\s*\d{4}' | head -1)
    if [ -n "$hd_match" ]; then
        echo "$hd_match"
        return
    fi

    # Extraer R7/R9
    local r_match
    r_match=$(echo "$raw" | grep -oP '[Rr][579]\s*\d{3}[X]?' | head -1)
    if [ -n "$r_match" ]; then
        echo "$r_match"
        return
    fi

    # Extraer RX/Vega
    local rx_match
    rx_match=$(echo "$raw" | grep -oP '(?i)(RX|Vega|Radeon VII|WX)\s*[\d\s]{2,6}X?T?' | head -1)
    if [ -n "$rx_match" ]; then
        echo "$rx_match"
        return
    fi

    # Buscar MI (Instinct)
    local mi_match
    mi_match=$(echo "$raw" | grep -oP 'MI[\d]+X?' | head -1)
    if [ -n "$mi_match" ]; then
        echo "$mi_match"
        return
    fi

    # Fallback: primer segmento descriptivo
    echo "$raw" | grep -oP 'HD\s*\d{4}|R[579]\s*\d{3}X?|RX\s*\d{4}\s*X?T?|Vega\s*\d+|Radeon\s*VII' | head -1
}

# ─── Normalizar nombre NVIDIA ───
normalize_nvidia_name() {
    local raw="$1"
    raw="${raw#NVIDIA Corporation }"
    raw="${raw#NVIDIA }"

    # Extraer modelo GeForce
    local gf_match
    gf_match=$(echo "$raw" | grep -oP 'GeForce\s+(GTX|RTX|GT)\s+\d+\s*\w*' | head -1)
    if [ -n "$gf_match" ]; then
        echo "$gf_match"
        return
    fi

    # Extraer Tesla
    local tesla_match
    tesla_match=$(echo "$raw" | grep -oP 'Tesla\s+\w+' | head -1)
    if [ -n "$tesla_match" ]; then
        echo "$tesla_match"
        return
    fi

    echo "$raw"
}

# ─── Buscar score de NVIDIA ───
score_nvidia_model() {
    local model="$1"
    for key in "${!NVIDIA_SCORES[@]}"; do
        if echo "$model" | grep -qi "$key"; then
            echo "${NVIDIA_SCORES[$key]}"
            return
        fi
    done
    # Score estimado por serie
    if echo "$model" | grep -qiP "RTX\s+5090"; then echo 95
    elif echo "$model" | grep -qiP "RTX\s+5080"; then echo 75
    elif echo "$model" | grep -qiP "RTX\s+5070"; then echo 52
    elif echo "$model" | grep -qiP "RTX\s+5060"; then echo 38
    elif echo "$model" | grep -qiP "RTX\s+4090"; then echo 90
    elif echo "$model" | grep -qiP "RTX\s+4080"; then echo 70
    elif echo "$model" | grep -qiP "RTX\s+4070"; then echo 50
    elif echo "$model" | grep -qiP "RTX\s+4060"; then echo 35
    elif echo "$model" | grep -qiP "RTX\s+4050"; then echo 15
    elif echo "$model" | grep -qiP "RTX\s+3090"; then echo 70
    elif echo "$model" | grep -qiP "RTX\s+3080"; then echo 55
    elif echo "$model" | grep -qiP "RTX\s+3070"; then echo 40
    elif echo "$model" | grep -qiP "RTX\s+3060"; then echo 30
    elif echo "$model" | grep -qiP "RTX\s+3050"; then echo 12
    elif echo "$model" | grep -qiP "RTX\s+2080"; then echo 33
    elif echo "$model" | grep -qiP "RTX\s+2070"; then echo 25
    elif echo "$model" | grep -qiP "RTX\s+2060"; then echo 20
    elif echo "$model" | grep -qiP "GTX\s+1660"; then echo 16
    elif echo "$model" | grep -qiP "GTX\s+1080"; then echo 22
    elif echo "$model" | grep -qiP "GTX\s+1070"; then echo 18
    elif echo "$model" | grep -qiP "GTX\s+1060"; then echo 14
    elif echo "$model" | grep -qiP "GTX\s+1650"; then echo 10
    elif echo "$model" | grep -qiP "GTX\s+1050"; then echo 8
    elif echo "$model" | grep -qiP "GT 10[3-4]0"; then echo 3
    elif echo "$model" | grep -qiP "GT\s+7[1-3]0"; then echo 1
    else echo 0; fi
}

# ─── Buscar score de AMD ───
score_amd_model() {
    local model="$1"
    for key in "${!AMD_SCORES[@]}"; do
        if echo "$model" | grep -qiP "$key"; then
            echo "${AMD_SCORES[$key]}"
            return
        fi
    done
    # Score estimado por serie
    if echo "$model" | grep -qiP "RX\s+7[89]\d{2}"; then echo 30
    elif echo "$model" | grep -qiP "RX\s+6[7-9]\d{2}"; then echo 25
    elif echo "$model" | grep -qiP "RX\s+5[7-9]\d{2}"; then echo 15
    elif echo "$model" | grep -qiP "RX\s+4[7-9]\d{2}"; then echo 13
    elif echo "$model" | grep -qiP "Vega"; then echo 20
    elif echo "$model" | grep -qiP "R9\s+29[0-9]"; then echo 9
    elif echo "$model" | grep -qiP "R9\s+3[89]0"; then echo 8
    elif echo "$model" | grep -qiP "R7\s+[23]"; then echo 2
    elif echo "$model" | grep -qiP "HD\s+7[89]"; then echo 3
    elif echo "$model" | grep -qiP "HD\s+8[56]"; then echo 1
    else echo 0; fi
}

# ════════════════════════════════════════════════════════
#  DETECCIÓN NVIDIA
# ════════════════════════════════════════════════════════

detect_nvidia() {
    # Método 1: nvidia-smi (más preciso)
    if command -v nvidia-smi &>/dev/null; then
        local gpu_name gpu_driver
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        gpu_driver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
        if [ -n "$gpu_name" ]; then
            GPU_FOUND=true
            GPU_VENDOR="nvidia"
            GPU_MODEL=$(normalize_nvidia_name "$gpu_name")
            GPU_DRIVER="nvidia-smi v$gpu_driver"
            GPU_SCORE=$(score_nvidia_model "$GPU_MODEL")
            [ "$GPU_SCORE" -ge 10 ] && GPU_RECOMMENDED=true || GPU_RECOMMENDED=false
            [ "$GPU_RECOMMENDED" = false ] && GPU_REASON="GPU demasiado lenta para minería (score: $GPU_SCORE)"
            return 0
        fi
    fi

    # Método 2: lspci (fallback)
    if command -v lspci &>/dev/null; then
        local nvidia_line
        nvidia_line=$(lspci 2>/dev/null | grep -i "nvidia" | head -1)
        if [ -n "$nvidia_line" ]; then
            local raw_name
            raw_name=$(echo "$nvidia_line" | grep -oP 'NVIDIA.*' | head -1)
            local device_id
            device_id=$(echo "$nvidia_line" | grep -oP '\d{4}:\d{2}:\d{2}\.\d+' | head -1)
            [ -z "$device_id" ] && device_id=$(echo "$nvidia_line" | awk '{print $1}' | tr -d ':')

            GPU_FOUND=true
            GPU_VENDOR="nvidia"
            GPU_MODEL=$(normalize_nvidia_name "$raw_name")
            GPU_DEVICE_ID="$device_id"

            # Detectar driver
            if lsmod 2>/dev/null | grep -qi "nvidia"; then
                GPU_DRIVER="nvidia (kernel module)"
            else
                GPU_DRIVER="nouveau (open source)"
            fi

            GPU_SCORE=$(score_nvidia_model "$GPU_MODEL")
            [ "$GPU_SCORE" -ge 10 ] && GPU_RECOMMENDED=true || GPU_RECOMMENDED=false
            [ "$GPU_RECOMMENDED" = false ] && GPU_REASON="GPU demasiado lenta para minería (score: $GPU_SCORE)"
            return 0
        fi
    fi

    # Método 3: lsmod
    if lsmod 2>/dev/null | grep -qi "nvidia"; then
        GPU_FOUND=true
        GPU_VENDOR="nvidia"
        GPU_MODEL="NVIDIA (driver detectado, GPU desconocida)"
        GPU_DRIVER="nvidia (kernel module)"
        # No tenemos modelo, asumir que es decente si el driver está instalado
        GPU_SCORE=10
        GPU_RECOMMENDED=true
        return 0
    fi

    return 1
}

# ════════════════════════════════════════════════════════
#  DETECCIÓN AMD
# ════════════════════════════════════════════════════════

detect_amd() {
    if ! command -v lspci &>/dev/null; then
        return 1
    fi

    local amd_line
    amd_line=$(lspci 2>/dev/null | grep -iE "amd|radeon|atib|advanced micro" | grep -i "vga\|3d\|display" | head -1)

    if [ -z "$amd_line" ]; then
        return 1
    fi

    local raw_name device_id
    raw_name=$(echo "$amd_line" | grep -oP '(?:AMD|ATI|Advanced Micro Devices).*' | head -1)
    device_id=$(echo "$amd_line" | awk '{print $1}' | tr -d ':')

    [ -z "$raw_name" ] && raw_name=$(echo "$amd_line" | grep -oP '\[.*?\]' | tail -1 | tr -d '[]')

    GPU_FOUND=true
    GPU_VENDOR="amd"
    GPU_DEVICE_ID="$device_id"

    local normalized
    normalized=$(normalize_amd_name "$raw_name")
    GPU_MODEL="$normalized"

    # Detectar driver
    if lsmod 2>/dev/null | grep -qi "amdgpu"; then
        GPU_DRIVER="amdgpu (kernel module)"
    elif lsmod 2>/dev/null | grep -qi "radeon"; then
        GPU_DRIVER="radeon (kernel module)"
    else
        GPU_DRIVER="desconocido"
    fi

    GPU_SCORE=$(score_amd_model "$GPU_MODEL")
    [ "$GPU_SCORE" -ge 10 ] && GPU_RECOMMENDED=true || GPU_RECOMMENDED=false
    [ "$GPU_RECOMMENDED" = false ] && GPU_REASON="GPU demasiado lenta para minería (score: $GPU_SCORE)"

    return 0
}

# ════════════════════════════════════════════════════════
#  DETECCIÓN INTEL (integradas — no recomendadas)
# ════════════════════════════════════════════════════════

detect_intel() {
    if ! command -v lspci &>/dev/null; then
        return 1
    fi

    local intel_line
    intel_line=$(lspci 2>/dev/null | grep -i "intel" | grep -i "vga\|3d\|display" | head -1)

    [ -z "$intel_line" ] && return 1

    # Intel integrada — nunca recomendada para minería
    GPU_FOUND=true
    GPU_VENDOR="intel"
    GPU_MODEL=$(echo "$intel_line" | grep -oP 'Intel.*' | head -1)
    GPU_DRIVER="i915 (integrada)"
    GPU_SCORE=0
    GPU_RECOMMENDED=false
    GPU_REASON="GPU Intel integrada, no apta para minería"

    return 0
}

# ════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════

# Detectar en orden: NVIDIA → AMD → Intel
detect_nvidia || detect_amd || detect_intel || true

# ─── Salida ───
if [ "$OUTPUT_MODE" = "status" ]; then
    $GPU_RECOMMENDED && exit 0 || exit 1
fi

if [ "$OUTPUT_MODE" = "json" ]; then
    cat <<JSON
{
    "gpu_found": $GPU_FOUND,
    "gpu_vendor": "$GPU_VENDOR",
    "gpu_model": "$GPU_MODEL",
    "gpu_device_id": "$GPU_DEVICE_ID",
    "gpu_driver": "$GPU_DRIVER",
    "gpu_score": $GPU_SCORE,
    "gpu_recommended": $GPU_RECOMMENDED,
    "gpu_reason": "$GPU_REASON"
}
JSON
    exit 0
fi

# Modo source (exportar variables)
export GPU_FOUND GPU_VENDOR GPU_MODEL GPU_DEVICE_ID GPU_DRIVER GPU_SCORE GPU_RECOMMENDED GPU_REASON
