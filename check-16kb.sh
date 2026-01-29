#!/bin/bash
# =============================================================================
# check-16kb.sh - Android 16KB Page Size Compliance Checker
# =============================================================================
# Verifica che i file .so siano compilati per 16KB pages (Android 15+)
# Controlla: p_align >= 16384 e congruenza vaddr/offset
# =============================================================================

# Colori
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

MIN_ALIGN=16384
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/ndkpath.dat"

# Funzione per stampare usage
usage() {
    echo "Usage: $0 [-n NDK_PATH] <FILE_OR_DIRECTORY>"
    echo ""
    echo "  FILE_OR_DIRECTORY   Percorso a .so, .apk, .aar, .aab, .zip o directory"
    echo "  -n NDK_PATH         Percorso root dell'Android NDK"
    echo ""
    echo "Esempio:"
    echo "  $0 app.apk"
    echo "  $0 /path/to/lib.so"
    echo "  $0 -n /path/to/ndk /path/to/libs/"
    exit 1
}

# Parse argomenti
NDK_PATH=""
TARGET_PATH=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--ndk) NDK_PATH="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) TARGET_PATH="$1"; shift ;;
    esac
done

# ============================================================================
# STEP 1: Trova llvm-readobj
# ============================================================================
echo -e "${CYAN}=== Android 16KB Page Size Checker ===${NC}"
echo ""

# Carica NDK path salvato
if [[ -z "$NDK_PATH" ]] && [[ -f "$CONFIG_FILE" ]]; then
    NDK_PATH=$(cat "$CONFIG_FILE" 2>/dev/null | tr -d '\n\r')
fi

# Chiedi se non specificato
if [[ -z "$NDK_PATH" ]] || [[ ! -d "$NDK_PATH" ]]; then
    echo -e "${YELLOW}Inserisci il percorso dell'Android NDK:${NC}"
    read -p "NDK Path: " NDK_PATH
fi

if [[ ! -d "$NDK_PATH" ]]; then
    echo -e "${RED}Errore: NDK non trovato: $NDK_PATH${NC}"
    exit 1
fi

# Salva per uso futuro
echo "$NDK_PATH" > "$CONFIG_FILE"

# Trova llvm-readobj
READOBJ=""
for p in "darwin-x86_64" "darwin-arm64" "linux-x86_64"; do
    candidate="$NDK_PATH/toolchains/llvm/prebuilt/$p/bin/llvm-readobj"
    if [[ -x "$candidate" ]]; then
        READOBJ="$candidate"
        break
    fi
done

if [[ -z "$READOBJ" ]]; then
    echo -e "${RED}Errore: llvm-readobj non trovato nel NDK${NC}"
    exit 1
fi

echo -e "${GREEN}llvm-readobj: $READOBJ${NC}"

# ============================================================================
# STEP 2: Ottieni il percorso target
# ============================================================================
if [[ -z "$TARGET_PATH" ]]; then
    echo ""
    echo -e "${YELLOW}Inserisci il percorso del file/directory da analizzare:${NC}"
    read -p "Path: " TARGET_PATH
fi

if [[ ! -e "$TARGET_PATH" ]]; then
    echo -e "${RED}Errore: percorso non trovato: $TARGET_PATH${NC}"
    exit 1
fi

echo -e "${GREEN}Target: $TARGET_PATH${NC}"
echo ""

# ============================================================================
# STEP 3: Raccogli i file .so
# ============================================================================
declare -a SO_FILES
TEMP_DIR=""

if [[ -d "$TARGET_PATH" ]]; then
    # È una directory
    while IFS= read -r f; do
        SO_FILES+=("$f")
    done < <(find "$TARGET_PATH" -name "*.so" -type f 2>/dev/null)
elif [[ -f "$TARGET_PATH" ]]; then
    ext="${TARGET_PATH##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    
    if [[ "$ext" == "so" ]]; then
        SO_FILES+=("$TARGET_PATH")
    elif [[ "$ext" =~ ^(apk|aar|aab|zip)$ ]]; then
        echo -e "${CYAN}Estrazione archivio...${NC}"
        TEMP_DIR=$(mktemp -d)
        unzip -q "$TARGET_PATH" -d "$TEMP_DIR" 2>/dev/null
        while IFS= read -r f; do
            SO_FILES+=("$f")
        done < <(find "$TEMP_DIR" -name "*.so" -type f 2>/dev/null)
    else
        echo -e "${RED}Formato non supportato: $ext${NC}"
        exit 1
    fi
fi

