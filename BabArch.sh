#!/bin/bash
set -euo pipefail

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
    local password="minel"
    local password_file="/root/sifre.txt"

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

    # Eğer dosya yoksa oluştur ve içine "minel" yaz
    if [[ ! -f "$password_file" ]]; then
        echo "$password" > "$password_file"
        log "$password_file dosyası oluşturuldu ve şifre yazıldı."
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

    # LUKS formatını gerçekleştir ve şifreyi dosyadan al
    if cryptsetup --type luks1 -v -y luksFormat "$luks_partition" -d "$password_file"; then
        log "Bölüm LUKS1 ile şifrelendi."
        printf "${GREEN}Bölüm LUKS1 ile şifrelendi.${RESET}\n"
    else
        log "Hata: LUKS formatlama başarısız."
        printf "${RED}Hata: LUKS formatlama başarısız.${RESET}\n" >&2
        return 1
    fi

    # Şifre dosyasını sil
    rm -f "$password_file"
    log "$password_file dosyası silindi."
}



# 1.11 Bölümleri formatla
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
        printf "${RED}Hata: LUKS bölümü açılamadı.${RESET}\n" >&2
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
    printf "${GREEN}Sisteme chroot yapılıyor...${RESET}\n"
    arch-chroot /mnt /bin/bash
}

# 2.1 Zaman dilimini ayarla
set_timezone() {
    printf "${GREEN}Zaman dilimi İstanbul olarak ayarlanıyor...${RESET}\n"
    ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
    hwclock --systohc
    reflector --verbose --protocol https --latest 5 --sort rate  --country Germany --save /etc/pacman.d/mirrorlist

}

# Kullanıcıya hostname belirlet
set_hostname() {
    local hostname
    printf "${YELLOW}Lütfen sistem için bir hostname girin (örnek: muhittintopalak): ${RESET}"
    read -r hostname

    if [[ -z "$hostname" ]]; then
        printf "${RED}Hata: Geçersiz hostname. Kurulum durduruluyor.${RESET}\n" >&2
        exit 1
    fi

    printf "${GREEN}Hostname olarak '${hostname}' seçildi.${RESET}\n"
    echo "$hostname" > /etc/hostname

    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${hostname}.localdomain ${hostname}
EOF
}

# 2.3 Locale ayarla
set_locale() {
    local locale="en_CA.UTF-8"
    printf "${GREEN}Locale ayarlanıyor: ${locale}${RESET}\n"
    sed -i "s/^#\(${locale}\)/\1/" /etc/locale.gen
    echo "LANG=${locale}" > /etc/locale.conf
    locale-gen
}

# 2.4 Konsol fontu ve klavye düzeni ayarla
set_console_font_and_keymap() {
    printf "${GREEN}Konsol fontu ve klavye düzeni ayarlanıyor...${RESET}\n"
    echo "FONT=ter-v24b" > /etc/vconsole.conf
    echo "KEYMAP=trq" >> /etc/vconsole.conf
}

# 2.5 Varsayılan editörü ayarla
set_default_editor() {
    printf "${GREEN}Sistem varsayılan editörü ayarlanıyor...${RESET}\n"
    echo "EDITOR=nvim" > /etc/environment
    echo "VISUAL=nvim" >> /etc/environment
}

# 2.6 Root parolası belirle
# Root şifresini ayarla
set_root_password() {
    local root_password
    local confirm_root_password
    local attempts=0

    while [[ $attempts -lt 3 ]]; do
        # Kullanıcıdan root şifresi al
        read -s -p "Root için yeni şifre girin: " root_password
        echo
        read -s -p "Root şifrenizi tekrar girin: " confirm_root_password
        echo

        if [[ "$root_password" == "$confirm_root_password" ]]; then
            echo -e "$root_password\n$root_password" | passwd root
            log "Root şifresi ayarlandı."
            printf "${GREEN}Root şifresi başarıyla ayarlandı.${RESET}\n"
            return
        else
            log "Hata: Şifreler eşleşmiyor. Tekrar deneyin."
            printf "${RED}Hata: Şifreler eşleşmiyor. Tekrar deneyin.${RESET}\n"
            ((attempts++))
        fi
    done

    log "Hata: 3 kez şifre eşleşmesi sağlanamadı. Script durduruluyor."
    printf "${RED}Hata: 3 kez şifre eşleşmesi sağlanamadı. Script durduruluyor.${RESET}\n"
    exit 1
}


