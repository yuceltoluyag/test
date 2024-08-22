#!/bin/bash


# Renk kodları
YELLOW='\e[33m'
GREEN='\e[32m'
RED='\e[31m'
RESET='\e[0m'

# Log dosyası
LOGFILE="/var/log/disk_setup.log"

# Loglama fonksiyonu
log() {
    local message="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ${message}" >> "$LOGFILE"
}

# İlerleme göstergesi fonksiyonu
show_progress() {
    local message="$1"
    local duration="$2"  # Süreyi saniye cinsinden al
    echo -n "$message"
    for i in $(seq 0 "$duration"); do
        sleep 1
        echo -n "."
    done
    echo " Done!"
}

# Disk değişkenini ayarla
set_disk_variable() {
    local disk
    disk=$(lsblk -dn -o NAME,TYPE | grep disk | head -n 1 | awk '{print "/dev/" $1}')

    if [[ ! -b "$disk" ]]; then
        log "Hata: Geçersiz disk seçimi. Kurulum durduruluyor."
        printf "${RED}Hata: Geçersiz disk seçimi. Kurulum durduruluyor.${RESET}\n" >&2
        exit 1
    fi

    log "Otomatik olarak seçilen disk: ${disk}"
    printf "${GREEN}Otomatik olarak seçilen disk: ${disk}${RESET}\n"
    export DISK="$disk"
}

# Klavye ve font ayarları
setup_keyboard_and_font() {
    loadkeys trq
    setfont ter-v24b
    printf "${GREEN}Klavye düzeni ve font ayarlandı.${RESET}\n"
}

# Gerekli paketlerin varlığını kontrol et ve yoksa yükle
check_required_packages() {
    local required_packages=("git" "curl" "wget" "vim")
    local missing_packages=()

    for package in "${required_packages[@]}"; do
        if ! command -v "$package" &>/dev/null; then
            missing_packages+=("$package")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        printf "${YELLOW}Eksik paketler tespit edildi: ${missing_packages[*]}. Yükleniyor...${RESET}\n"
        pacman -Sy --noconfirm "${missing_packages[@]}"
    else
        printf "${GREEN}Gerekli tüm paketler zaten yüklü.${RESET}\n"
    fi
}
