#!/bin/bash

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # Renk sıfırlama

# Mesaj yazdırma fonksiyonu
print_message() {
    echo -e "${YELLOW}$1${NC}"
}

enable_services() {
    local services=("$@")
    for service in "${services[@]}"; do
        if ! systemctl is-enabled "$service" > /dev/null 2>&1; then
            print_message "$service etkinleştiriliyor..."
            sudo systemctl enable --now "$service"
        else
            echo -e "${GREEN}$service zaten etkin.${NC}"
        fi
    done
}

install_packages() {
    local missing_packages=()

    # Eksik olan paketleri bul ve listeye ekle
    for package in "$@"; do
        if ! pacman -Qi "$package" > /dev/null 2>&1; then
            missing_packages+=("$package")
        fi
    done

    # Pacman ile eksik paketleri yükle
    if [ ${#missing_packages[@]} -ne 0 ]; then
        print_message "Eksik paketler yükleniyor: ${missing_packages[*]}"
        if ! sudo pacman -S --noconfirm "${missing_packages[@]}"; then
            print_message "Pacman ile yüklenemeyen paketler var. Yay ile deneniyor..."

            # Yay kurulu değilse, install_aur_helper çalıştırılır.
            if ! command -v yay > /dev/null 2>&1; then
                print_message "Yay AUR yardımcı programı kurulmamış. Kurulum yapılıyor..."
                install_aur_helper
            fi

            # Yay ile eksik paketleri yükle
            if ! yay -S --noconfirm "${missing_packages[@]}"; then
                echo -e "${RED}Bazı paketler hem pacman hem de yay ile yüklenemedi.${NC}"
            fi
        fi
    else
        echo -e "${GREEN}Tüm paketler zaten yüklü.${NC}"
    fi
}


# Tüm paketlerin tek listede toplanması
packages=(
    dbus intel-ucode fuse2 lshw powertop inxi acpi base-devel git zip unzip htop tree w3m dialog reflector bash-completion arandr iw
    wpa_supplicant tcpdump mtr net-tools conntrack-tools ethtool wget rsync socat openbsd-netcat axel sof-firmware ttf-impallari-cabin-font ttf-ms-fonts glow ttf-jetbrains-mono exa bc jq most bat neovim vi man screen asciinema expect arch-audit whois stress iotop ncdu nethogs openssh sshpass keychain bind-tools cronie at borgbackup borgmatic pwgen lsd rclone syncthing vdirsyncer khal khard words fzf neofetch cifs-utils shellcheck oath-toolkit python-pip dmidecode python-pre-commit zim mailutils python-pipx
    xorg-server xorg-apps xorg-xinit xdotool xclip xsel ttf-dejavu ttf-freefont ttf-liberation ttf-droid terminus-font noto-fonts noto-fonts-emoji ttf-ubuntu-font-family ttf-roboto bluez bluez-utils blueman nm-connection-editor networkmanager-openvpn python-poetry fail2ban lightdm lightdm-gtk-greeter oblogout ttyd dool nmap pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber alsa-utils dmenu rofi alacritty i3-wm i3lock i3blocks i3status imwheel scrot i3ipc-python network-manager-applet ranger ffmpegthumbnailer firefox lxappearance feh sxiv dunst
)

configure_snapper() {
    print_message "Snapper ve snap-pac kuruluyor..."
    install_packages snapper snap-pac

    # Önceki snapshot yapılandırmasını kaldırma
    print_message "Önceki snapshot yapılandırması kaldırılıyor..."
    sudo umount /.snapshots
    sudo rm -rf /.snapshots

    # Root için yeni Snapper yapılandırması oluşturma
    print_message "Yeni Snapper yapılandırması oluşturuluyor..."
    sudo snapper -c root create-config /

    # Snapper'ın oluşturduğu .snapshots subvolume'unu silme
    sudo btrfs subvolume delete .snapshots

    # Yeni mount point oluşturma ve yeniden mount etme
    sudo mkdir /.snapshots
    sudo mount -a

    # Yetkilendirme ve izinler
    sudo chmod 750 /.snapshots
    sudo chown :wheel /.snapshots

    # Snapper otomatik timeline snapshot'ları yapılandırma (dinamik kullanıcı)
    print_message "Snapper otomatik timeline snapshot'ları yapılandırılıyor..."
    sudo sed -i "s/^ALLOW_USERS=\"\"/ALLOW_USERS=\"$USER\"/" /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
    sudo sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root

    # Snapper zamanlayıcıları etkinleştirme
    sudo systemctl enable --now snapper-timeline.timer
    sudo systemctl enable --now snapper-cleanup.timer

    # Grub-btrfs kurulumu ve yapılandırılması
    print_message "Grub-btrfs kuruluyor ve yapılandırılıyor..."
    install_packages grub-btrfs
    sudo sed -i 's|^#GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/efi/grub"|' /etc/default/grub-btrfs/config
    sudo systemctl enable --now grub-btrfs.path

    # Grub-btrfs için overlayfs yapılandırması
    print_message "Grub-btrfs için overlayfs yapılandırılıyor..."
    sudo sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 grub-btrfs overlayfs)/' /etc/mkinitcpio.conf
    sudo mkinitcpio -P
}

# Tüm paketlerin kurulumu
install_packages "${packages[@]}"

enable_trim() {
    print_message "SSD için TRIM zamanlayıcısı etkinleştiriliyor..."
    sudo systemctl enable --now fstrim.timer
}

configure_font_rendering() {
    print_message "Font rendering ayarları yapılandırılıyor..."
    sudo ln -sf /etc/fonts/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/10-sub-pixel-rgb.conf
    sudo ln -sf /etc/fonts/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d/11-lcdfilter-default.conf
}

optimize_kernel_parameters() {
    print_message "Kernel parametreleri optimize ediliyor..."
    sudo tee /etc/sysctl.d/99-sysctl.conf > /dev/null <<EOL
vm.vfs_cache_pressure=500
vm.swappiness=100
vm.dirty_background_ratio=1
vm.dirty_ratio=50
EOL
    sudo sysctl --system
}

configure_zram() {
    print_message "Zram swap yapılandırması yapılıyor..."
    sudo bash -c "echo 0 > /sys/module/zswap/parameters/enabled"
    sudo swapoff --all
    sudo modprobe zram num_devices=1
    sudo bash -c "echo zstd > /sys/block/zram0/comp_algorithm"
    sudo bash -c "echo 8G > /sys/block/zram0/disksize"
    sudo mkswap --label zram0 /dev/zram0
    sudo swapon --priority 32767 /dev/zram0
}

create_zram_scripts() {
    print_message "Zram swap için başlatma ve durdurma scriptleri oluşturuluyor..."
    sudo tee /usr/local/bin/zram_start > /dev/null <<EOL
#!/bin/bash
modprobe zram num_devices=1
echo zstd > /sys/block/zram0/comp_algorithm
echo 8G > /sys/block/zram0/disksize
mkswap --label zram0 /dev/zram0
swapon --priority 32767 /dev/zram0
EOL

    sudo tee /usr/local/bin/zram_stop > /dev/null <<EOL
#!/bin/bash
swapoff /dev/zram0
echo 1 > /sys/block/zram0/reset
modprobe -r zram
EOL

    sudo chmod +x /usr/local/bin/zram_start /usr/local/bin/zram_stop
}

create_zram_service() {
    print_message "Zram swap için systemd servisi oluşturuluyor..."
    sudo tee /etc/systemd/system/zram-swap.service > /dev/null <<EOL
[Unit]
Description=Configure zram swap device
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zram_start
ExecStop=/usr/local/bin/zram_stop
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOL

    sudo systemctl enable --now zram-swap.service
}

setup_command_not_found() {
    print_message "Command-not-found özelliği kuruluyor..."
    install_packages pkgfile
    sudo pkgfile --update

    if ! grep -q 'command-not-found.bash' ~/.bashrc; then
        echo 'if [[ -f /usr/share/doc/pkgfile/command-not-found.bash ]]; then' >> ~/.bashrc
        echo '    . /usr/share/doc/pkgfile/command-not-found.bash' >> ~/.bashrc
        echo 'fi' >> ~/.bashrc
    fi
    exec bash
}

install_aur_helper() {
    print_message "Yay AUR yardımcı programı kuruluyor..."
    if ! command -v yay > /dev/null 2>&1; then
        git clone https://aur.archlinux.org/yay-git.git
        cd yay-git || { print_message "Dizin değiştirilemedi, script sonlandırılıyor."; exit 1; }
        makepkg -si --noconfirm
        cd ..
        rm -rf yay-git
    else
        echo -e "${GREEN}Yay zaten yüklü.${NC}"
    fi
}

# Diğer yapılandırmalar (Fonksiyonlar burada kalmaya devam edecek)
enable_trim
configure_font_rendering
configure_snapper
optimize_kernel_parameters
configure_zram
create_zram_scripts
create_zram_service
setup_command_not_found

# Hizmetlerin etkinleştirilmesi
enable_services bluetooth fail2ban

# LightDM'in en son etkinleştirilmesi
enable_services lightdm.service

print_message "Tüm işlemler başarıyla tamamlandı."
