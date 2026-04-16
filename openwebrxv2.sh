#!/bin/bash
set -eo pipefail
set -u

#========================
# Version
#========================
VERSION="4.4.4"

#========================
# Color Codes
#========================
RED=$'\033[31m'
BOLD=$'\033[1m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[33m'
GRAY=$'\033[90m'
NC=$'\033[0m'

#========================
# Log & Manifest Files
#========================
LOG_FILE="/var/log/openwebrx_install.log"
MANIFEST_FILE="/var/log/openwebrx_install_manifest.log"
touch "$LOG_FILE" "$MANIFEST_FILE" 2>/dev/null || { echo "Cannot create log files. Exiting."; exit 1; }
exec > >(tee -a "$LOG_FILE") 2>&1

#========================
# Helper functions
#========================
log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
log_manifest() { echo "$(date +'%Y-%m-%d %H:%M:%S') | $2 | $1" >> "$MANIFEST_FILE"; }

#========================
# Cleanup trap
#========================
cleanup() {
    if [ $? -ne 0 ]; then
        echo "Installation interrupted. Check log: $LOG_FILE"
    fi
}
trap cleanup EXIT INT TERM

#========================
# Ask for sudo upfront
#========================
sudo -v || { log "Sudo required. Exiting."; exit 1; }

#========================
# Noninteractive apt
#========================
export DEBIAN_FRONTEND=noninteractive
APT_INSTALL="sudo DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install"

#========================
# Get system info (for right box)
#========================
get_system_info() {
    hostname=$(hostname)
    ip=$(hostname -I | awk '{print $1}')
    os=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
    openwebrx_status=$(systemctl is-active openwebrx 2>/dev/null || echo "not installed")
    codecserver_status=$(systemctl is-active codecserver 2>/dev/null || echo "not installed")

    if [[ "$openwebrx_status" == "active" ]]; then
        openwebrx_status_colored="${GREEN}active${NC}"
    else
        openwebrx_status_colored="${RED}not installed${NC}"
    fi

    if [[ "$codecserver_status" == "active" ]]; then
        codecserver_status_colored="${GREEN}active${NC}"
    else
        codecserver_status_colored="${RED}not installed${NC}"
    fi
}

#========================
# Banner
#========================
show_banner() {
    clear
    echo "${BOLD}${RED}=========================================${NC}"
    echo "${BOLD}${RED}     OpenWebRX+ Installer v$VERSION${NC}"
    echo "${BOLD}${RED}=========================================${NC}"
    echo ""
}

