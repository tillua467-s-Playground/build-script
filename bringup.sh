#!/usr/bin/env bash
set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' 

print_banner() {
    echo -e "${GREEN}"
    echo "    ██████╗ ██████╗ ██╗███╗   ██╗ ██████╗ ██╗   ██╗██████╗  ██████╗ ████████╗"
    echo "    ██╔══██╗██╔══██╗██║████╗  ██║██╔════╝ ██║   ██║██╔══██╗██╔═══██╗╚══██╔══╝"
    echo "    ██████╔╝██████╔╝██║██╔██╗ ██║██║  ███╗██║   ██║██████╔╝██║   ██║   ██║   "
    echo "    ██╔══██╗██╔══██╗██║██║╚██╗██║██║   ██║██║   ██║██╔══██╗██║   ██║   ██║   "
    echo "    ██████╔╝██║  ██║██║██║ ╚████║╚██████╔╝╚██████╔╝██████╔╝╚██████╔╝   ██║   "
    echo "    ╚═════╝ ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝  ╚═════╝ ╚═════╝  ╚═════╝    ╚═╝   "
    echo -e "${NC}"
}


# Helpers
bak() {
    local f="$1"
    if [ -f "$f" ] && [ ! -f "${f}.bak" ]; then
        cp -a "$f" "${f}.bak"
    fi
}

replace_file_regex() {
    local file="$1"
    local perl_expr="$2"
    bak "$file"
    perl -0777 -pe "$perl_expr" -i "$file"
}

prompt_yesno() {
    local prompt="$1"
    local default="${2:-}"
    while true; do
        read -rp "$prompt " ans
        ans="${ans,,}"
        case "$ans" in
        y|yes) return 0 ;;
        n|no) return 1 ;;
        "") if [ -n "$default" ]; then
                if [ "$default" = "y" ]; then return 0; else return 1; fi
            fi
            ;;
        esac
        echo "Please answer y or n."
    done
}

# Logging
info() { printf "\n${GREEN}[INFO] %s${NC}\n" "$1"; }
warn() { printf "\n${YELLOW}[WARN] %s${NC}\n" "$1"; }
err()  { printf "\n${RED}[ERROR] %s${NC}\n" "$1" >&2; }

show_help() {
    echo "Usage: $0 [options]"
    echo
    echo "Options:"
    echo "  -h, --help           Show this help message."
    echo "  -l, --list-roms      List all specially supported ROM names and exit."
    echo "  -m, --env            Use environment variables for configuration instead of interactive prompts."
    echo "                       (Requires BRINGUP_CODENAME, BRINGUP_ROM_PREFIX, etc.)"
    echo "  -n, --new-rom <name> <prefix>"
    echo "                       Add a new ROM mapping to the script and exit."
    echo "                       Example: $0 -n \"Evolution X\" evo"
    echo
    echo "If no options are provided, the script runs in interactive mode."
}

add_new_rom() {
    local rom_name="$1"
    local rom_prefix="$2"
    local script_path="$0"

    info "Adding new ROM to script: '$rom_name' -> '$rom_prefix'"

    bak "$script_path"
    local new_case_line="      \"${rom_name}\") ROM_PREFIX=\"${rom_prefix}\" ;;"
    
    perl -i -pe 's/^(\s*)"infinity"|\"infinityx"\)/'"$new_case_line"'\n$1"infinity"|"infinityx"/' "$script_path"

    if grep -q "$rom_prefix" "$script_path"; then
        info "Successfully added new ROM. Please review the script file ('$script_path') to ensure correctness."
    else
        err "Failed to add new ROM. The script may be in an inconsistent state. Please check the backup."
        exit 1
    fi
}

list_supported_roms() {
    info "Listing specially mapped ROMs:"
    sed -n '/case.*INPUT_ROM_NAME/,/esac/p' "$0" | \
        grep -v -E 'case|esac|\*|""' | \
        sed -E 's/^\s*//; s/\).+//; s/\"//g; s/\|/ | /g' | \
        while read -r line; do
            echo "  - $line"
        done

    echo
    echo "Note: Any other name can be entered and will be used as its own prefix."
}

