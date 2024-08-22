#!/bin/bash
set -e
source ./common.sh

mount_root_device() {
    printf "${GREEN}Kök bölümü /mnt dizinine bağlanıyor...${RESET}\n"
    mount /dev/mapper/cryptdev /mnt
}

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

mount_btrfs_subvolumes() {
    local sv_opts="rw,noatime,compress-force=zstd:1,space_cache=v2"
    
    printf "${GREEN}Alt birimler bağlanıyor...${RESET}\n"
    umount /mnt
    mount -o ${sv_opts},subvol=@ /dev/mapper/cryptdev /mnt

    mkdir -p /mnt/{home,.snapshots,var/cache,var/lib/libvirt,var/log,var/tmp}
    mount -o ${sv_opts},subvol=@home /dev/mapper/cryptdev /mnt/home
    mount -o ${sv_opts},subvol=@snapshots /dev/mapper/cryptdev /mnt/.snapshots
    mount -o ${sv_opts},subvol=@cache /dev/mapper/cryptdev /mnt/var/cache
    mount -o ${sv_opts},subvol=@libvirt /dev/mapper/cryptdev /mnt/var/lib/libvirt
    mount -o ${sv_opts},subvol=@log /dev/mapper/cryptdev /mnt/var/log
    mount -o ${sv_opts},subvol=@tmp /dev/mapper/cryptdev /mnt/var/tmp
}

mount_esp_partition() {
    local disk="$DISK"
    local esp_partition

    if [[ "$disk" =~ nvme ]]; then
        esp_partition="${disk}p1"
    else
        esp_partition="${disk}1"
    fi

    mkdir -p /mnt/efi
    mount "$esp_partition" /mnt/efi
}

install_base_system() {
    printf "${GREEN}Temel sistem paketleri kuruluyor...${RESET}\n"
    pacstrap /mnt base base-devel "${MICROCODE}" btrfs-progs linux linux-firmware bash-completion \
        cryptsetup htop man-db mlocate neovim networkmanager openssh pacman-contrib \
        pkgfile reflector sudo terminus-font tmux
}

generate_fstab() {
    printf "${GREEN}Fstab dosyası oluşturuluyor...${RESET}\n"
    genfstab -U -p /mnt >> /mnt/etc/fstab
}