#========================
# Print two columns (menu left, info right)
#========================
print_two_columns() {
    local left_lines=("$@")
    local right_lines=(
        "${BOLD}System Information${NC}"
        "Hostname: $hostname"
        "IP: $ip"
        "OS: $os"
        "OpenWebRX: $openwebrx_status_colored"
        "Codecserver: $codecserver_status_colored"
    )
    local max_lines=$((${#left_lines[@]} > ${#right_lines[@]} ? ${#left_lines[@]} : ${#right_lines[@]}))
    for ((i=0; i<max_lines; i++)); do
        left="${left_lines[$i]:-}"
        right="${right_lines[$i]:-}"
        printf "%-65s %s\n" "$left" "$right"
    done
}

#========================
# Core OpenWebRX+ install (with repo detection)
#========================
install_openwebrx_core() {
    echo ""
    log "Starting OpenWebRX+ core installation..."
    OS_ID=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    VERSION_CODENAME=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
    echo "Detected: $OS_ID $VERSION_CODENAME"
    case "$OS_ID" in
        ubuntu)
            case "$VERSION_CODENAME" in
                jammy|noble)
                    curl -s https://luarvique.github.io/ppa/openwebrx-plus.gpg | sudo gpg --dearmor -o /usr/share/keyrings/openwebrx-plus.gpg
                    echo "deb [signed-by=/usr/share/keyrings/openwebrx-plus.gpg] https://luarvique.github.io/ppa/${VERSION_CODENAME} ./" | sudo tee /etc/apt/sources.list.d/openwebrx-plus.list
                    if [ "$VERSION_CODENAME" = "jammy" ]; then
                        curl -s https://repo.openwebrx.de/debian/key.gpg.txt | sudo gpg --dearmor -o /usr/share/keyrings/openwebrx.gpg
                        echo "deb [signed-by=/usr/share/keyrings/openwebrx.gpg] https://repo.openwebrx.de/ubuntu/ jammy main" | sudo tee /etc/apt/sources.list.d/openwebrx.list
                    fi
                    ;;
                *) echo "Unsupported Ubuntu version: $VERSION_CODENAME"; return 1 ;;
            esac ;;
        debian)
            case "$VERSION_CODENAME" in
                bullseye|bookworm)
                    curl -s https://luarvique.github.io/ppa/openwebrx-plus.gpg | sudo gpg --dearmor -o /usr/share/keyrings/openwebrx-plus.gpg
                    echo "deb [signed-by=/usr/share/keyrings/openwebrx-plus.gpg] https://luarvique.github.io/ppa/${VERSION_CODENAME} ./" | sudo tee /etc/apt/sources.list.d/openwebrx-plus.list
                    if [ "$VERSION_CODENAME" = "bullseye" ]; then
                        curl -s https://repo.openwebrx.de/debian/key.gpg.txt | sudo gpg --dearmor -o /usr/share/keyrings/openwebrx.gpg
                        echo "deb [signed-by=/usr/share/keyrings/openwebrx.gpg] https://repo.openwebrx.de/debian/ bullseye main" | sudo tee /etc/apt/sources.list.d/openwebrx.list
                    fi
                    ;;
                *) echo "Unsupported Debian version: $VERSION_CODENAME"; return 1 ;;
            esac ;;
        *) echo "Unsupported OS: $OS_ID"; return 1 ;;
    esac
    echo "Updating package lists..."
    sudo apt update -y || { echo "apt update failed"; return 1; }
    echo "Installing openwebrx package..."
    $APT_INSTALL openwebrx || { echo "Installation failed"; return 1; }
    sudo systemctl enable openwebrx
    sudo systemctl restart openwebrx
    log_manifest "OpenWebRX+" "INSTALLED"
    log "OpenWebRX+ core installation completed successfully"
    echo "[OK] OpenWebRX+ installed. Access at http://$ip:8073"
    echo ""
    read -p "Do you want to create an admin user now? (y/n): " create_user
    if [[ "$create_user" =~ ^[Yy]$ ]]; then
        add_user_interactive
    else
        echo "You can manage users later using the main menu option 8."
    fi
    return 0
}

#========================
# Module definitions (single source of truth)
#========================
declare -A MODULE_GIT
declare -A MODULE_BRANCH
declare -A MODULE_DEPS
declare -A MODULE_CMAKE_FLAGS
declare -A MODULE_TYPE          # cmake, make, debian, special
declare -A MODULE_BUILD_CMD     # override for nonâ€‘cmake
declare -A MODULE_INSTALL_CMD   # override for install
declare -A MODULE_BINARIES      # spaceâ€‘separated list of binary paths
declare -A MODULE_CONFIGS       # config files/dirs to remove (optional)
declare -A MODULE_EXTRA_CMDS    # extra commands before build
declare -A MODULE_UNINSTALL_EXTRA  # extra commands after uninstall

# SatDump
MODULE_GIT["SatDump"]="https://github.com/SatDump/SatDump.git"
MODULE_DEPS["SatDump"]="git build-essential cmake g++ pkgconf libfftw3-dev libpng-dev libtiff-dev libjemalloc-dev libcurl4-openssl-dev libvolk-dev libnng-dev libglfw3-dev zenity portaudio19-dev libzstd-dev libhdf5-dev librtlsdr-dev libhackrf-dev libairspy-dev libairspyhf-dev libad9361-dev libiio-dev libbladerf-dev libomp-dev ocl-icd-opencl-dev intel-opencl-icd mesa-opencl-icd libdbus-1-dev libarmadillo-dev libsqlite3-dev"
MODULE_TYPE["SatDump"]="cmake"
MODULE_CMAKE_FLAGS["SatDump"]="-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr"
MODULE_BINARIES["SatDump"]="/usr/bin/satdump /usr/local/bin/satdump"
MODULE_UNINSTALL_EXTRA["SatDump"]="if [ -d /opt/SatDump/build ]; then (cd /opt/SatDump/build && sudo make uninstall) 2>/dev/null || true; fi"

