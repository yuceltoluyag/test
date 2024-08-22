#!/bin/bash
set -e
source ./common.sh

wipe_disk() {
    local disk="$DISK"
    if [[ -z "$disk" ]]; then
        log "Hata: Disk değişkeni tanımlanmamış."
        printf "${RED}Hata: Disk değişkeni tanımlanmamış.${RESET}\n" >&2
        return 1
    fi

    printf "${YELLOW}${disk} diski sıfırlanacak. Devam etmek istiyor musunuz? (e/h)${RESET}\n"
    read -r -n 1 confirmation
    printf "\n"

    if [[ "$confirmation" != "e" ]]; then
        log "İşlem iptal edildi."
        printf "${RED}İşlem iptal edildi.${RESET}\n"
        return 1
    fi

    log "${disk} diski sıfırlanıyor..."
    printf "${GREEN}${disk} diski sıfırlanıyor...${RESET}\n"
    wipefs -af "$disk"
    sgdisk --zap-all --clear "$disk"
    partprobe "$disk"
}

partition_disk() {
    local disk="$DISK"
    printf "${GREEN}Bölümleme işlemi başlatılıyor...${RESET}\n"
    sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:esp "$disk"
    sgdisk -n 0:0:0 -t 0:8309 -c 0:luks "$disk"
    partprobe "$disk"
}

encrypt_partition() {
    local disk="$DISK"
    local luks_partition

    if [[ "$disk" =~ nvme ]]; then
        luks_partition="${disk}p2"
    else
        luks_partition="${disk}2"
    fi

    printf "${YELLOW}Bu işlem tüm verileri kalıcı olarak silecek. Devam etmek istiyor musunuz? (yes/YES): ${RESET}"
    read -r confirmation

    if [[ "${confirmation,,}" != "yes" ]]; then
        log "İşlem iptal edildi."
        printf "${RED}İşlem iptal edildi.${RESET}\n"
        return 1
    fi

    echo "$LUKS_PASSWORD" | sudo cryptsetup --type luks1 -v luksFormat "$luks_partition"
    log "Bölüm LUKS1 ile şifrelendi."
}

format_partitions() {
    local disk="$DISK"
    local luks_partition esp_partition

    if [[ "$disk" =~ nvme ]]; then
        esp_partition="${disk}p1"
        luks_partition="${disk}p2"
    else
        esp_partition="${disk}1"
        luks_partition="${disk}2"
    fi

    cryptsetup open "$luks_partition" cryptdev
    mkfs.vfat -F32 -n ESP "$esp_partition"
    mkfs.btrfs -L archlinux /dev/mapper/cryptdev
}
