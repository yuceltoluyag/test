#!/bin/bash

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # Renk sıfırlama
CURRENT_USER=${SUDO_USER:-$USER}
# Kullanıcıya hoş geldin mesajı
echo "Hoşgeldin, $CURRENT_USER!"

# Mesaj yazdırma fonksiyonu
print_message() {
    local color
    case "$2" in
        success) color="${GREEN}" ;;
        error) color="${RED}" ;;
        warning) color="${YELLOW}" ;;
        *) color="${NC}" ;;  # Varsayılan renk
    esac
    echo -e "${color}$1${NC}"
}

# AUR yardımcı programı kurulumu
install_aur_helper() {
    print_message "Yay AUR yardımcı programı kuruluyor..."
    if ! command -v yay > /dev/null 2>&1; then
        git clone https://aur.archlinux.org/yay-git.git
        cd yay-git || { print_message "Dizin değiştirilemedi, script sonlandırılıyor." "error"; exit 1; }
        makepkg -si --noconfirm
        cd ..
        sudo rm -rf yay-git
    else
        print_message "Yay zaten yüklü." "success"
    fi
}

install_aur_packages() {
    print_message "AUR paketleri yükleniyor..." "warning"
    for package in "$@"; do
        if ! yay -Qi "$package" > /dev/null 2>&1; then
            yay -Rdd --noconfirm "$package" 2>/dev/null || true
            yay -S --noconfirm --answerclean=All --answerdiff=All --answeredit=All --answerupgrade=All --removemake --cleanafter --batchinstall --overwrite='*' "$package" || print_message "$package yüklenemedi." "error"
        else
            print_message "$package zaten yüklü." "success"
        fi
    done
}