# dump1090
MODULE_GIT["dump1090"]="https://github.com/flightaware/dump1090.git"
MODULE_DEPS["dump1090"]="build-essential fakeroot debhelper librtlsdr-dev pkg-config libncurses5-dev libbladerf-dev libhackrf-dev liblimesuite-dev libsoapysdr-dev devscripts"
MODULE_TYPE["dump1090"]="make"
MODULE_BUILD_CMD["dump1090"]="make"
MODULE_INSTALL_CMD["dump1090"]="sudo install -Dm755 dump1090 /usr/bin/dump1090"
MODULE_BINARIES["dump1090"]="/usr/bin/dump1090"

# APRS Symbols (special)
MODULE_TYPE["APRS Symbols"]="special"
MODULE_UNINSTALL_EXTRA["APRS Symbols"]="sudo rm -rf /usr/share/aprs-symbols"

# MSK144Decoder
MODULE_GIT["MSK144Decoder"]="https://github.com/alexander-sholohov/msk144decoder.git"
MODULE_DEPS["MSK144Decoder"]="build-essential cmake gfortran libfftw3-dev libboost-dev libcurl4-openssl-dev"
MODULE_TYPE["MSK144Decoder"]="cmake"
MODULE_CMAKE_FLAGS["MSK144Decoder"]=".. -DCMAKE_BUILD_TYPE=Release"
MODULE_EXTRA_CMDS["MSK144Decoder"]="git submodule init && git submodule update --progress"
MODULE_BINARIES["MSK144Decoder"]="/usr/local/bin/msk144decoder"

# M17-cxx-demod
MODULE_GIT["M17-cxx-demod"]="https://github.com/mobilinkd/m17-cxx-demod.git"
MODULE_DEPS["M17-cxx-demod"]="build-essential cmake libcodec2-dev libboost-program-options-dev libgtest-dev git"
MODULE_TYPE["M17-cxx-demod"]="cmake"
MODULE_CMAKE_FLAGS["M17-cxx-demod"]=".. -DCMAKE_BUILD_TYPE=Release"
MODULE_EXTRA_CMDS["M17-cxx-demod"]="git submodule init && git submodule update --progress"
MODULE_BINARIES["M17-cxx-demod"]="/usr/local/bin/m17-demod"

# RADAE Decoder (special due to missing 'make install')
MODULE_GIT["RADAE Decoder"]="https://github.com/peterbmarks/radae_decoder.git"
MODULE_DEPS["RADAE Decoder"]="build-essential cmake libasound2-dev pkg-config autoconf automake libtool libpulse-dev"
MODULE_TYPE["RADAE Decoder"]="special"
MODULE_BINARIES["RADAE Decoder"]="/usr/local/bin/webrx_rade_decode"
MODULE_UNINSTALL_EXTRA["RADAE Decoder"]="sudo rm -f /usr/local/bin/webrx_rade_decode"

# freedv_rx (special â€“ builds codec2 and installs freedv_rx)
MODULE_GIT["freedv_rx"]="https://github.com/drowe67/codec2.git"
MODULE_DEPS["freedv_rx"]="build-essential cmake libfftw3-dev"
MODULE_TYPE["freedv_rx"]="special"
MODULE_BINARIES["freedv_rx"]="/usr/local/bin/freedv_rx"
MODULE_UNINSTALL_EXTRA["freedv_rx"]="sudo rm -f /usr/local/bin/freedv_rx"

# CodecServer SoftMBE (special Debian build)
MODULE_GIT["CodecServer-SoftMBE"]="https://github.com/knatterfunker/codecserver-softmbe.git"
MODULE_DEPS["CodecServer-SoftMBE"]="git build-essential debhelper cmake libprotobuf-dev protobuf-compiler libcodecserver-dev"
MODULE_TYPE["CodecServer-SoftMBE"]="debian"
MODULE_BUILD_CMD["CodecServer-SoftMBE"]="sudo sed -i 's/dh \$@/dh \$@ --dpkg-shlibdeps-params=--ignore-missing-info/' debian/rules; dpkg-buildpackage -uc -us"
MODULE_INSTALL_CMD["CodecServer-SoftMBE"]="sudo dpkg -i ../codecserver-driver-softmbe_0.0.1_*.deb"
MODULE_BINARIES["CodecServer-SoftMBE"]=""
MODULE_UNINSTALL_EXTRA["CodecServer-SoftMBE"]="sudo dpkg -r libmbe1 libmbe-dev 2>/dev/null || true; sudo dpkg -r codecserver-driver-softmbe 2>/dev/null || true; sudo sed -i '/\\[device:softmbe\\]/,+1d' /etc/codecserver/codecserver.conf 2>/dev/null || true"