get_product_makefile_from_AndroidProducts() {
    local devdir="$1"
    local ap="$devdir/AndroidProducts.mk"
    if [ ! -f "$ap" ]; then
        warn "AndroidProducts.mk not found in $devdir"
        return 1
    fi
    awk '
        BEGIN{found=0;}
        /PRODUCT_MAKEFILES/ {found=1}
        found && /\\$/ {next}
        found && /local_dir/ { } # skip
        found && /[\w\W]*\.mk/ {if(match($0, /([[:alnum:]_\/-]+\.mk)/,a)) {print a[1]; exit}}
        ' "$ap" | head -n1
}

edit_product_makefile() {
    local devdir="$1"
    local product_mk="$2"
    local fpath
    if [ -f "$product_mk" ]; then
        fpath="$product_mk"
    elif [ -f "$devdir/$product_mk" ]; then
        fpath="$devdir/$product_mk"
    else
        fpath="$(find "$devdir" -name "$(basename "$product_mk")" -print -quit || true)"
    fi
    if [ -z "$fpath" ] || [ ! -f "$fpath" ]; then
        warn "Product makefile not found: $product_mk"
        return 1
    fi

    info "Editing product makefile: $fpath"
    local desired_product="${ROM_PREFIX}_${CODENAME}"
    replace_file_regex "$fpath" "s/^\s*PRODUCT_NAME\s*[:+]?=\s*.*$/PRODUCT_NAME := ${desired_product}/m"
    replace_file_regex "$fpath" "s#\\\$\\(call inherit-product, vendor/[^/]+/config/common_full_phone.mk\\)#\x24(call inherit-product, vendor/${ROM_PREFIX}/config/common_full_phone.mk)#g"
    replace_file_regex "$fpath" "s#vendor/[^/]+/config/common_full_phone.mk#vendor/${ROM_PREFIX}/config/common_full_phone.mk#g"

    local new_basename="${desired_product}.mk"
    local old_basename
    old_basename="$(basename "$fpath")"
    local new_fpath
    new_fpath="$(dirname "$fpath")/$new_basename"

    if [ "$fpath" != "$new_fpath" ]; then
        info "Renaming product makefile: $old_basename -> $new_basename"
        if mv -f "$fpath" "$new_fpath"; then
        local ap_path="$devdir/AndroidProducts.mk"
        if [ -f "$ap_path" ]; then
            info "Updating AndroidProducts.mk to use $new_basename"
            replace_file_regex "$ap_path" "s/$old_basename/$new_basename/g"
        else
            warn "AndroidProducts.mk not found in $devdir, cannot update reference to product makefile."
        fi
        echo "$new_fpath"
        else
        warn "Failed to rename product makefile."
        echo "$fpath"
        return 1
        fi
    else
        echo "$fpath"
    fi
        
    return 0
}

edit_boardconfig_common() {
    local cdir="$1"
    local bc="$cdir/BoardConfigCommon.mk"
    if [ ! -f "$bc" ]; then
        warn "BoardConfigCommon.mk not found in $cdir; skipping."
        return 1
    fi
    info "Editing $bc"
    bak "$bc"
    replace_file_regex "$bc" "s#vendor/[^/]+/config/device_framework_matrix\\.xml#vendor/${ROM_PREFIX}/config/device_framework_matrix.xml#g"
    replace_file_regex "$bc" \
        "s#^-include\\s+vendor/[^/]+/config/BoardConfigReservedSize.mk#-include vendor/${ROM_PREFIX}/config/BoardConfigReservedSize.mk#m"

    return 0
}

edit_boardconfig_device() {
    local ddir="$1"
    local bc="$ddir/BoardConfig.mk"

    if [ ! -f "$bc" ]; then
        warn "BoardConfig.mk not found in $ddir; skipping BoardConfig changes."
        return 1
    fi
    info "Editing $bc"
    bak "$bc"
    replace_file_regex "$bc" "s#vendor/[^/]+/config/device_framework_matrix\\.xml#vendor/${ROM_PREFIX}/config/device_framework_matrix.xml#g"
    replace_file_regex "$bc" \
        "s#^-include\\s+vendor/[^/]+/config/BoardConfigReservedSize.mk#-include vendor/${ROM_PREFIX}/config/BoardConfigReservedSize.mk#m"

    return 0
}