# Paket yükleme fonksiyonu
install_packages() {
    local missing_packages=()
    local aur_packages=()

    for package in "$@"; do
        if ! pacman -Qi "$package" > /dev/null 2>&1; then
            if pacman -Ss "^$package\$" > /dev/null 2>&1; then
                missing_packages+=("$package")
            else
                aur_packages+=("$package")
            fi
        fi
    done

    if [ ${#missing_packages[@]} -ne 0 ]; then
        print_message "Eksik paketler yükleniyor: ${missing_packages[*]}" "warning"
        # Çakışan paketleri otomatik olarak kaldırmak için --needed ve --overwrite kullanıyoruz
        for package in "${missing_packages[@]}"; do
            if pacman -Qi "$package" > /dev/null 2>&1; then
                sudo pacman -Rdd --noconfirm "$package" 2>/dev/null || true
            fi
        done
        sudo pacman -S --noconfirm --needed --overwrite='*' "${missing_packages[@]}" || {
            print_message "Çakışan paketler tespit edildi ve çözülmeye çalışıldı, işlem başarısız oldu." "error"
            exit 1
        }
    fi

    if [ ${#aur_packages[@]} -ne 0 ]; then
        print_message "Pacman ile bulunamayan AUR paketleri yükleniyor: ${aur_packages[*]}" "warning"
        install_aur_packages "${aur_packages[@]}"
    fi
}


# Servis etkinleştirme fonksiyonu (mevcut olup olmadığını kontrol eder)
enable_service() {
    local service=$1
    if systemctl list-unit-files | grep -q "$service"; then
        if ! systemctl is-enabled "$service" > /dev/null 2>&1; then
            print_message "$service etkinleştiriliyor..." "warning"
            sudo systemctl enable --now "$service"
        else
            print_message "$service zaten etkin." "success"
        fi
    else
        print_message "$service mevcut değil, atlanıyor." "warning"
    fi
}

# Birden fazla servisi etkinleştirme fonksiyonu
enable_services() {
    for service in "$@"; do
        enable_service "$service"
    done
}

# Paketlerin listesi
packages=(
    dbus intel-ucode fuse2 lshw powertop inxi acpi base-devel git lazygit rustup clang ipython zip unzip debootstrap usbutils htop btop iotop nano lsof wezterm  libnotify  brightnessctl gammastep nftables playerctl  usbguard  tree man-pages gdb mc zathura strace w3m dialog reflector bash-completion arandr iw apparmor firejail xdg-dbus-proxy polkit restic audit fwupd gparted gptfdisk dosfstools efibootmgr efitools edk2-shell iwd iptables-nft zathura-pdf-poppler mpv imagemagick zsh dash ripgrep bat most p7zip plymouth plymouth-theme-colorful-loop-git docker docker-compose qemu-full virt-manager keepassxc
    wpa_supplicant tcpdump mtr net-tools conntrack-tools ethtool wget dnsmasq glider rsync socat openbsd-netcat axel sof-firmware ttf-impallari-cabin-font ttf-ms-fonts glow ttf-jetbrains-mono exa bc jq most bat neovim vi man screen asciinema expect arch-audit whois stress iotop ncdu nethogs openssh dbus-broker  sshpass keychain bind-tools cronie at borgbackup borgmatic pwgen lsd rclone syncthing vdirsyncer khal khard words fzf neofetch cifs-utils shellcheck oath-toolkit python-pip dmidecode python-pre-commit man-db zim mailutils python-pipx inotify-tools
    xorg-server xorg-apps xorg-xinit xterm xdotool xclip xsel ttf-dejavu ttf-freefont ttf-liberation ttf-droid terminus-font noto-fonts noto-fonts-emoji ttf-ubuntu-font-family ttf-roboto bluez bluez-utils blueman nm-connection-editor networkmanager-openvpn python-poetry fail2ban lightdm lightdm-gtk-greeter accountsservice-git  ttyd dool nmap pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack wireplumber alsa-utils dmenu rofi alacritty i3-wm i3lock i3blocks i3status imwheel scrot i3ipc-python-git network-manager-applet ranger ffmpegthumbnailer firefox lxappearance feh sxiv dunst btrfs-assistant  btrfs-progs linux-lts linux-lts-headers
)

configure_snapper() {
    print_message "Snapper ve snap-pac kuruluyor..."
    install_packages snapper snap-pac plymouth grub-btrfs inotify-tools

    # Snapper config dosyasının var olup olmadığını kontrol ediyoruz
    if sudo snapper -c root list-configs | grep -q 'root'; then
        print_message "Snapper yapılandırması zaten mevcut, yeniden yapılandırma yapılmayacak." "warning"
    else
        print_message "Önceki snapshot yapılandırması kaldırılıyor..." "warning"
        if mountpoint -q /.snapshots; then
            sudo umount /.snapshots
        fi
        sudo rm -rf /.snapshots

        print_message "Yeni Snapper yapılandırması oluşturuluyor..." "warning"
        sudo snapper -c root create-config /

        if [ ! -d "/.snapshots" ]; then
            sudo mkdir /.snapshots
        else
            print_message ".snapshots dizini zaten mevcut, yeniden oluşturulmayacak." "warning"
        fi

        sudo mount -a

        sudo chmod 750 /.snapshots
        sudo chown :wheel /.snapshots
        CURRENT_USER=${SUDO_USER:-$USER}

        print_message "Snapper otomatik timeline snapshot'ları yapılandırılıyor..." "warning"
        sudo sed -i "s/^ALLOW_USERS=\"\"/ALLOW_USERS=\"$CURRENT_USER\"/" /etc/snapper/configs/root
        sudo sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' /etc/snapper/configs/root
        sudo sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' /etc/snapper/configs/root
        sudo sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root
        sudo sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/' /etc/snapper/configs/root
        sudo sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/' /etc/snapper/configs/root
        sudo sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/' /etc/snapper/configs/root

        enable_services snapper-timeline.timer
        enable_services snapper-cleanup.timer
    fi
    enable_service grub-btrfsd.service
    # .snapshots dizinini PRUNENAMES'e ekleyin
    if ! grep -q ".snapshots" /etc/updatedb.conf; then
        sudo sed -i 's/^PRUNENAMES.*/& .snapshots/' /etc/updatedb.conf
        print_message "updatedb.conf dosyasına .snapshots eklendi." "success"
    else
        print_message "updatedb.conf dosyasında .snapshots zaten mevcut." "success"
    fi
    # GRUB_BTRFS_GRUB_DIRNAME ve GRUB_BTRFS_BOOT_DIRNAME ayarlarını güncelleme
    sudo sed -i 's|^#GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/efi/grub"|' /etc/default/grub-btrfs/config
    sudo sed -i 's|^#GRUB_BTRFS_BOOT_DIRNAME=.*|GRUB_BTRFS_BOOT_DIRNAME="/efi"|' /etc/default/grub-btrfs/config
}


# SSD için TRIM zamanlayıcısı etkinleştirme fonksiyonu
enable_trim() {
    print_message "SSD için TRIM zamanlayıcısı etkinleştiriliyor..." "warning"
    enable_service fstrim.timer
}

# Font rendering yapılandırma fonksiyonu
configure_font_rendering() {
    print_message "Font rendering ayarları yapılandırılıyor..." "warning"
    sudo ln -sf /etc/fonts/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/10-sub-pixel-rgb.conf
    sudo ln -sf /etc/fonts/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d/11-lcdfilter-default.conf
}

# Kernel parametrelerini optimize etme fonksiyonu
optimize_kernel_parameters() {
    print_message "Kernel parametreleri optimize ediliyor..." "warning"
    sudo tee /etc/sysctl.d/99-sysctl.conf > /dev/null <<EOL
vm.vfs_cache_pressure=500
vm.swappiness=100
vm.dirty_background_ratio=1
vm.dirty_ratio=50
EOL
    sudo sysctl --system
}

# Zram swap yapılandırma fonksiyonu
configure_zram() {
    print_message "Zram swap yapılandırması yapılıyor..." "warning"
    
    if ! grep -q "zram0" /proc/swaps; then
        sudo bash -c "echo 0 > /sys/module/zswap/parameters/enabled"
        sudo swapoff --all
        sudo modprobe zram num_devices=1

        # Zram cihazının meşgul olup olmadığını kontrol edin ve gerekirse sıfırlayın
        if [[ $(cat /sys/block/zram0/disksize) -gt 0 ]]; then
            echo 1 | sudo tee /sys/block/zram0/reset
        fi

        sudo bash -c "echo zstd > /sys/block/zram0/comp_algorithm"
        sudo bash -c "echo 12G > /sys/block/zram0/disksize"
        sudo mkswap --label zram0 /dev/zram0
        sudo swapon --priority 32767 /dev/zram0

        sudo tee /usr/local/bin/zram_start > /dev/null <<EOL
#!/bin/bash
modprobe zram num_devices=1
if [[ \$(cat /sys/block/zram0/disksize) -gt 0 ]]; then
    echo 1 | sudo tee /sys/block/zram0/reset
fi
echo zstd > /sys/block/zram0/comp_algorithm
echo 12G > /sys/block/zram0/disksize
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

        enable_service zram-swap.service
    else
        print_message "Zram zaten etkin, yapılandırma atlanıyor." "success"
    fi
}


# command-not-found özelliğini kurma fonksiyonu
setup_command_not_found() {
    print_message "Command-not-found özelliği kuruluyor..." "warning"
    install_packages pkgfile
    sudo pkgfile --update

    if ! grep -q 'command-not-found.bash' ~/.bashrc; then
        {
            echo 'if [[ -f /usr/share/doc/pkgfile/command-not-found.bash ]]; then'
            echo '    . /usr/share/doc/pkgfile/command-not-found.bash'
            echo 'fi'
        } >> ~/.bashrc
    fi
}

backup_boot() {
    print_message "Pacman işlemlerinde /efi yedeklemesi yapılandırılıyor." "warning"

    # Pacman hooks dizinini oluştur
    sudo mkdir -p /etc/pacman.d/hooks || { print_message "Dizin oluşturulamadı, script sonlandırılıyor." "error"; exit 1; }

    # EFI yedekleme hook'unu oluştur
    sudo tee /etc/pacman.d/hooks/50-efibackup.hook > /dev/null <<EOF || { print_message "EFI backup hook oluşturulamadı, script sonlandırılıyor." "error"; exit 1; }
[Trigger]
Operation = Upgrade
Operation = Install
Operation = Remove
Type = Path
Target = usr/lib/modules/*/vmlinuz

[Action]
Depends = rsync
Description = Backing up /efi...
When = PostTransaction
Exec = /usr/bin/rsync -a --delete /efi /.efibackup
EOF
}

configure_pacman_conf() {
    print_message "Pacman yapılandırma dosyası güncelleniyor..." "warning"

    # Pacman yapılandırma dosyasını yedekle
    sudo cp /etc/pacman.conf /etc/pacman.conf.bak

    # Yeni pacman.conf içeriğini oluştur
    sudo tee /etc/pacman.conf > /dev/null <<EOF
#{{{ General options
    [options]
    HoldPkg      = pacman glibc
    CleanMethod  = KeepInstalled
    Architecture = auto
#}}}

#{{{ Misc options
    UseSyslog
    Color
    ILoveCandy
    CheckSpace
    VerbosePkgLists
#}}}

#{{{ Trust
    SigLevel           = Required DatabaseOptional
    LocalFileSigLevel  = Optional
    RemoteFileSigLevel = Required
#}}}

#{{{ Repositories
    [core]
    Include = /etc/pacman.d/mirrorlist

    [extra]
    Include = /etc/pacman.d/mirrorlist

    [community]
    Include = /etc/pacman.d/mirrorlist

    [multilib]
    Include = /etc/pacman.d/mirrorlist
#}}}

# vim:fdm=marker
EOF

    print_message "Pacman yapılandırma dosyası güncellendi." "success"

    # Paketleri senkronize etme
    print_message "Paketler senkronize ediliyor..." "warning"
    sudo pacman -Syyu --noconfirm
    if command -v yay > /dev/null 2>&1; then
        yay -Syyu --noconfirm
    fi
    print_message "Paket senkronizasyonu tamamlandı." "success"
}




configure_system_post_install(){

    # Patch placeholders from config files
    sudo sed -i "s/^user = .*/user = \"$CURRENT_USER\"/" /etc/libvirt/qemu.conf

    
    # Set the very fast dash in place of sh
    sudo ln -sfT dash /usr/bin/sh

    grub_file="/etc/default/grub"
    cmdline="lsm=landlock,lockdown,yama,integrity,apparmor,bpf lockdown=integrity rootflags=subvol=@ mem_sleep_default=deep audit=1 audit_backlog_limit=32768 splash rd.udev.log_level=3"
    current_cmdline=$(grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$grub_file" | cut -d '"' -f 2)
    for param in $cmdline; do
        if [[ $current_cmdline != *"$param"* ]]; then
            current_cmdline="$param $current_cmdline"
        fi
    done
    sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$current_cmdline\"|" "$grub_file"
    sudo grub-mkconfig -o /efi/grub/grub.cfg
    sudo mkinitcpio -P
}
# Sistem Servisleri ve Diğer Yapılandırmaların Kurulumu
configure_system_services() {
    # For a smoother transition between Plymouth and Sway
    sudo sed -i 's|^HUSHLOGIN_FILE.*|HUSHLOGIN_FILE /etc/hushlogins|' /etc/login.defs
    sudo touch /etc/hushlogins
    echo "Kontrol ediliyor: /etc/firejail/firejail.users dosyası"
    if [ ! -f "/etc/firejail/firejail.users" ]; then
        echo "$CURRENT_USER" | sudo tee /etc/firejail/firejail.users > /dev/null
        echo "Dosya oluşturuldu ve kullanıcı eklendi: $CURRENT_USER"
    else
        if ! grep -Fxq "$CURRENT_USER" /etc/firejail/firejail.users; then
            echo "$CURRENT_USER" | sudo tee -a /etc/firejail/firejail.users > /dev/null
            echo "Kullanıcı eklendi: $CURRENT_USER"
        else
            echo "Kullanıcı zaten mevcut: $CURRENT_USER"
        fi
    fi

    # İnternet erişimine izin verecek bir grup oluşturun
    print_message "İnternet erişimi için 'allow-internet' grubu oluşturuluyor..." "warning"
    sudo groupadd -rf allow-internet
    print_message "'allow-internet' grubu oluşturuldu veya zaten mevcut." "success"

    # Kullanıcıyı gerekli gruplara ekleyin
    for group in wheel audit libvirt firejail allow-internet; do
        # Grup mevcut değilse oluştur
        if ! getent group "$group" > /dev/null 2>&1; then
            print_message "Grup '$group' mevcut değil, oluşturuluyor..." "warning"
            sudo groupadd "$group"
            if [ $? -eq 0 ]; then
                print_message "Grup '$group' başarıyla oluşturuldu." "success"
            else
                print_message "Grup '$group' oluşturulamadı." "error"
                continue  # Eğer grup oluşturulamazsa bu grubu atla
            fi
        fi
        
        # Kullanıcıyı gruba ekle
        if sudo gpasswd -a "$CURRENT_USER" "$group"; then
            print_message "Kullanıcı '$CURRENT_USER', '$group' grubuna eklendi." "success"
        else
            print_message "Kullanıcı '$CURRENT_USER', '$group' grubuna eklenemedi." "error"
        fi
    done


    if ! grep -q "plymouth" /etc/mkinitcpio.conf; then
        sudo sed -i 's/^HOOKS=(\(.*\))/HOOKS=(\1 plymouth)/' /etc/mkinitcpio.conf
        print_message "Plymouth hook'u mkinitcpio'ya eklendi." "success"
    else
        print_message "Plymouth hook'u zaten mevcut." "success"
    fi
    # Check if grub-btrfs-overlayfs is already in the HOOKS
    if ! grep -q "grub-btrfs-overlayfs" /etc/mkinitcpio.conf; then
        sudo sed -i 's/HOOKS=(\(.*\))/HOOKS=(\1 grub-btrfs-overlayfs)/' /etc/mkinitcpio.conf
        print_message "grub-btrfs-overlayfs hook'u mkinitcpio'ya eklendi.." "success"
    else
        print_message "grub-btrfs-overlayfs hook'u zaten mevcut.." "success"
    fi

    # Setup firejail
    sudo /usr/bin/firecfg
    # Configure systemd services
    enable_services systemd-networkd systemd-resolved systemd-timesyncd getty@tty1 \
                    dbus-broker iwd auditd nftables docker libvirtd check-secure-boot \
                    apparmor auditd-notify local-forwarding-proxy

    # Configure systemd timers
    enable_services snapper-timeline.timer snapper-cleanup.timer auditor.timer \
                    btrfs-scrub@-.timer btrfs-balance.timer pacman-sync.timer \
                    pacman-notify.timer should-reboot-check.timer

    # Configure systemd user services
    sudo systemctl --global enable dbus-broker
    sudo systemctl --global enable journalctl-notify
    sudo systemctl --global enable pipewire
    sudo systemctl --global enable wireplumber
    sudo systemctl --global enable gammastep
}



# Scriptin sonunda gereksiz `}` karakterini kaldırın ve paket yükleme işlemlerinden sonra servisleri etkinleştirin:
install_aur_helper
install_packages "${packages[@]}"

# Tüm paketlerin yüklendiğinden emin olduktan sonra servisleri etkinleştirin
enable_trim
configure_font_rendering
configure_pacman_conf
configure_snapper
optimize_kernel_parameters
configure_zram
setup_command_not_found
backup_boot
echo "Backup boot Hooku oluşturuldu.."
configure_system_post_install
configure_system_services
# Bu noktada servisler etkinleştirilebilir
enable_services bluetooth fail2ban
if ! grep -Fxq "exec i3" "$HOME/.xinitrc"; then
    echo "exec i3" >> "$HOME/.xinitrc"
fi
enable_service lightdm
print_message "Tüm işlemler başarıyla tamamlandı." "success"