# List of all modules (for menus and uninstall)
ALL_MODULES=(
    "OpenWebRX+"
    "SatDump"
    "dump1090"
    "APRS Symbols"
    "MSK144Decoder"
    "M17-cxx-demod"
    "RADAE Decoder"
    "freedv_rx"
    "CodecServer-SoftMBE"
)

#========================
# Generic module installer (dispatches by type)
#========================
install_module() {
    local name="$1"
    local git_url="${MODULE_GIT[$name]:-}"
    local branch="${MODULE_BRANCH[$name]:-}"
    local deps="${MODULE_DEPS[$name]:-}"
    local type="${MODULE_TYPE[$name]:-}"
    local cmake_flags="${MODULE_CMAKE_FLAGS[$name]:-}"
    local build_cmd="${MODULE_BUILD_CMD[$name]:-}"
    local install_cmd="${MODULE_INSTALL_CMD[$name]:-}"
    local extra_cmds="${MODULE_EXTRA_CMDS[$name]:-}"

    echo "Installing $name..."
    if [ -n "$deps" ]; then
        $APT_INSTALL $deps || { echo "[-] Failed to install dependencies for $name"; return 1; }
    fi

    case "$type" in
        cmake)
            cd /opt
            [ -d "$name" ] && sudo rm -rf "$name"
            git clone "$git_url" "$name"
            cd "$name"
            [ -n "$branch" ] && git checkout "$branch"
            if [ -n "$extra_cmds" ]; then
                eval "$extra_cmds"
            fi
            mkdir -p build && cd build
            eval "cmake $cmake_flags .." || { echo "[-] CMake failed for $name"; return 1; }
            make -j$(nproc) || { echo "[-] Make failed for $name"; return 1; }
            sudo make install
            ;;
        make)
            cd /opt
            [ -d "$name" ] && sudo rm -rf "$name"
            git clone "$git_url" "$name"
            cd "$name"
            eval "$build_cmd" || { echo "[-] Build failed for $name"; return 1; }
            if [ -n "$install_cmd" ]; then
                eval "$install_cmd" || { echo "[-] Install failed for $name"; return 1; }
            else
                sudo make install
            fi
            ;;
        debian)
            cd /opt
            # Special: mbelib dependency for softmbe
            if [ "$name" = "CodecServer-SoftMBE" ]; then
                cd /opt
                [ -d mbelib ] && sudo rm -rf mbelib
                git clone https://github.com/szechyjs/mbelib.git
                cd mbelib
                dpkg-buildpackage -uc -us
                cd ..
                sudo dpkg -i libmbe1_1.3.0_*.deb libmbe-dev_1.3.0_*.deb
            fi
            [ -d "$name" ] && sudo rm -rf "$name"
            git clone "$git_url" "$name"
            cd "$name"
            eval "$build_cmd" || { echo "[-] Build failed for $name"; return 1; }
            eval "$install_cmd" || { echo "[-] Install failed for $name"; return 1; }
            # Post-install config for softmbe
            if [ "$name" = "CodecServer-SoftMBE" ]; then
                if ! grep -q "\[device:softmbe\]" /etc/codecserver/codecserver.conf 2>/dev/null; then
                    sudo tee -a /etc/codecserver/codecserver.conf > /dev/null << _EOF_

