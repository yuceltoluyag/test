#!/bin/bash
set -e

GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
RESET='\e[0m'


log() {
    local message="$1"
    echo "$(date +'%Y-%m-%d %H:%M:%S') - ${message}" >> /var/log/disk_setup.log
}


# 2.1 Zaman dilimini ayarla
set_timezone() {
    printf "${GREEN}Zaman dilimi İstanbul olarak ayarlanıyor...${RESET}\n"
    ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
    hwclock --systohc

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