handle_sepolicy_include() {
    local search_paths=()
    search_paths+=("$DEVICE_DIR")
    if [ -n "$COMMON_PATH" ]; then search_paths+=("$COMMON_PATH"); fi
    local matches=()
    for p in "${search_paths[@]}"; do
        while IFS= read -r line; do
        matches+=("$line")
        done < <(grep -R -H --line-number -E "sepolicy/libperfmgr/sepolicy.mk" "$p" 2>/dev/null || true)
    done

    if [ "${#matches[@]}" -eq 0 ]; then
        info "No sepolicy libperfmgr include lines found; skipping sepolicy step."
        return 0
    fi

    info "Found sepolicy include occurrences. Determine whether ROM uses lineage sepolicy."
    if prompt_yesno "Does the ROM use lineage sepolicy (i.e., include paths under device/.../sepolicy referencing lineage)? (y/n)"; then
        POLICY_PREFIX="lineage"
    else
        POLICY_PREFIX="$ROM_PREFIX"
    fi

    for m in "${matches[@]}"; do
        local file_line="${m#*:}"
        local file="${m%%:*}"
        bak "$file"
        replace_file_regex "$file" "s#device/[^/]+/sepolicy/libperfmgr/sepolicy.mk#device/${POLICY_PREFIX}/sepolicy/libperfmgr/sepolicy.mk#g"
    done
    }