[device:softmbe]
driver=softmbe
_EOF_
                fi
                sudo systemctl restart codecserver
            fi
            ;;
        special)
            case "$name" in
                "APRS Symbols")
                    sudo git clone https://github.com/hessu/aprs-symbols /usr/share/aprs-symbols 2>/dev/null || true
                    ;;
                "RADAE Decoder")
                    cd /opt
                    [ -d radae_decoder ] && sudo rm -rf radae_decoder
                    git clone "$git_url" radae_decoder
                    cd radae_decoder
                    mkdir -p build && cd build
                    cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_GUI=OFF ..
                    make -j$(nproc)
                    if [ -f tools/webrx_rade_decode ]; then
                        sudo install -m 0755 tools/webrx_rade_decode /usr/local/bin/
                        echo "[OK] RADAE Decoder installed."
                    else
                        echo "[-] RADAE Decoder build failed (binary not found)."
                        return 1
                    fi
                    ;;
                "freedv_rx")
                    cd /opt
                    [ -d freedv_rx_build ] && sudo rm -rf freedv_rx_build
                    git clone "$git_url" freedv_rx_build
                    cd freedv_rx_build
                    mkdir -p build && cd build
                    cmake .. || { echo "[-] CMake failed for freedv_rx"; return 1; }
                    make -j$(nproc) || { echo "[-] Make failed for freedv_rx"; return 1; }
                    sudo make install
                    # Manually copy freedv_rx binary
                    if [ -f src/freedv_rx ]; then
                        sudo install -m 0755 src/freedv_rx /usr/local/bin/
                    elif [ -f ../src/freedv_rx ]; then
                        sudo install -m 0755 ../src/freedv_rx /usr/local/bin/
                    else
                        echo "[-] freedv_rx binary not found after build."
                        return 1
                    fi
                    ;;
                *)
                    echo "[-] Unknown special module: $name"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo "[-] Unknown module type for $name"
            return 1
            ;;
    esac

    if [ $? -eq 0 ]; then
        log_manifest "$name" "INSTALLED"
        echo "[OK] $name installed."
        return 0
    else
        echo "[-] $name installation failed."
        return 1
    fi
}

#========================
# Generic uninstaller
#========================
uninstall_module() {
    local name="$1"
    local binaries="${MODULE_BINARIES[$name]:-}"
    local extra="${MODULE_UNINSTALL_EXTRA[$name]:-}"

    echo "Removing $name..."
    # Remove binaries
    for bin in $binaries; do
        sudo rm -f "$bin"
    done
    # Run extra cleanup commands (e.g., dpkg -r, config removal)
    if [ -n "$extra" ]; then
        eval "$extra"
    fi
    # For cmake modules, try make uninstall from build directory
    if [ "${MODULE_TYPE[$name]}" = "cmake" ] && [ -d "/opt/$name/build" ]; then
        (cd "/opt/$name/build" && sudo make uninstall) 2>/dev/null || true
    fi
    # For freedv_rx special build, also remove the source directory
    if [ "$name" = "freedv_rx" ] && [ -d "/opt/freedv_rx_build" ]; then
        sudo rm -rf /opt/freedv_rx_build
    fi
    log_manifest "$name" "REMOVED"
    echo "[OK] $name removed."
}

#========================
# Full install (option 2)
#========================
full_install() {
    install_openwebrx_core
    for mod in "${ALL_MODULES[@]}"; do
        if [ "$mod" != "OpenWebRX+" ]; then
            install_module "$mod"
        fi
    done
    restart_services
    echo "[OK] Full installation completed."
}

#========================
# Advanced install submenu (option 3)
#========================
advanced_install() {
    local modules=()
    for mod in "${ALL_MODULES[@]}"; do
        [ "$mod" != "OpenWebRX+" ] && modules+=("$mod")
    done
    while true; do
        clear
        echo "${BOLD}${YELLOW}=== Advanced Install - Select Modules ===${NC}"
        echo ""
        for i in "${!modules[@]}"; do
            echo "$((i+1))) ${modules[$i]}"
        done
        echo "0) Back to main menu"
        echo ""
        read -p "Enter numbers (space separated): " -a choices
        need_restart=false
        for c in "${choices[@]}"; do
            if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#modules[@]} ]; then
                install_module "${modules[$((c-1))]}" && need_restart=true
            elif [ "$c" -eq 0 ]; then
                return
            else
                echo "Invalid choice: $c"
            fi
        done
        if [ "$need_restart" = true ]; then
            restart_services
        fi
        read -n1 -rsp $'Press any key to continue...\n'
    done
}

