#!/bin/bash

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # Renk sıfırlama

echo -e "${YELLOW}Post-installation işlemleri başlıyor...${NC}"

# Fonksiyonlar
install_packages() {
    local packages=("$@")
    for package in "${packages[@]}"; do
        if ! pacman -Qi "$package" > /dev/null 2>&1; then
            echo -e "${YELLOW}$package kuruluyor...${NC}"
            sudo pacman -S --noconfirm "$package"
        else
            echo -e "${GREEN}$package zaten yüklü.${NC}"
        fi
    done
}

enable_services() {
    local services=("$@")
    for service in "${services[@]}"; do
        if ! systemctl is-enabled "$service" > /dev/null 2>&1; then
            echo -e "${YELLOW}$service etkinleştiriliyor...${NC}"
            sudo systemctl enable --now "$service"
        else
            echo -e "${GREEN}$service zaten etkin.${NC}"
        fi
    done
}

# X.Org ve yardımcı programları kurma
echo -e "${YELLOW}X.Org ve yardımcı programlar kuruluyor...${NC}"
xorg_packages=(
    xorg-server xorg-apps xorg-xinit xdotool xclip xsel
)
install_packages "${xorg_packages[@]}"

# LightDM ve ilgili paketlerin kurulumu
echo -e "${YELLOW}LightDM ve ilgili paketler kuruluyor...${NC}"
lightdm_packages=(
    lightdm lightdm-gtk-greeter oblogout
)
install_packages "${lightdm_packages[@]}"
enable_services lightdm.service

# Ek sistem yardımcı programlarının kurulumu
echo -e "${YELLOW}Sistem yardımcı programları kuruluyor...${NC}"
system_utilities=(
    dbus intel-ucode fuse2 lshw powertop inxi acpi base-devel git zip unzip htop tree w3m dialog reflector bash-completion arandr iw
    wpa_supplicant tcpdump mtr net-tools conntrack-tools ethtool wget rsync socat openbsd-netcat axel sof-firmware
)
install_packages "${system_utilities[@]}"

# i3 pencere yöneticisi ve yardımcı programlarının kurulumu
echo -e "${YELLOW}i3 pencere yöneticisi ve ilgili fontlar kuruluyor...${NC}"
i3_packages=(
    ttf-dejavu ttf-freefont ttf-liberation ttf-droid terminus-font noto-fonts noto-fonts-emoji ttf-ubuntu-font-family ttf-roboto
)
install_packages "${i3_packages[@]}"

# Bluetooth desteğinin kurulumu ve etkinleştirilmesi
echo -e "${YELLOW}Bluetooth desteği kuruluyor...${NC}"
bluetooth_packages=(
    bluez bluez-utils blueman
)
install_packages "${bluetooth_packages[@]}"
enable_services bluetooth

# Ağ yönetimi ve Python geliştirme araçlarının kurulumu
echo -e "${YELLOW}Ağ yönetimi ve Python araçları kuruluyor...${NC}"
network_and_python=(
    nm-connection-editor networkmanager-openvpn python-pip python-poetry
)
install_packages "${network_and_python[@]}"

# Font rendering yapılandırması
echo -e "${YELLOW}Font rendering ayarları yapılandırılıyor...${NC}"
sudo ln -sf /etc/fonts/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/10-sub-pixel-rgb.conf
sudo ln -sf /etc/fonts/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d/11-lcdfilter-default.conf

# Fail2Ban kurulumu ve yapılandırılması
echo -e "${YELLOW}Fail2Ban kuruluyor ve yapılandırılıyor...${NC}"
install_packages fail2ban
sudo tee /etc/fail2ban/jail.local > /dev/null <<EOL
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/sshd_auth.log
maxretry = 2
findtime = 300000
bantime = -1
EOL
enable_services fail2ban

# Snapper ve snap-pac kurulumu
echo -e "${YELLOW}Snapper ve snap-pac kuruluyor...${NC}"
install_packages snapper snap-pac

# Snapper yapılandırması
echo -e "${YELLOW}Snapper yapılandırılıyor...${NC}"
sudo umount /.snapshots
sudo rm -rf /.snapshots
sudo snapper -c root create-config /
sudo mkdir /.snapshots
sudo mount -a
sudo chmod 750 /.snapshots
sudo chown :wheel /.snapshots
sudo systemctl enable --now snapper-timeline.timer snapper-cleanup.timer

# Kernel parametrelerini optimize etme
echo -e "${YELLOW}Kernel parametreleri optimize ediliyor...${NC}"
sudo tee /etc/sysctl.d/99-sysctl.conf > /dev/null <<EOL
vm.vfs_cache_pressure=500
vm.swappiness=100
vm.dirty_background_ratio=1
vm.dirty_ratio=50
EOL
sudo sysctl --system

# Zram swap yapılandırması
echo -e "${YELLOW}Zram swap yapılandırması yapılıyor...${NC}"
sudo bash -c "echo 0 > /sys/module/zswap/parameters/enabled"
sudo swapoff --all
sudo modprobe zram num_devices=1
sudo bash -c "echo zstd > /sys/block/zram0/comp_algorithm"
sudo bash -c "echo 8G > /sys/block/zram0/disksize"
sudo mkswap --label zram0 /dev/zram0
sudo swapon --priority 32767 /dev/zram0

# Zram swap için başlatma ve durdurma scriptleri oluşturma
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

# Zram swap için systemd servisi oluşturma
echo -e "${YELLOW}Zram swap için systemd servisi oluşturuluyor...${NC}"
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

# Ek araçların kurulumu
echo -e "${YELLOW}Ek araçlar kuruluyor...${NC}"
additional_tools=(
    ttyd dool nmap
)
install_packages "${additional_tools[@]}"

# ttyd ve nmap kullanımı örnekleri
echo -e "${YELLOW}ttyd ve nmap kullanımı örnekleri...${NC}"
ttyd top &
nmap -p- localhost

echo -e "${GREEN}Tüm işlemler başarıyla tamamlandı.${NC}"