handle_overlays() {
    local base_search_paths=("$DEVICE_DIR")
    if [ -n "$COMMON_PATH" ]; then base_search_paths+=("$COMMON_PATH"); fi

    local overlay_dirs=()
    for p in "${base_search_paths[@]}"; do
        while IFS= read -r d; do overlay_dirs+=("$d"); done < <(find "$p" -maxdepth 2 -type d -name "overlay-*" 2>/dev/null || true)
    done
    if [ "${#overlay_dirs[@]}" -eq 0 ]; then
        info "No overlay-* folders found."
        return 0
    fi
    local expected_overlay
    if [ "$ROM_TYPE" = "lineage" ]; then
        expected_overlay="overlay-lineage"
    else
        expected_overlay="overlay-custom"
    fi

    info "Expected overlay directory name for this ROM: $expected_overlay"
    for od in "${overlay_dirs[@]}"; do
        local parent
        parent="$(dirname "$od")"
        local base
        base="$(basename "$od")"
        if [ "$base" = "$expected_overlay" ]; then
        info "Overlay $od already named correctly."
        continue
        fi

        info "Moving overlay $od -> $parent/$expected_overlay"
        if [ ! -d "$parent/$expected_overlay" ]; then
        mkdir -p "$parent/$expected_overlay"
        fi
        shopt -s dotglob
        for item in "$od"/*; do
        [ -e "$item" ] || continue
        mv -f "$item" "$parent/$expected_overlay/" || true
        done
        shopt -u dotglob
        rmdir --ignore-fail-on-non-empty "$od" || true
        local makefile_candidates=()
        if [ -n "$PLATFORM" ]; then
        if [ -n "$COMMON_PATH" ] && [ -f "$COMMON_PATH/${PLATFORM}.mk" ]; then
            makefile_candidates+=("$COMMON_PATH/${PLATFORM}.mk")
        fi
        if [ -f "$DEVICE_DIR/${PLATFORM}.mk" ]; then
            makefile_candidates+=("$DEVICE_DIR/${PLATFORM}.mk")
        fi
        fi
        if [ -f "$DEVICE_DIR/device.mk" ]; then
            makefile_candidates+=("$DEVICE_DIR/device.mk")
        fi
        while IFS= read -r mf; do makefile_candidates+=("$mf"); done < <(grep -RIl --null --line-break --exclude-dir=out -e "DEVICE_PACKAGE_OVERLAYS" -e "PRODUCT_PACKAGE_OVERLAYS" "$DEVICE_DIR" 2>/dev/null || true)

        for mf in "${makefile_candidates[@]}"; do
        [ -f "$mf" ] || continue
        info "Updating overlays in $mf"
        bak "$mf"
        replace_file_regex "$mf" "s#overlay-[a-zA-Z0-9_-]+#${expected_overlay}#g"
        done
    done
    }

fix_dependency_filenames() {
    local base_paths=("$DEVICE_DIR")
    if [ -n "$COMMON_PATH" ]; then base_paths+=("$COMMON_PATH"); fi
    for p in "${base_paths[@]}"; do
        while IFS= read -r f; do
        local b=$(basename "$f")
        if [ "$b" = "lineage.dependencies" ]; then
            local newname="${p}/${ROM_PREFIX}.dependencies"
            info "Renaming $f -> $newname"
            bak "$f"
            mv -f "$f" "$newname"
            perl -0777 -i.bak -pe "s/lineage\\.dependencies/${ROM_PREFIX}.dependencies/g" $(grep -RIl --exclude-dir=.git "lineage.dependencies" "$p" 2>/dev/null || true) || true
        fi
        done < <(find "$p" -type f -name "lineage.dependencies" 2>/dev/null || true)
    done
}

main_bringup_logic() {
    local env_mode=false
    if [ "$1" = "env" ]; then
        env_mode=true
    fi
    local CODENAME PLATFORM HAVE_COMMON COMMON_DIR ROM_TYPE ROM_PREFIX ROM_LINEAGE_ANS INPUT_ROM_NAME DEVICE_DIR COMMON_PATH=""

    if [ "$env_mode" = true ]; then
        warn "Running in non-interactive environment mode."
        CODENAME=${BRINGUP_CODENAME:?"BRINGUP_CODENAME must be set in environment mode."}
        HAVE_COMMON=${BRINGUP_HAVE_COMMON:?"BRINGUP_HAVE_COMMON must be set to y/n in environment mode."}
        ROM_TYPE=${BRINGUP_ROM_TYPE:?"BRINGUP_ROM_TYPE must be set to lineage/other in environment mode."}

        if [ "$HAVE_COMMON" = "y" ] || [ "$HAVE_COMMON" = "yes" ]; then
        HAVE_COMMON=yes
        PLATFORM=${BRINGUP_PLATFORM:?"BRINGUP_PLATFORM must be set in environment mode when HAVE_COMMON is yes."}
        COMMON_DIR="${PLATFORM}-common"
        else
        HAVE_COMMON=no
        PLATFORM=""
        COMMON_DIR=""
        fi

        if [ "$ROM_TYPE" = "lineage" ]; then
        ROM_PREFIX="lineage"
        else
        ROM_PREFIX=${BRINGUP_ROM_PREFIX:?"BRINGUP_ROM_PREFIX must be set in environment mode for non-lineage ROMs."}
        fi
    else
        read -rp "Enter device codename (e.g. phoenix): " CODENAME
        CODENAME=${CODENAME:-}

        if prompt_yesno "Do you have a separate common tree for this device? (y/n)"; then
        HAVE_COMMON=yes
        read -rp "Enter platform name (e.g. sm6150): " PLATFORM
        if [ -z "$PLATFORM" ]; then
            err "Platform required when common tree exists."
            exit 1
        fi
        COMMON_DIR="${PLATFORM}-common"
        else
        HAVE_COMMON=no
        COMMON_DIR=""
        PLATFORM=""
        fi

    while true; do
        read -rp "Is the ROM lineage-based? (y/n): " ROM_LINEAGE_ANS
        ROM_LINEAGE_ANS="${ROM_LINEAGE_ANS,,}"
        if [ "$ROM_LINEAGE_ANS" = "y" ] || [ "$ROM_LINEAGE_ANS" = "yes" ]; then
            ROM_TYPE="lineage"
            ROM_PREFIX="lineage"
            break
        elif [ "$ROM_LINEAGE_ANS" = "n" ] || [ "$ROM_LINEAGE_ANS" = "no" ]; then
        ROM_TYPE="other"
        read -rp "Enter ROM name/prefix (e.g. infinity, pixelos, clover, google): " INPUT_ROM_NAME
        INPUT_ROM_NAME="${INPUT_ROM_NAME,,}"
        case "$INPUT_ROM_NAME" in
            "pixelos" | "pixel") ROM_PREFIX="aosp" ;;
            clover) ROM_PREFIX="clover" ;;
            google) ROM_PREFIX="aosp" ;;
            "infinity" | "infinityx") ROM_PREFIX="infinity" ;;
            "miku" | "mikuui") ROM_PREFIX="miku";;
            "") err "ROM name required."; continue ;;
          *) ROM_PREFIX="$INPUT_ROM_NAME" ;;
        esac
        break
        else
            echo "Please answer y or n."
        fi
        done
    fi

    if [ -z "$CODENAME" ]; then
        err "Codename required."
        exit 1
    fi

    info "Codename: $CODENAME"
    info "Common tree separate: $HAVE_COMMON"
    if [ -n "$COMMON_DIR" ]; then info "Common dir expected: $COMMON_DIR"; fi
    info "ROM type: $ROM_TYPE (prefix: $ROM_PREFIX)"

    DEVICE_DIR_CANDIDATE="./$CODENAME"
    if [ -d "$DEVICE_DIR_CANDIDATE" ]; then
        DEVICE_DIR="$DEVICE_DIR_CANDIDATE"
    else
        read -rp "Device dir not found at ./$CODENAME. Enter device tree directory path: " DEVICE_DIR
        if [ ! -d "$DEVICE_DIR" ]; then err "Device dir not found: $DEVICE_DIR"; exit 1; fi
    fi
    info "Device dir: $DEVICE_DIR"

    if [ "$HAVE_COMMON" = "yes" ]; then
        if [ -d "./$COMMON_DIR" ]; then
            COMMON_PATH="./$COMMON_DIR"
    else
        read -rp "Common dir not found at ./$COMMON_DIR. Enter common dir path: " COMMON_PATH
        if [ ! -d "$COMMON_PATH" ]; then err "Common dir not found: $COMMON_PATH"; exit 1; fi
    fi
        info "Common dir: $COMMON_PATH"
    fi

    if [ "$HAVE_COMMON" = "yes" ]; then
        edit_boardconfig_common "$COMMON_PATH" || true
    else
        edit_boardconfig_device "$DEVICE_DIR" || true
    fi

    product_mk_file="$(get_product_makefile_from_AndroidProducts "$DEVICE_DIR" || true)"
    if [ -z "$product_mk_file" ]; then
    warn "Could not auto-detect product makefile from AndroidProducts.mk. Searching for *.mk in $DEVICE_DIR..."
    product_mk_file="$(find "$DEVICE_DIR" -maxdepth 2 -type f -name "*${CODENAME}*.mk" -print -quit || true)"
    if [ -z "$product_mk_file" ]; then
        read -rp "Could not find product makefile automatically. Enter product makefile path (relative or absolute): " product_mk_file
    fi
    fi

    if [ -n "$product_mk_file" ]; then
    new_product_mk_file=$(edit_product_makefile "$DEVICE_DIR" "$product_mk_file")
    if [ $? -eq 0 ]; then
        product_mk_file="$new_product_mk_file"
    else
        warn "Failed to edit product makefile."
    fi
    else
    warn "Skipping product makefile edits."
    fi

    handle_sepolicy_include || true
    handle_overlays || true
    fix_dependency_filenames || true

    if [ "$HAVE_COMMON" = "no" ]; then
    info "No separate common tree: ensuring device-level BoardConfig.mk and device.mk reflect changes."
    edit_boardconfig_device "$DEVICE_DIR" || true
    fi

    info "Bringup edits complete. Summary of actions:"
    echo "- Device directory: $DEVICE_DIR"
    if [ -n "$COMMON_PATH" ]; then echo "- Common directory: $COMMON_PATH"; fi
    echo "- ROM prefix used: $ROM_PREFIX"
    echo "- Product makefile edited (if found): ${product_mk_file:-not-found}"
    echo "- BoardConfig edits applied where possible"
    echo "- Overlay folders checked and moved if necessary"
    echo "- Backups created as *.bak next to edited files"
    echo "Now please Add the Neccsarry flags"
    echo
}

if [ ! -t 1 ]; then
    GREEN=""
    YELLOW=""
    RED=""
    NC=""
fi

print_banner

if [ $# -eq 0 ]; then
    main_bringup_logic "interactive"
    exit 0
fi

while [ $# -gt 0 ]; do
    case "$1" in
    -h|--help)
        show_help
        exit 0
        ;;
    -l|--list-roms)
        list_supported_roms
        exit 0
        ;;
    -m|--env)
        main_bringup_logic "env"
        shift
        ;;
    -n|--new-rom)
        if [ -z "$2" ] || [ -z "$3" ]; then
            err "The -n|--new-rom flag requires two arguments: <rom_name> and <rom_prefix>"
            show_help
        exit 1
        fi
        add_new_rom "$2" "$3"
        shift 3 
        ;;
    *)
        err "Unknown option: $1"
        show_help
        exit 1
        ;;
    esac
done