#========================
# Uninstall submenu (option 4)
#========================
uninstall_submenu() {
    # Read manifest to see which modules are installed
    declare -A installed
    if [ -f "$MANIFEST_FILE" ]; then
        while IFS='|' read -r date action module; do
            module=$(echo "$module" | sed 's/^ //;s/ $//')
            if [[ "$action" == *"INSTALLED"* ]] && [[ "$module" != "OpenWebRX User"* ]]; then
                installed["$module"]=1
            fi
        done < "$MANIFEST_FILE"
    fi

    local uninstall_list=()
    for mod in "${ALL_MODULES[@]}"; do
        if [[ -n "${installed[$mod]:-}" ]]; then
            uninstall_list+=("$mod")
        fi
    done

    if [ ${#uninstall_list[@]} -eq 0 ]; then
        echo "No installed modules found."
        read -n1 -rsp $'Press any key to continue...\n'
        return
    fi

    while true; do
        clear
        echo "${BOLD}${YELLOW}=== Uninstall Modules ===${NC}"
        echo ""
        for i in "${!uninstall_list[@]}"; do
            echo "$((i+1))) ${uninstall_list[$i]}"
        done
        echo "$(( ${#uninstall_list[@]} + 1 ))) Remove All (complete cleanup)"
        echo "0) Back to main menu"
        echo ""
        read -p "Enter number to uninstall: " uc

        if [[ "$uc" == "0" ]]; then
            return
        fi

        local remove_all_num=$(( ${#uninstall_list[@]} + 1 ))
        if [[ "$uc" == "$remove_all_num" ]]; then
            echo "This will remove EVERYTHING installed by this script."
            read -p "Are you sure? Type 'yes' to continue: " confirm
            if [[ "$confirm" == "yes" ]]; then
                for mod in "${uninstall_list[@]}"; do
                    if [ "$mod" = "OpenWebRX+" ]; then
                        uninstall_openwebrx_core
                    else
                        uninstall_module "$mod"
                    fi
                done
                echo "Full cleanup completed."
                restart_services
            fi
            read -n1 -rsp $'Press any key to continue...\n'
            return
        fi

        if [[ "$uc" =~ ^[0-9]+$ ]] && [ "$uc" -ge 1 ] && [ "$uc" -le ${#uninstall_list[@]} ]; then
            local idx=$((uc-1))
            local mod="${uninstall_list[$idx]}"
            read -p "Are you sure you want to uninstall $mod? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                if [ "$mod" = "OpenWebRX+" ]; then
                    uninstall_openwebrx_core
                else
                    uninstall_module "$mod"
                fi
                restart_services
            fi
        else
            echo "Invalid choice."
        fi
        read -n1 -rsp $'Press any key to continue...\n'
        break
    done
}

#========================
# Special uninstall for OpenWebRX+ core (not a module in the array)
#========================
uninstall_openwebrx_core() {
    echo "Removing OpenWebRX+..."
    sudo apt-get remove -y openwebrx || true
    sudo rm -f /etc/apt/sources.list.d/openwebrx*.list
    sudo rm -f /usr/share/keyrings/openwebrx*.gpg
    sudo apt-get update
    log_manifest "OpenWebRX+" "REMOVED"
    echo "[OK] OpenWebRX+ removed."
}

#========================
# Restart Services (option 6)
#========================
restart_services() {
    echo "Restarting OpenWebRX+ service..."
    sudo systemctl restart openwebrx
    echo "Restarting Codecserver service..."
    sudo systemctl restart codecserver 2>/dev/null || echo "Codecserver not installed or not running."
    log_manifest "Services (openwebrx+codecserver)" "RESTARTED"
    echo "[OK] Services restarted."
}

#========================
# View Status (option 5)
#========================
view_status() {
    clear
    echo "${BOLD}${YELLOW}=== Module Installation Status ===${NC}"
    echo ""
    declare -A installed
    local openwebrx_user=""
    local last_install_timestamp=""
    local last_restart_timestamp=""
    if [ -f "$MANIFEST_FILE" ]; then
        while IFS='|' read -r date action module; do
            module=$(echo "$module" | sed 's/^ //;s/ $//')
            if [[ "$action" == *"INSTALLED"* ]]; then
                last_install_timestamp="$date"
                if [[ "$module" == "OpenWebRX User"* ]]; then
                    openwebrx_user=$(echo "$module" | sed -n 's/OpenWebRX User (\(.*\))/\1/p')
                else
                    installed["$module"]=1
                fi
            fi
            if [[ "$action" == *"RESTARTED"* ]]; then
                last_restart_timestamp="$date"
            fi
        done < "$MANIFEST_FILE"
    fi
    for mod in "${ALL_MODULES[@]}"; do
        if [[ -n "${installed[$mod]:-}" ]]; then
            echo -e "  ${GREEN}[+]${NC} $mod"
        else
            echo -e "  ${RED}[-]${NC} $mod"
        fi
    done
    if [ -n "$openwebrx_user" ]; then
        echo -e "  ${GREEN}[+]${NC} OpenWebRX User: $openwebrx_user"
    else
        echo -e "  ${RED}[-]${NC} OpenWebRX User"
    fi
    echo ""
    echo "Manifest file: $MANIFEST_FILE"
    if [ -n "$last_install_timestamp" ]; then
        echo "Last installation change: $last_install_timestamp"
    else
        echo "No installation records found."
    fi
    if [ -n "$last_restart_timestamp" ]; then
        echo "Last service restart:      $last_restart_timestamp"
    else
        echo "No service restart recorded yet."
    fi
    read -n1 -rsp $'Press any key to return to main menu...\n'
}

#========================
# Help screen (option 7)
#========================
show_help() {
    clear
    echo "${BOLD}${YELLOW}=== Help / About ===${NC}"
    echo ""
    echo "${BOLD}What this script does:${NC}"
    echo "  Installs/uninstalls OpenWebRX+ and a curated set of decoders."
    echo ""
    echo "${BOLD}Supported OS:${NC}"
    echo "  Ubuntu 22.04 (Jammy), 24.04 (Noble)"
    echo "  Debian 11 (Bullseye), 12 (Bookworm)"
    echo ""
    echo "${BOLD}Main options:${NC}"
    echo "  1) Core only            - OpenWebRX+ (web interface + builtâ€‘in decoders)"
    echo "  2) Full install         - Core + all extra decoders (SatDump, dump1090, etc.)"
    echo "  3) Advanced install     - Pick individual decoders"
    echo "  4) Uninstall            - Remove installed components"
    echo "  5) View Status          - Show what's installed"
    echo "  6) Restart Services     - Restart OpenWebRX and Codecserver"
    echo "  7) Help                 - This screen"
    echo "  8) User Management      - Add/remove OpenWebRX users, reset passwords"
    echo "  9) Exit"
    echo ""
    echo "${BOLD}Logs & manifests:${NC}"
    echo "  Log file:     $LOG_FILE"
    echo "  Manifest:     $MANIFEST_FILE"
    echo ""
    echo "${BOLD}After install:${NC}"
    echo "  Access OpenWebRX+ at http://<your-ip>:8073"
    echo ""
    echo "${BOLD}Need more help?${NC}"
    echo "  Check the project: https://github.com/luarvique/openwebrx-plus"
    echo ""
    read -n1 -rsp $'Press any key to return to main menu...\n'
}

#========================
# User Management Submenu (all functions)
#========================
user_management() {
    while true; do
        clear
        echo "${BOLD}${YELLOW}=== OpenWebRX User Management ===${NC}"
        echo ""
        echo "1) Add user"
        echo "2) Remove user"
        echo "3) Reset password"
        echo "4) List users"
        echo "5) Disable user"
        echo "6) Enable user"
        echo "7) Check if user exists"
        echo "0) Back to main menu"
        echo ""
        read -p "Choice [0-7]: " um_choice
        case $um_choice in
            1) add_user_interactive ;;
            2) remove_user_interactive ;;
            3) reset_password_interactive ;;
            4) list_users ;;
            5) disable_user_interactive ;;
            6) enable_user_interactive ;;
            7) user_exists_interactive ;;
            0) return ;;
            *) echo "Invalid choice"; sleep 1 ;;
        esac
        read -n1 -rsp $'Press any key to continue...\n'
    done
}

