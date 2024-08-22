#!/bin/bash
set -euo pipefail
export LUKS_PASSWORD="minel"

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
# 1.6 Sistem saatini güncelle
update_system_clock() {
    log "Sistem saati güncelleniyor..."
    printf "${GREEN}Sistem saati güncelleniyor...${RESET}\n"
    timedatectl set-ntp true
    timedatectl status
}

# Disk değişkenini ayarla
set_disk_variable() {
    local disk
    lsblk -f
    printf "${YELLOW}Kurulum yapılacak diski otomatik seçiyorum...${RESET}\n"

    # Otomatik olarak ilk uygun diski seçiyoruz
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


# 1.12 Kök bölümünü bağla
mount_root_device() {
    printf "${GREEN}Kök bölümü /mnt dizinine bağlanıyor...${RESET}\n"
    if ! mount /dev/mapper/cryptdev /mnt; then
        printf "${RED}Hata: Kök bölümü bağlanamadı.${RESET}\n" >&2
        return 1
    fi
}

# 1.13 BTRFS alt birimlerini oluştur
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

# 1.14 Alt birimleri bağla
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

# 1.15 ESP bölümünü bağla
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

# 1.16 Paket yansımalarını güncelle
synchronize_package_databases() {
    printf "${GREEN}Paket veritabanları güncelleniyor...${RESET}\n"
    pacman -Syy
}

generate_mirrorlist() {
    printf "${GREEN}Yansılar güncelleniyor...${RESET}\n"
    reflector --verbose --protocol https --latest 5 --sort rate --country Germany --save /etc/pacman.d/mirrorlist
}

# Microcode kontrolü
check_microcode() {
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        export MICROCODE="intel-ucode"
        printf "${GREEN}Intel mikrocode seçildi.${RESET}\n"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        export MICROCODE="amd-ucode"
        printf "${GREEN}AMD mikrocode seçildi.${RESET}\n"
    else
        printf "${RED}Desteklenmeyen CPU üreticisi. Kurulum durduruluyor.${RESET}\n" >&2
        exit 1
    fi
}

install_base_system() {
    printf "${GREEN}Temel sistem paketleri kuruluyor...${RESET}\n"
    pacstrap /mnt base base-devel "${MICROCODE}" btrfs-progs linux linux-firmware bash-completion \
        cryptsetup htop man-db mlocate neovim networkmanager openssh pacman-contrib \
        pkgfile reflector sudo terminus-font tmux
}

# 1.18 Fstab oluştur
generate_fstab() {
    printf "${GREEN}Fstab dosyası oluşturuluyor...${RESET}\n"
    genfstab -U -p /mnt >> /mnt/etc/fstab
}

# 2. Sistemi yapılandır: Chroot
configure_system() {
    printf "${GREEN}Sisteme chroot yapılıyor ve yapılandırma başlatılıyor...${RESET}\n"
    cp /root/test/setup_chroot.sh /mnt/setup_chroot.sh
    chmod +x /mnt/setup_chroot.sh
    arch-chroot /mnt /bin/bash /setup_chroot.sh
    rm /mnt/setup_chroot.sh
}


# 2.14 Chroot'tan çık ve yeniden başlat
reboot_system() {
    printf "${YELLOW}Yeniden başlatılıyor...${RESET}\n"
    exit
    umount -R /mnt
    reboot
}

# UEFI kontrolü
check_uefi() {
    if [[ ! -d /sys/firmware/efi/efivars ]]; then
        printf "${RED}Bu sistem UEFI değil. Kurulum durduruluyor.${RESET}\n" >&2
        exit 1
    fi
    printf "${GREEN}UEFI modu tespit edildi.${RESET}\n"
}

# İnternet bağlantı kontrolü
check_internet() {
    if ! ping -c 1 archlinux.org &>/dev/null; then
        printf "${RED}İnternet bağlantısı yok. Kurulum durduruluyor.${RESET}\n" >&2
        exit 1
    fi
    printf "${GREEN}İnternet bağlantısı tespit edildi.${RESET}\n"
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

# main fonksiyonunda güncellemeler
main() {
    printf "${YELLOW}Kurulum başlıyor, arkanıza yaslanın ve kahvenizi yudumlayın...${RESET}\n"
    
    setup_keyboard_and_font
    check_required_packages
    check_uefi
    check_internet
    check_microcode
    update_system_clock
    set_disk_variable

    # Diğer kurulum adımları otomatik olarak gerçekleşecek
    wipe_disk
    partition_disk
    encrypt_partition
    format_partitions
    mount_root_device
    create_btrfs_subvolumes
    mount_btrfs_subvolumes
    mount_esp_partition
    synchronize_package_databases
    generate_mirrorlist
    install_base_system
    generate_fstab
    configure_system
  

    printf "${GREEN}Kurulum tamamlandı, sistem yeniden başlatılıyor...${RESET}\n"
    reboot_system
}

# İlerleme göstergesi ile başlatma
show_progress "İşlemler başlatılıyor" 5
main "$@"
