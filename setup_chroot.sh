#!/bin/bash
set -e
source ./common.sh

set_timezone() {
    ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
    hwclock --systohc
}

set_hostname() {
    local hostname="muhittintopalak"
    echo "$hostname" > /etc/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${hostname}.localdomain ${hostname}
EOF
}

set_locale() {
    local locale="en_CA.UTF-8"
    sed -i "s/^#\(${locale}\)/\1/" /etc/locale.gen
    echo "LANG=${locale}" > /etc/locale.conf
    locale-gen
}

set_console_font_and_keymap() {
    echo "FONT=ter-v24b" > /etc/vconsole.conf
    echo "KEYMAP=trq" >> /etc/vconsole.conf
}

install_grub() {
    local disk="$DISK"
    local luks_uuid

    if [[ "$disk" =~ nvme ]]; then
        luks_uuid=$(blkid -s UUID -o value "${disk}p2")
    else
        luks_uuid=$(blkid -s UUID -o value "${disk}2")
    fi

    pacman -S --noconfirm grub efibootmgr
    sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet cryptdevice=UUID=${luks_uuid}:cryptdev\"/" /etc/default/grub
    sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
    grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=GRUB
    grub-mkconfig -o /efi/grub/grub.cfg
}

enable_networkmanager() {
    printf "${GREEN}NetworkManager etkinleştiriliyor...${RESET}\n"
    systemctl enable NetworkManager
}

# Chroot içinde çağırılacak fonksiyonlar
enable_networkmanager
set_timezone
set_hostname
set_locale
set_console_font_and_keymap
install_grub