add_user_interactive() {
    echo ""
    read -p "Enter username: " username
    if [ -z "$username" ]; then
        echo "[-] No username entered."
        return
    fi
    echo "You will be prompted to set a password."
    sudo openwebrx admin adduser "$username"
    if [ $? -eq 0 ]; then
        echo "[OK] User '$username' created."
        log_manifest "OpenWebRX User ($username)" "INSTALLED"
    else
        echo "[-] User creation failed."
    fi
}

remove_user_interactive() {
    echo ""
    read -p "Enter username to remove: " username
    if [ -z "$username" ]; then
        echo "[-] No username entered."
        return
    fi
    read -p "Are you sure you want to remove user '$username'? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        sudo openwebrx admin removeuser "$username"
        if [ $? -eq 0 ]; then
            echo "[OK] User '$username' removed."
            log_manifest "OpenWebRX User ($username)" "REMOVED"
        else
            echo "[-] Failed to remove user."
        fi
    else
        echo "Operation cancelled."
    fi
}

reset_password_interactive() {
    echo ""
    read -p "Enter username: " username
    if [ -z "$username" ]; then
        echo "[-] No username entered."
        return
    fi
    echo "You will be prompted to set a new password."
    sudo openwebrx admin resetpassword "$username"
    if [ $? -eq 0 ]; then
        echo "[OK] Password reset for '$username'."
    else
        echo "[-] Password reset failed."
    fi
}

