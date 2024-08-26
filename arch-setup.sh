#!/bin/bash

# Log file path
LOG_FILE="/var/log/arch_install.log"

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # Renk sıfırlama

# Log function
log() {
    local msg="$1"
    local level="$2"
    local color=""

    # Mesaj seviyesine göre renk belirleme
    case "$level" in
        INFO) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
    esac

    # Ekrana renkli çıktı, log dosyasına renksiz çıktı
    printf "${color}%s [%s] %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" | tee -a >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")
}


# Terminus font yükleme ve ayarlama
install_font() {
    log "Terminus fontu yükleniyor..." "INFO"
    if ! pacman -Qi terminus-font > /dev/null; then
        pacman -Sy --noconfirm terminus-font || log "Terminus font kurulumu başarısız." "ERROR"
    fi
    setfont ter-v24n || log "Font ayarlanamadı." "ERROR"
}

# Sanallaştırma kontrolü (Virtualization check)
virt_check() {
    hypervisor=$(systemd-detect-virt)
    case $hypervisor in
        kvm )   
            log "KVM tespit edildi, misafir araçları kuruluyor..." "INFO"
            pacstrap /mnt qemu-guest-agent &>/dev/null
            systemctl enable qemu-guest-agent --root=/mnt &>/dev/null
            ;;
        vmware )   
            log "VMWare Workstation/ESXi tespit edildi, misafir araçları kuruluyor..." "INFO"
            pacstrap /mnt open-vm-tools &>/dev/null
            systemctl enable vmtoolsd --root=/mnt &>/dev/null
            systemctl enable vmware-vmblock-fuse --root=/mnt &>/dev/null
            ;;
        oracle )    
            log "VirtualBox tespit edildi, misafir araçları kuruluyor..." "INFO"
            pacstrap /mnt virtualbox-guest-utils &>/dev/null
            systemctl enable vboxservice --root=/mnt &>/dev/null
            ;;
        microsoft ) 
            log "Hyper-V tespit edildi, misafir araçları kuruluyor..." "INFO"
            pacstrap /mnt hyperv &>/dev/null
            systemctl enable hv_fcopy_daemon --root=/mnt &>/dev/null
            systemctl enable hv_kvp_daemon --root=/mnt &>/dev/null
            systemctl enable hv_vss_daemon --root=/mnt &>/dev/null
            ;;
        * ) 
            log "Sanallaştırma tespit edilmedi veya desteklenmeyen bir sanallaştırma platformu tespit edildi. Devam ediyor..." "INFO"
            ;;
    esac
}

setup_keyfile() {
    log "Keyfile oluşturuluyor..." "INFO"
    dd_output=$(dd bs=512 count=4 iflag=fullblock if=/dev/random of=/mnt/crypto_keyfile.bin 2>&1)
    if echo "$dd_output" | grep -q "records in"; then
        chmod 600 /mnt/crypto_keyfile.bin
        log "Keyfile başarıyla oluşturuldu." "INFO"
    else
        log "Keyfile oluşturulurken bir hata meydana geldi: $dd_output" "ERROR"
        exit 1
    fi

    log "Keyfile LUKS'e ekleniyor..." "INFO"
    cryptsetup luksAddKey $part2 /mnt/crypto_keyfile.bin || { log "Keyfile ekleme işlemi başarısız oldu." "ERROR"; exit 1; }
}




set_hostname() {
    local hostname
    read -r -p "Lütfen hostname adını girin: " hostname
    echo "$hostname" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname
EOF
    log "Hostname başarıyla ayarlandı: $hostname" "INFO"
}

# Klavye düzeni seçimi
select_keyboard_layout() {
    log "Mevcut klavye düzenleri listeleniyor..." "INFO"
    available_layouts=$(localectl list-keymaps | grep -E 'trq|us|uk|de')
    echo "$available_layouts" | less

    read -p "Lütfen bir klavye düzeni seçin (Varsayılan: trq): " keyboard_layout
    keyboard_layout=${keyboard_layout:-trq}

    if echo "$available_layouts" | grep -qw "$keyboard_layout"; then
        log "Klavye düzeni $keyboard_layout olarak ayarlanıyor..." "INFO"
        loadkeys $keyboard_layout || log "Klavye düzeni yüklenemedi." "ERROR"
    else
        log "Hatalı klavye düzeni girdiniz! Varsayılan olarak trq ayarlanıyor..." "WARN"
        loadkeys trq || log "Varsayılan klavye düzeni yüklenemedi." "ERROR"
    fi
}