# Kullanıcı oluştur
create_user() {
    local username
    local user_password
    local confirm_user_password
    local attempts=0

    read -p "Yeni kullanıcı adı girin: " username

    while [[ $attempts -lt 3 ]]; do
        # Kullanıcıdan şifreyi al
        read -s -p "Kullanıcı için yeni şifre girin: " user_password
        echo
        read -s -p "Kullanıcı şifrenizi tekrar girin: " confirm_user_password
        echo

        if [[ "$user_password" == "$confirm_user_password" ]]; then
            useradd -m -G  wheel -s /bin/bash "$username"
            echo -e "$user_password\n$user_password" | passwd "$username"
            sed -i "s/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/" /etc/sudoers
            log "Kullanıcı '$username' oluşturuldu ve şifresi ayarlandı."
            printf "${GREEN}Kullanıcı '$username' başarıyla oluşturuldu.${RESET}\n"
            return
        else
            log "Hata: Şifreler eşleşmiyor. Tekrar deneyin."
            printf "${RED}Hata: Şifreler eşleşmiyor. Tekrar deneyin.${RESET}\n"
            ((attempts++))
        fi
    done

    log "Hata: 3 kez şifre eşleşmesi sağlanamadı. Script durduruluyor."
    printf "${RED}Hata: 3 kez şifre eşleşmesi sağlanamadı. Script durduruluyor.${RESET}\n"
    exit 1
}


# 2.8 NetworkManager'ı etkinleştir
enable_networkmanager() {
    printf "${GREEN}NetworkManager etkinleştiriliyor...${RESET}\n"
    systemctl enable NetworkManager
}

# 2.9 SSH sunucusunu etkinleştir
enable_sshd() {
    printf "${GREEN}SSHD sunucusu etkinleştiriliyor...${RESET}\n"
    systemctl enable sshd.service
}

# 2.10 LUKS için keyfile oluştur ve yapılandır
configure_keyfile() {
    local disk="$DISK"
    local luks_partition

    if [[ "$disk" =~ nvme ]]; then
        luks_partition="${disk}p2"
    else
        luks_partition="${disk}2"
    fi

    printf "${GREEN}Keyfile oluşturuluyor ve LUKS yapılandırılıyor...${RESET}\n"
    dd bs=512 count=4 iflag=fullblock if=/dev/random of=/crypto_keyfile.bin
    chmod 600 /crypto_keyfile.bin
    cryptsetup luksAddKey "$luks_partition" /crypto_keyfile.bin
}

# 2.11 mkinitcpio'yu yapılandır
configure_mkinitcpio() {
    printf "${GREEN}mkinitcpio yapılandırılıyor...${RESET}\n"
    sed -i 's/^FILES=()/FILES=(\/crypto_keyfile.bin)/' /etc/mkinitcpio.conf
    sed -i 's/^MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect keymap consolefont modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    mkinitcpio -P
}

# 2.12 GRUB önyükleyicisini kur ve yapılandır
install_grub() {
    local disk="$DISK"
    local luks_uuid

    if [[ "$disk" =~ nvme ]]; then
        luks_uuid=$(blkid -s UUID -o value "${disk}p2")
    else
        luks_uuid=$(blkid -s UUID -o value "${disk}2")
    fi

    printf "${GREEN}GRUB kuruluyor ve yapılandırılıyor...${RESET}\n"
    pacman -S --noconfirm grub efibootmgr
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet cryptdevice=UUID=${luks_uuid}:cryptdev\"/" /etc/default/grub
    sed -i 's/^GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES="part_gpt part_msdos luks"/' /etc/default/grub
    sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
}

# 2.13 Önyükleyiciyi kur
install_boot_loader() {
    printf "${GREEN}Önyükleyici kuruluyor...${RESET}\n"
    grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=GRUB
    efibootmgr
    grub-mkconfig -o /efi/grub/grub.cfg
    grep 'cryptodisk\|luks' /efi/grub/grub.cfg
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
    set_timezone
    set_hostname
    set_locale
    set_console_font_and_keymap
    set_default_editor
    set_root_password
    create_user
    enable_networkmanager
    enable_sshd
    configure_keyfile
    configure_mkinitcpio
    install_grub
    install_boot_loader

    printf "${GREEN}Kurulum tamamlandı, sistem yeniden başlatılıyor...${RESET}\n"
    reboot_system
}

# İlerleme göstergesi ile başlatma
show_progress "İşlemler başlatılıyor" 5
main "$@"