list_users() {
    echo ""
    echo "Enabled users:"
    sudo openwebrx admin listusers
}

disable_user_interactive() {
    echo ""
    read -p "Enter username to disable: " username
    if [ -z "$username" ]; then
        echo "[-] No username entered."
        return
    fi
    sudo openwebrx admin disableuser "$username"
    if [ $? -eq 0 ]; then
        echo "[OK] User '$username' disabled."
    else
        echo "[-] Failed to disable user."
    fi
}

enable_user_interactive() {
    echo ""
    read -p "Enter username to enable: " username
    if [ -z "$username" ]; then
        echo "[-] No username entered."
        return
    fi
    sudo openwebrx admin enableuser "$username"
    if [ $? -eq 0 ]; then
        echo "[OK] User '$username' enabled."
    else
        echo "[-] Failed to enable user."
    fi
}

user_exists_interactive() {
    echo ""
    read -p "Enter username to check: " username
    if [ -z "$username" ]; then
        echo "[-] No username entered."
        return
    fi
    sudo openwebrx admin hasuser "$username"
    if [ $? -eq 0 ]; then
        echo "[OK] User '$username' exists."
    else
        echo "[-] User '$username' does not exist."
    fi
}

#========================
# Main Menu
#========================
show_main_menu() {
    while true; do
        get_system_info
        show_banner
        menu_items=(
            "${YELLOW}1)${NC} Install OpenWebRX+ (core only)"
            "${YELLOW}2)${NC} Install OpenWebRX+ & All Decoders"
            "${YELLOW}3)${NC} Advanced Install (pick individual decoders)"
            "${YELLOW}4)${NC} Uninstall"
            "${YELLOW}5)${NC} View Status"
            "${YELLOW}6)${NC} Restart Services"
            "${YELLOW}7)${NC} Help"
            "${YELLOW}8)${NC} User Management"
            "${YELLOW}9)${NC} Exit"
        )
        print_two_columns "${menu_items[@]}"
        echo ""
        echo "${RED}${BOLD}Please Note:${NC} If you are unsure, please see the \"Help\" section."
        echo ""
        read -p "${BOLD}Choice [1-9]: ${NC}" choice
        case $choice in
            1) install_openwebrx_core; read -n1 -rsp $'Press any key to continue...\n' ;;
            2) full_install; read -n1 -rsp $'Press any key to continue...\n' ;;
            3) advanced_install ;;
            4) uninstall_submenu ;;
            5) view_status ;;
            6) restart_services; read -n1 -rsp $'Press any key to continue...\n' ;;
            7) show_help ;;
            8) user_management ;;
            9) echo "Exiting. Goodbye!"; exit 0 ;;
            *) echo "Invalid choice"; sleep 1 ;;
        esac
    done
}

#========================
# Entry Point
#========================
# Command-line arguments
if [[ $# -gt 0 ]]; then
    case "$1" in
        --full-install) full_install; exit 0 ;;
        --install-module) shift; install_module "$1"; exit 0 ;;
        --version) echo "OpenWebRX+ Installer v$VERSION"; exit 0 ;;
        *) echo "Unknown option. Usage: $0 [--full-install|--install-module <name>|--version]"; exit 1 ;;
    esac
fi

# Start interactive menu
show_main_menu