# UEFI mod kontrolü
check_uefi_mode() {
    log "UEFI modda önyükleme kontrol ediliyor..." "INFO"
    if [ -d /sys/firmware/efi/efivars ]; then
        log "Sistem UEFI modda önyüklenmiş." "INFO"
    else
        log "Sistem BIOS modda önyüklenmiş. Bu kurulum rehberi UEFI tabanlıdır." "ERROR"
        exit 1
    fi
}

setup_partitions() {
    if [[ "$disk" == *"nvme"* ]]; then
        part1="${disk}p1"
        part2="${disk}p2"
    else
        part1="${disk}1"
        part2="${disk}2"
    fi
}

# Disk seçimi ve türüne göre partisyon ayarlama
select_disk() {
    log "Kurulum için kullanılacak disk seçiliyor..." "INFO"
    
    # Kullanılabilir diskleri listeleme
    PS3="Lütfen kurulumu yapacağınız diskin numarasını seçin (örn: 1, 2, 3): "
    disks=$(lsblk -dpnoNAME | grep -P "/dev/sd|/dev/nvme|/dev/vd")

    select disk in $disks; do
        if [ -n "$disk" ]; then
            log "Kurulum için $disk diski seçildi: $disk" "INFO"
            export disk
            setup_partitions
            break
        else
            log "Geçersiz bir seçim yaptınız. Lütfen tekrar deneyin." "ERROR"
        fi
    done
}


# Bölüm silme ve yeniden yapılandırma
configure_partitions() {
    log "Eski bölüm düzeni siliniyor..." "INFO"
    wipefs -af $disk && sgdisk --zap-all --clear $disk && partprobe $disk || log "Eski bölüm düzeni silinirken hata oluştu." "ERROR"
    
    log "Disk bölümlendiriliyor..." "INFO"
    sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:esp $disk && \
    sgdisk -n 0:0:0 -t 0:8309 -c 0:luks $disk && \
    partprobe $disk || log "Disk bölümlendirme başarısız." "ERROR"

    sgdisk -p $disk
}

# LUKS şifreleme ve dosya sistemlerini yapılandırma
setup_filesystems() {
    log "${part2} bölümü LUKS1 ile şifreleniyor..." "INFO"
    cryptsetup --type luks1 -v -y luksFormat $part2 || log "LUKS formatlama başarısız." "ERROR"
    cryptsetup open $part2 cryptdev || log "LUKS açma işlemi başarısız." "ERROR"

    log "ESP bölümü formatlanıyor..." "INFO"
    mkfs.vfat -F32 -n ESP $part1 || log "ESP formatlama başarısız." "ERROR"

    log "Kök bölümü (cryptdev) BTRFS olarak formatlanıyor..." "INFO"
    mkfs.btrfs -L archlinux /dev/mapper/cryptdev || log "BTRFS formatlama başarısız." "ERROR"
}

# Alt birimlerin oluşturulması ve bağlanması
setup_btrfs_subvolumes() {
    log "BTRFS alt birimleri oluşturuluyor..." "INFO"
    mount /dev/mapper/cryptdev /mnt || log "Disk montajı başarısız." "ERROR"

    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@cache
    btrfs subvolume create /mnt/@libvirt
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@tmp || log "BTRFS alt birimleri oluşturulurken hata oluştu." "ERROR"

    umount /mnt || log "Disk unmount işlemi başarısız." "ERROR"

    export sv_opts="rw,noatime,compress-force=zstd:1,space_cache=v2"

    log "Kök alt birimi (subvol=@) monte ediliyor..." "INFO"
    mount -o ${sv_opts},subvol=@ /dev/mapper/cryptdev /mnt || log "Kök alt birimi montajı başarısız." "ERROR"

    mkdir -p /mnt/{home,.snapshots,var/cache,var/lib/libvirt,var/log,var/tmp}

    log "Ek alt birimler monte ediliyor..." "INFO"
    mount -o ${sv_opts},subvol=@home /dev/mapper/cryptdev /mnt/home
    mount -o ${sv_opts},subvol=@snapshots /dev/mapper/cryptdev /mnt/.snapshots
    mount -o ${sv_opts},subvol=@cache /dev/mapper/cryptdev /mnt/var/cache
    mount -o ${sv_opts},subvol=@libvirt /dev/mapper/cryptdev /mnt/var/lib/libvirt
    mount -o ${sv_opts},subvol=@log /dev/mapper/cryptdev /mnt/var/log
    mount -o ${sv_opts},subvol=@tmp /dev/mapper/cryptdev /mnt/var/tmp || log "Alt birimlerin montajı başarısız." "ERROR"
}