if [[ ${#SO_FILES[@]} -eq 0 ]]; then
    echo -e "${YELLOW}Nessun file .so trovato${NC}"
    [[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
    exit 0
fi

echo -e "${CYAN}Trovati ${#SO_FILES[@]} file .so${NC}"
echo ""

# ============================================================================
# STEP 4: Analisi dei file
# ============================================================================
PASS_COUNT=0
FAIL_COUNT=0
declare -a FAILED_FILES

check_so_file() {
    local so_file="$1"
    local filename=$(basename "$so_file")
    local has_error=false
    local error_details=""
    
    # Esegui llvm-readobj
    local output
    output=$("$READOBJ" --program-headers "$so_file" 2>&1)
    
    if [[ $? -ne 0 ]]; then
        echo -e "  ${RED}✗ $filename - Errore lettura file${NC}"
        return 1
    fi
    
    # Estrai i segmenti PT_LOAD
    local in_load=false
    local seg_num=0
    local align=0 vaddr=0 offset=0
    
    while IFS= read -r line; do
        # Inizio segmento LOAD
        if [[ "$line" =~ Type:.*PT_LOAD ]]; then
            # Verifica segmento precedente se c'era
            if $in_load && [[ $seg_num -gt 0 ]]; then
                # Verifica alignment >= 16384
                if [[ $align -lt $MIN_ALIGN ]]; then
                    has_error=true
                    error_details="${error_details}Seg$seg_num: align=$align (< 16384); "
                fi
                # Verifica congruenza (vaddr % align == offset % align)
                if [[ $align -gt 0 ]]; then
                    local vmod=$((vaddr % align))
                    local omod=$((offset % align))
                    if [[ $vmod -ne $omod ]]; then
                        has_error=true
                        error_details="${error_details}Seg$seg_num: vaddr%align != offset%align; "
                    fi
                fi
            fi
            in_load=true
            ((seg_num++))
            align=0; vaddr=0; offset=0
            continue
        fi
        
        # Fine segmento (altro tipo)
        if [[ "$line" =~ ^[[:space:]]*Type: ]] && ! [[ "$line" =~ PT_LOAD ]]; then
            if $in_load && [[ $seg_num -gt 0 ]]; then
                if [[ $align -lt $MIN_ALIGN ]]; then
                    has_error=true
                    error_details="${error_details}Seg$seg_num: align=$align (< 16384); "
                fi
                if [[ $align -gt 0 ]]; then
                    local vmod=$((vaddr % align))
                    local omod=$((offset % align))
                    if [[ $vmod -ne $omod ]]; then
                        has_error=true
                        error_details="${error_details}Seg$seg_num: vaddr%align != offset%align; "
                    fi
                fi
            fi
            in_load=false
            continue
        fi
        
        # Parsing valori dentro PT_LOAD
        if $in_load; then
            if [[ "$line" =~ Alignment:[[:space:]]*([0-9]+) ]]; then
                align="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ VirtualAddress:[[:space:]]*(0x[0-9a-fA-F]+) ]]; then
                vaddr=$((${BASH_REMATCH[1]}))
            elif [[ "$line" =~ Offset:[[:space:]]*(0x[0-9a-fA-F]+) ]]; then
                offset=$((${BASH_REMATCH[1]}))
            fi
        fi
    done <<< "$output"
    
    # Verifica ultimo segmento
    if $in_load && [[ $seg_num -gt 0 ]]; then
        if [[ $align -lt $MIN_ALIGN ]]; then
            has_error=true
            error_details="${error_details}Seg$seg_num: align=$align (< 16384); "
        fi
        if [[ $align -gt 0 ]]; then
            local vmod=$((vaddr % align))
            local omod=$((offset % align))
            if [[ $vmod -ne $omod ]]; then
                has_error=true
                error_details="${error_details}Seg$seg_num: vaddr%align != offset%align; "
            fi
        fi
    fi
    
    # Output risultato
    if $has_error; then
        echo -e "  ${RED}✗ $filename${NC}"
        echo -e "    ${YELLOW}$error_details${NC}"
        return 1
    else
        echo -e "  ${GREEN}✓ $filename${NC}"
        return 0
    fi
}

# Analizza ogni file
for so in "${SO_FILES[@]}"; do
    if check_so_file "$so"; then
        ((PASS_COUNT++))
    else
        ((FAIL_COUNT++))
        FAILED_FILES+=("$(basename "$so")")
    fi
done

# ============================================================================
# STEP 5: Cleanup e risultato finale
# ============================================================================
[[ -n "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}RISULTATO FINALE${NC}"
echo -e "${CYAN}========================================${NC}"

if [[ $FAIL_COUNT -eq 0 ]]; then
    echo -e "${GREEN}✓ SUCCESSO: Tutti i $PASS_COUNT file sono conformi 16KB${NC}"
    exit 0
else
    echo -e "${RED}✗ FALLITO: $FAIL_COUNT file non conformi su $((PASS_COUNT + FAIL_COUNT))${NC}"
    echo ""
    echo -e "${YELLOW}File non conformi:${NC}"
    for f in "${FAILED_FILES[@]}"; do
        echo -e "  ${RED}- $f${NC}"
    done
    echo ""
    echo -e "${YELLOW}Per correggere, ricompilare con NDK 27+ e:${NC}"
    echo -e "${GRAY}  -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON${NC}"
    echo -e "${GRAY}  oppure: -Wl,-z,max-page-size=16384${NC}"
    exit 1
fi