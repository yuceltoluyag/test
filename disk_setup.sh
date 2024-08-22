#!/bin/bash

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

# Diskteki eski bölümleri sil
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
    if ! wipefs -af "$disk"; then
        log "Hata: Disk sıfırlama başarısız."
        printf "${RED}Hata: Disk sıfırlama başarısız.${RESET}\n" >&2
        return 1
    fi
    if ! sgdisk --zap-all --clear "$disk"; then
        log "Hata: Disk bölümlerini silme başarısız."
        printf "${RED}Hata: Disk bölümlerini silme başarısız.${RESET}\n" >&2
        return 1
    fi
    if ! partprobe "$disk"; then
        log "Hata: Bölüm tablosu güncellenemedi."
        printf "${RED}Hata: Bölüm tablosu güncellenemedi.${RESET}\n" >&2
        return 1
    fi
}

# Diski bölümle
partition_disk() {
    local disk="$DISK"
    if [[ -z "$disk" ]]; then
        log "Hata: Disk değişkeni tanımlanmamış."
        printf "${RED}Hata: Disk değişkeni tanımlanmamış.${RESET}\n" >&2
        return 1
    fi

    printf "${YELLOW}Bu işlem diskteki mevcut verileri siler. Devam etmek istiyor musunuz? (e/h)${RESET}\n"
    read -r -n 1 confirmation
    printf "\n"

    if [[ "$confirmation" != "e" ]]; then
        log "İşlem iptal edildi."
        printf "${RED}İşlem iptal edildi.${RESET}\n"
        return 1
    fi

    log "Bölümleme işlemi başlatılıyor..."
    printf "${GREEN}Bölümleme işlemi başlatılıyor...${RESET}\n"
    if ! sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:esp "$disk"; then
        log "Hata: EFI bölümü oluşturulamadı."
        printf "${RED}Hata: EFI bölümü oluşturulamadı.${RESET}\n" >&2
        return 1
    fi
    if ! sgdisk -n 0:0:0 -t 0:8309 -c 0:luks "$disk"; then
        log "Hata: Şifreli bölüm oluşturulamadı."
        printf "${RED}Hata: Şifreli bölüm oluşturulamadı.${RESET}\n" >&2
        return 1
    fi
    if ! partprobe "$disk"; then
        log "Hata: Bölüm tablosu güncellenemedi."
        printf "${RED}Hata: Bölüm tablosu güncellenemedi.${RESET}\n" >&2
        return 1
    fi
    log "Bölümleme işlemi başarılı."
    printf "${GREEN}Bölümleme işlemi başarılı.${RESET}\n"
}

# Şifreleme işlemi
encrypt_partition() {
    local disk="$DISK"
    local luks_partition

    if [[ -z "$disk" ]]; then
        log "Hata: Disk değişkeni tanımlanmamış."
        printf "${RED}Hata: Disk değişkeni tanımlanmamış.${RESET}\n" >&2
        return 1
    fi

    if [[ "$disk" =~ nvme ]]; then
        luks_partition="${disk}p2"
    else
        luks_partition="${disk}2"
    fi

    # Kullanıcıdan onay al
    printf "${YELLOW}Bu işlem tüm verileri kalıcı olarak silecek. Devam etmek istiyor musunuz? (yes/YES): ${RESET}"
    read -r confirmation

    # Onay kontrolü (yes veya YES kabul edilir)
    if [[ "${confirmation,,}" != "yes" ]]; then
        log "İşlem iptal edildi."
        printf "${RED}İşlem iptal edildi.${RESET}\n"
        return 1
    fi

    # LUKS formatını gerçekleştir (şifre çevre değişkeninden alınacak)
    if echo "$LUKS_PASSWORD" | sudo cryptsetup --type luks1 -v luksFormat "$luks_partition"; then
        log "Bölüm LUKS1 ile şifrelendi."
        printf "${GREEN}Bölüm LUKS1 ile şifrelendi.${RESET}\n"
    else
        log "Hata: LUKS formatlama başarısız."
        printf "${RED}Hata: LUKS formatlama başarısız.${RESET}\n" >&2
        return 1
    fi
}

# Bölümleri formatla ve montajla
format_partitions() {
    local disk="$DISK"
    local luks_partition esp_partition

    if [[ -z "$disk" ]]; then
        printf "${RED}Hata: Disk değişkeni tanımlanmamış.${RESET}\n" >&2
        return 1
    fi

    if [[ "$disk" =~ nvme ]]; then
        esp_partition="${disk}p1"
        luks_partition="${disk}p2"
    else
        esp_partition="${disk}1"
        luks_partition="${disk}2"
    fi

    printf "${GREEN}Şifreli bölüm açılıyor...${RESET}\n"
    if ! cryptsetup open "$luks_partition" cryptdev; then
        printf "${RED}Hata: LUKS bölümü açılamadı. Şifreyi doğru girdiğinizden emin olun.${RESET}\n" >&2
        return 1
    fi

    printf "${GREEN}EFI bölümü VFAT olarak formatlanıyor...${RESET}\n"
    mkfs.vfat -F32 -n ESP "$esp_partition"

    printf "${GREEN}Kök bölümü BTRFS olarak formatlanıyor...${RESET}\n"
    mkfs.btrfs -L archlinux /dev/mapper/cryptdev
}

# Kök bölümü montajla
mount_root_device() {
    printf "${GREEN}Kök bölümü /mnt dizinine bağlanıyor...${RESET}\n"
    if ! mount /dev/mapper/cryptdev /mnt; then
        printf "${RED}Hata: Kök bölümü bağlanamadı.${RESET}\n" >&2
        return 1
    fi
}

# BTRFS alt birimleri oluştur
create_btrfs_subvolumes() {
    printf "${GREEN}BTRFS alt birimleri oluşturuluyor...${RESET}\n"
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@cache
    btrfs subvolume create /mnt/@libvirt
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@tmp
}

# BTRFS alt birimlerini montajla
mount_btrfs_subvolumes() {
    local sv_opts="rw,noatime,compress-force=zstd:1,space_cache=v2"
    
    printf "${GREEN}Kök bölümü yeniden bağlanıyor...${RESET}\n"
    umount /mnt
    mount -o ${sv_opts},subvol=@ /dev/mapper/cryptdev /mnt

    mkdir -p /mnt/{home,.snapshots,var/cache,var/lib/libvirt,var/log,var/tmp}

    printf "${GREEN}Alt birimler bağlanıyor...${RESET}\n"
    mount -o ${sv_opts},subvol=@home /dev/mapper/cryptdev /mnt/home
    mount -o ${sv_opts},subvol=@snapshots /dev/mapper/cryptdev /mnt/.snapshots
    mount -o ${sv_opts},subvol=@cache /dev/mapper/cryptdev /mnt/var/cache
    mount -o ${sv_opts},subvol=@libvirt /dev/mapper/cryptdev /mnt/var/lib/libvirt
    mount -o ${sv_opts},subvol=@log /dev/mapper/cryptdev /mnt/var/log
    mount -o ${sv_opts},subvol=@tmp /dev/mapper/cryptdev /mnt/var/tmp
}

# ESP bölümünü montajla
mount_esp_partition() {
    local disk="$DISK"
    local esp_partition

    if [[ "$disk" =~ nvme ]]; then
        esp_partition="${disk}p1"
    else
        esp_partition="${disk}1"
    fi

    printf "${GREEN}ESP bölümü /mnt/efi dizinine bağlanıyor...${RESET}\n"
    mkdir -p /mnt/efi
    mount "$esp_partition" /mnt/efi
}