# ESP bölümü monte etme
mount_esp() {
    log "ESP bölümü ${part1} /mnt/efi dizinine monte ediliyor..." "INFO"
    mkdir -p /mnt/efi
    if ! mount ${part1} /mnt/efi; then
        log "EFI bölümünü ${part1} monte etme başarısız oldu!" "ERROR"
        exit 1
    fi
}

# Temel yapılandırma işlemleri
configure_system() {
    log "Paket veritabanları senkronize ediliyor..." "INFO"
    pacman -Syy || log "Paket senkronizasyonu başarısız." "ERROR"

    log "En iyi Alman aynaları seçiliyor..." "INFO"
    reflector --verbose --protocol https --latest 5 --sort rate --country Germany --save /etc/pacman.d/mirrorlist || log "Ayna listesi güncellenemedi." "ERROR"

    log "İşlemci türü kontrol ediliyor..." "INFO"
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        export microcode="intel-ucode"
        log "Intel işlemci tespit edildi, intel-ucode seçildi." "INFO"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        export microcode="amd-ucode"
        log "AMD işlemci tespit edildi, amd-ucode seçildi." "INFO"
    else
        log "İşlemci türü tespit edilemedi, microcode paketi seçilemedi." "ERROR"
        exit 1
    fi

    log "Temel sistem yükleniyor..." "INFO"
    pacstrap /mnt --needed base base-devel ${microcode} btrfs-progs linux linux-firmware bash-completion cryptsetup htop man-db mlocate neovim networkmanager openssh pacman-contrib pkgfile reflector sudo grub efibootmgr terminus-font vim tmux || log "Temel sistem kurulumu başarısız." "ERROR"

    log "fstab dosyası oluşturuluyor..." "INFO"
    genfstab -U -p /mnt >> /mnt/etc/fstab || log "fstab oluşturma başarısız." "ERROR"
}

# Kullanıcıyı oluşturma ve şifre belirleme
set_user_and_password() {
    local user=$1
    local pass
    local pass_confirm
    local retry_limit=3
    local attempts=0

    if arch-chroot /mnt id -u "$user" >/dev/null 2>&1; then
        log "Kullanıcı $user zaten mevcut. Şifresi güncellenecek." "INFO"
    else
        arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$user" || log "Kullanıcı $user oluşturulamadı." "ERROR"
    fi
    sed -i "s/# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/" /etc/sudoers

    while true; do
        read -r -s -p "$user için bir şifre belirleyin: " pass
        echo
        read -r -s -p "Şifreyi tekrar girin: " pass_confirm
        echo
        if [ "$pass" == "$pass_confirm" ]; then
            if echo "$user:$pass" | arch-chroot /mnt chpasswd; then
                break
            else
                log "Şifre belirlenirken bir hata oluştu. Tekrar deneyin." "ERROR"
            fi
        else
            log "Şifreler eşleşmiyor, tekrar deneyin." "ERROR"
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge "$retry_limit" ]; then
            log "Çok fazla başarısız deneme. İşlem iptal ediliyor." "ERROR"
            exit 1
        fi
    done
}

# Chroot işlemi öncesi kontrol
check_mounts_before_chroot() {
    log "Chroot öncesi disklerin doğru monte edildiği kontrol ediliyor..." "INFO"
    if mountpoint -q /mnt && mountpoint -q /mnt/efi && mountpoint -q /mnt/home && mountpoint -q /mnt/.snapshots; then
        log "Tüm montajlar başarılı." "INFO"
    else
        log "Montajlarda sorun var. Lütfen tekrar kontrol edin." "ERROR"
        exit 1
    fi
}

configure_mkinitcpio_and_grub() {
    log "mkinitcpio ve GRUB yapılandırması başlatılıyor..." "INFO"
    
    # UUID'yi alıyoruz
    uuid=$(arch-chroot /mnt blkid -s UUID -o value $part2)
    if [ -z "$uuid" ]; then
        log "UUID alınamadı, kurulum iptal ediliyor." "ERROR"
        exit 1
    fi

    arch-chroot /mnt /bin/bash -c "
    # mkinitcpio yapılandırması
    sed -i 's/^FILES=()/FILES=(\/crypto_keyfile.bin)/' /etc/mkinitcpio.conf
    sed -i 's/^MODULES=()/MODULES=(btrfs)/' /etc/mkinitcpio.conf
    sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect keymap consolefont modconf block encrypt filesystems fsck)/' /etc/mkinitcpio.conf

    # mkinitcpio güncellemesi
    if ! mkinitcpio -P; then
        echo 'mkinitcpio güncellemesi başarısız.' >&2
        exit 1
    fi

    # GRUB yapılandırma
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet cryptdevice=UUID=$uuid:cryptdev\"/' /etc/default/grub
    sed -i 's/^#GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES=\"part_gpt part_msdos luks\"/' /etc/default/grub
    sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

    # GRUB kurulumu ve yapılandırması
    grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=GRUB
    if [ \$? -ne 0 ]; then
        echo 'GRUB kurulumu başarısız oldu.' >&2
        exit 1
    fi
    grub-mkconfig -o /efi/grub/grub.cfg
    if [ \$? -ne 0 ]; then
        echo 'GRUB yapılandırması başarısız oldu.' >&2
        exit 1
    fi
    "

    if [ $? -ne 0 ]; then
        log "mkinitcpio veya GRUB yapılandırmasında bir hata oluştu." "ERROR"
        exit 1
    fi

    log "mkinitcpio ve GRUB başarıyla yapılandırıldı." "INFO"
}

# Chroot içindeki yapılandırma
configure_chroot() {
    log "Sisteme chroot ile giriliyor ve yapılandırma adımları gerçekleştiriliyor..." "INFO"
    arch-chroot /mnt /bin/bash <<'EOF'
# Zaman dilimi ayarlama
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc

# Konsol fontu ve klavye düzeni ayarlama
echo "FONT=ter-v24n" > /etc/vconsole.conf
echo "KEYMAP=trq" >> /etc/vconsole.conf

# Locale ayarlama
sed -i "s/^#\(tr_TR.UTF-8\)/\1/" /etc/locale.gen
sed -i "s/^#\(en_US.UTF-8\)/\1/" /etc/locale.gen
echo "LANG=tr_TR.UTF-8" > /etc/locale.conf
echo "LC_MESSAGES=en_US.UTF-8" >> /etc/locale.conf
echo "LC_ADDRESS=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_COLLATE=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_CTYPE=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_IDENTIFICATION=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_MEASUREMENT=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_MONETARY=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_NAME=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_NUMERIC=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_PAPER=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_TELEPHONE=tr_TR.UTF-8" >> /etc/locale.conf
echo "LC_TIME=tr_TR.UTF-8" >> /etc/locale.conf
locale-gen

# Varsayılan editör ayarlama
echo "EDITOR=nvim" > /etc/environment
echo "VISUAL=nvim" >> /etc/environment

# NetworkManager etkinleştirme
systemctl enable NetworkManager

# SSH sunucusu etkinleştirme
systemctl enable sshd.service
EOF

    if [ $? -eq 0 ]; then
        log "Chroot içi yapılandırma başarıyla tamamlandı." "INFO"
    else
        log "Chroot içi yapılandırmada bir hata oluştu." "ERROR"
    fi

    # mkinitcpio ve GRUB yapılandırmasını ayrı bir fonksiyonda yapıyoruz.
    configure_mkinitcpio_and_grub
}


# Chroot'tan çıkış ve sistemin yeniden başlatılması
finalize_installation() {
    log "Chroot'tan çıkılıyor ve sistem yeniden başlatılıyor..." "INFO"
    mkdir -p /mnt/home/$username/test
    cp -r "$(pwd)"/* /mnt/home/$username/test/
    log "Klasör içeriği /mnt/home/$username/test dizinine başarıyla kopyalandı." "INFO"
    # Diskleri unmount etme
    # umount -R /mnt || log "Unmount işlemi sırasında hata oluştu." "ERROR"
    # reboot
}

# Tüm işlemleri başlatma
main() {
    install_font
    select_keyboard_layout
    check_uefi_mode
    select_disk
    configure_partitions
    setup_filesystems
    setup_btrfs_subvolumes
    mount_esp
    setup_keyfile
    configure_system
    virt_check
    check_mounts_before_chroot
    set_hostname
    configure_chroot
    read -r -p "Lütfen bir kullanıcı hesabı için ad girin: " username
    set_user_and_password "$username"
    set_user_and_password "root"
    finalize_installation
}

main
