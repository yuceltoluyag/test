#!/bin/bash

LOG_FILE="/var/log/arch_install.log"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() {
    local msg="$1"
    local level="$2"
    local color=""

    case "$level" in
        INFO) color="$GREEN" ;;
        WARN) color="$YELLOW" ;;
        ERROR) color="$RED" ;;
    esac

    printf "${color}%s [%s] %s${NC}\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg" | tee -a >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")
}

install_font() {
    log "Terminus fontu yükleniyor..." "INFO"
    pacman -Sy --noconfirm terminus-font || log "Terminus font kurulumu başarısız." "ERROR"
    setfont ter-v24n || log "Font ayarlanamadı." "ERROR"
}

virt_check() {
    local hypervisor
    hypervisor=$(systemd-detect-virt)
    log "${hypervisor^} tespit edildi, misafir araçları kuruluyor..." "INFO"
    case "$hypervisor" in
        kvm) packages="qemu-guest-agent" ;;
        vmware) packages="open-vm-tools" ;;
        oracle) packages="virtualbox-guest-utils" ;;
        microsoft) packages="hyperv" ;;
        *) 
            log "Sanallaştırma tespit edilmedi veya desteklenmeyen bir sanallaştırma platformu tespit edildi. Devam ediyor..." "INFO"
            return ;;
    esac

    pacstrap /mnt $packages &>/dev/null
    systemctl enable --root=/mnt $packages &>/dev/null
}

mount_partition() {
    local part="$1"
    local mount_point="$2"
    log "$mount_point dizini için $part monte ediliyor..." "INFO"
    mkdir -p "$mount_point"
    mount "$part" "$mount_point" || log "$mount_point monte edilemedi." "ERROR"
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

select_disk() {
    log "Kurulum için kullanılacak disk seçiliyor..." "INFO"
    PS3="Lütfen kurulumu yapacağınız diskin numarasını seçin: "
    disks=$(lsblk -dpnoNAME,SIZE,MODEL | grep -P "/dev/sd|/dev/nvme|/dev/vd")

    select disk in $disks; do
        if [ -n "$disk" ]; then
            log "Kurulum için seçilen disk: $disk" "INFO"
            read -p "Lütfen seçiminizi onaylayın (y/N): " confirm
            [[ "$confirm" =~ ^[yY]$ ]] && setup_partitions && break
            log "Disk seçimi iptal edildi, lütfen tekrar deneyin." "WARN"
        else
            log "Geçersiz bir seçim yaptınız. Lütfen tekrar deneyin." "ERROR"
        fi
    done
}

rotate_logs() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -ge 1048576 ]; then
        mv "$LOG_FILE" "$LOG_FILE.$(date +%F-%T)"
        touch "$LOG_FILE"
        log "Log dosyası döndürüldü." "INFO"
    fi
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
    while true; do
        read -r -p "Lütfen hostname adını girin: " hostname
        if [[ -z "$hostname" ]]; then
            log "Hostname boş olamaz. Lütfen geçerli bir hostname girin." "ERROR"
        else
            break
        fi
    done
    echo "$hostname" > /mnt/etc/hostname
    cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname.localdomain   $hostname
EOF
    log "Hostname başarıyla ayarlandı: $hostname" "INFO"
}

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

check_uefi_mode() {
    log "UEFI modda önyükleme kontrol ediliyor..." "INFO"
    if [ -d /sys/firmware/efi/efivars ]; then
        fw_size=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null)
        if [ "$fw_size" == "64" ]; then
            log "Sistem 64-bit UEFI modda önyüklenmiş." "INFO"
        elif [ "$fw_size" == "32" ]; then
            log "Sistem 32-bit UEFI modda önyüklenmiş." "INFO"
        else
            log "UEFI modda önyüklendiği doğrulandı, ancak bit boyutu belirlenemedi." "INFO"
        fi
    else
        log "Sistem BIOS modda önyüklenmiş. Bu kurulum rehberi UEFI tabanlıdır." "ERROR"
        exit 1
    fi
}

# Disk silme (wipe) işlemi
wipe_disk() {
    log "DİKKAT: $disk tamamen sıfırlanacak. Bu işlem geri alınamaz!" "WARN"
    read -p "Disk silme işlemine devam etmek istediğinizden emin misiniz? (y/N): " confirm
    if [[ "$confirm" != [yY] ]]; then
        log "Disk silme işlemi iptal edildi." "INFO"
        return
    fi

    log "Disk silme işlemi başlatılıyor..." "INFO"

    # Geçici bir şifreleme konteyneri oluştur
    cryptsetup open --type plain -d /dev/urandom $disk wipe_me || {
        log "Geçici şifreleme konteyneri oluşturulamadı." "ERROR"
        exit 1
    }

    # Konteyner üzerinde sıfırlama işlemi yap
    dd bs=1M if=/dev/zero of=/dev/mapper/wipe_me status=progress || {
        log "Disk sıfırlama işlemi başarısız." "ERROR"
        cryptsetup close wipe_me
        exit 1
    }

    # Konteyneri kapat
    cryptsetup close wipe_me || log "Geçici şifreleme konteyneri kapatılamadı." "ERROR"

    log "Disk sıfırlama işlemi başarıyla tamamlandı." "INFO"
}

prompt_wipe_disk() {
    # Kullanıcının seçtiği diskin boyutunu belirleyin
    disk_size_bytes=$(lsblk -b -n -o SIZE "$disk")
    disk_size_mb=$(awk "BEGIN {print $disk_size_bytes / 1024 / 1024}")  # MB'ye çevir

    # Yazma hızını otomatik olarak belirlemek için test yap
    log "Yazma hızı otomatik olarak belirleniyor..." "INFO"
    test_file="/tmp/testfile"
    dd_output=$(dd if=/dev/zero of="$test_file" bs=1M count=100 oflag=dsync 2>&1)

    if [[ $? -ne 0 ]]; then
        log "Yazma hızı testi sırasında bir hata oluştu: $dd_output" "ERROR"
        writing_speed_mb_s=33.4  # Varsayılan bir değere geri dönülüyor
        log "Varsayılan yazma hızı $writing_speed_mb_s MB/s olarak ayarlandı." "WARN"
    else
        writing_speed_mb_s=$(echo "$dd_output" | grep -oP '\d+\.\d+(?= MB/s)')
        writing_speed_mb_s=${writing_speed_mb_s%.*}  # Ondalık kısmı sil
    fi

    # Test dosyasını kaldır
    rm -f "$test_file"

    # Toplam yazma süresi (saniye cinsinden)
    total_time_seconds=$(awk "BEGIN {print $disk_size_mb / $writing_speed_mb_s}")

    # Saniyeyi dakikaya çevir ve tam sayı olarak göster
    total_time_minutes=$(awk "BEGIN {print int($total_time_seconds / 60)}")

    # Toplam süreyi saat ve dakikaya dönüştürme
    hours=$(awk "BEGIN {print int($total_time_minutes / 60)}")
    minutes=$(awk "BEGIN {print $total_time_minutes % 60}")

    # Toplam süreyi bilgi olarak göster
    if [[ $hours -gt 0 ]]; then
        log "Disk sıfırlama işlemi yaklaşık olarak $hours saat ve $minutes dakika sürecektir." "INFO"
    else
        log "Disk sıfırlama işlemi yaklaşık olarak $total_time_minutes dakika sürecektir." "INFO"
    fi

    log "Bu işlem diskin tüm verilerini geri dönülemez bir şekilde siler." "WARN"

    read -p "Disk sıfırlama işlemini başlatmak istiyor musunuz? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        wipe_disk
    else
        log "Disk sıfırlama işlemi atlandı, diğer adımlara geçiliyor..." "INFO"
    fi
}



configure_partitions() {
    log "Disk Sıfırlama İşlemi Başlatılıyor..." "INFO"
    prompt_wipe_disk
    log "Eski bölüm düzeni siliniyor..." "INFO"
    if ! (wipefs -af $disk && sgdisk --zap-all --clear $disk && partprobe $disk); then
        log "Eski bölüm düzeni silinirken hata oluştu." "ERROR"
        exit 1
    fi
    
    log "Disk bölümlendiriliyor..." "INFO"
    if ! (sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:esp $disk && sgdisk -n 0:0:0 -t 0:8309 -c 0:luks $disk && partprobe $disk); then
        log "Disk bölümlendirme başarısız." "ERROR"
        exit 1
    fi
    sgdisk -p $disk
    log "Bölümler başarıyla oluşturuldu: EFI Bölümü -> $part1, Kök Bölümü -> $part2" "INFO"
}


setup_filesystems() {
    log "Dosya sistemleri oluşturuluyor..." "INFO"
    log "${part2} bölümü LUKS1 ile şifreleniyor..." "INFO"
    cryptsetup --type luks1 -v -y luksFormat $part2 || log "LUKS formatlama başarısız." "ERROR"
    log "Şifreli kök bölümü açılıyor..." "INFO"
    cryptsetup open $part2 cryptdev || log "LUKS açma işlemi başarısız." "ERROR"

    log "EFI bölümü ($part1) FAT32 olarak formatlanıyor..." "INFO"
    mkfs.vfat -F32 -n ESP $part1 || log "ESP formatlama başarısız." "ERROR"

    log "Kök bölümü (/dev/mapper/cryptdev) /mnt dizinine monte ediliyor..." "INFO"
    mkfs.btrfs -L archlinux /dev/mapper/cryptdev || log "BTRFS formatlama başarısız." "ERROR"
}

setup_btrfs_subvolumes() {
    log "BTRFS alt birimleri oluşturuluyor..." "INFO"
    mount /dev/mapper/cryptdev /mnt || log "Disk montajı başarısız." "ERROR"

    # Alt birimleri oluşturun
    btrfs subvolume create /mnt/@ || log "Alt birim @ oluşturulamadı." "ERROR"
    btrfs subvolume create /mnt/@home || log "Alt birim @home oluşturulamadı." "ERROR"
    btrfs subvolume create /mnt/@snapshots || log "Alt birim @snapshots oluşturulamadı." "ERROR"
    btrfs subvolume create /mnt/@cache || log "Alt birim @cache oluşturulamadı." "ERROR"
    btrfs subvolume create /mnt/@libvirt || log "Alt birim @libvirt oluşturulamadı." "ERROR"
    btrfs subvolume create /mnt/@log || log "Alt birim @log oluşturulamadı." "ERROR"
    btrfs subvolume create /mnt/@tmp || log "BTRFS alt birimleri oluşturulurken hata oluştu." "ERROR"
    # Kök bölümünü unmount edin
    log "Kök bölümü unmount ediliyor..." "INFO"
    umount /mnt || log "Kök bölümü unmount edilemedi." "ERROR"

    export sv_opts="ssd,rw,noatime,compress-force=zstd:1,space_cache=v2,discard=async"

    log "Kök alt birimi (subvol=@) monte ediliyor..." "INFO"
    mount -o ${sv_opts},subvol=@ /dev/mapper/cryptdev /mnt || log "Kök alt birimi monte edilemedi." "ERROR"
    # Diğer alt birimlere mount noktaları oluşturma
    log "Alt birimler için dizinler oluşturuluyor..." "INFO"
    mkdir -p /mnt/{home,.snapshots,var/cache,var/lib/libvirt,var/log,var/tmp}

    # Alt birimleri monte etme (swap hariç)
    log "Alt birimler monte ediliyor..." "INFO"
    mount -o ${sv_opts},subvol=@home /dev/mapper/cryptdev /mnt/home || log "Home alt birimi monte edilemedi." "ERROR"
    mount -o ${sv_opts},subvol=@snapshots /dev/mapper/cryptdev /mnt/.snapshots || log "Snapshots alt birimi monte edilemedi." "ERROR"
    mount -o ${sv_opts},subvol=@cache /dev/mapper/cryptdev /mnt/var/cache || log "Cache alt birimi monte edilemedi." "ERROR"
    mount -o ${sv_opts},subvol=@libvirt /dev/mapper/cryptdev /mnt/var/lib/libvirt || log "libvirt alt birimi monte edilemedi." "ERROR"
    mount -o ${sv_opts},subvol=@log /dev/mapper/cryptdev /mnt/var/log || log "Log alt birimi monte edilemedi." "ERROR"
    mount -o ${sv_opts},subvol=@tmp /dev/mapper/cryptdev /mnt/var/tmp || log "Tmp alt birimi monte edilemedi." "ERROR"
}

mount_esp() {
    log "EFI bölümü (${part1}) /mnt/efi dizinine monte ediliyor..." "INFO"
    
    # EFI ve boot dizinlerini oluşturma
    mkdir -p /mnt/efi
    mkdir -p /mnt/boot

    # EFI bölümünü monte etme
    if ! mount ${part1} /mnt/efi; then
        log "EFI bölümü ${part1} monte etme başarısız oldu!" "ERROR"
        exit 1
    fi

    log "EFI bölümü başarıyla monte edildi." "INFO"
}

configure_system() {
    log "Paket veritabanları senkronize ediliyor..." "INFO"
    pacman -Syy || log "Paket senkronizasyonu başarısız." "ERROR"

    log "En iyi Almanya mirrorlisti seçiliyor..." "INFO"
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
    pacstrap /mnt --needed base base-devel linux linux-headers linux-firmware $microcode btrfs-progs grub efibootmgr vim networkmanager gvfs exfatprogs dosfstools e2fsprogs man-db man-pages texinfo openssh git reflector wget cryptsetup wpa_supplicant terminus-font bash-completion htop mlocate neovim pacman-contrib pkgfile sudo tmux || log "Temel sistem kurulumu başarısız." "ERROR"

    log "fstab dosyası oluşturuluyor..." "INFO"
    genfstab -U -p /mnt >> /mnt/etc/fstab || log "fstab oluşturma başarısız." "ERROR"

    log "fstab dosyasından 'subvolid' girdileri kaldırılıyor ve 'subvol=' ile güncelleniyor..." "INFO"
    sed -i 's/subvolid=[0-9]*,/subvol=/g' /mnt/etc/fstab || log "fstab dosyası güncellenemedi." "ERROR"

    log "fstab dosyası kontrol ediliyor..." "INFO"
    cat /mnt/etc/fstab
}

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

    # Sudoers dosyasını düzenleme (visudo yerine doğrudan sed kullanımı)
    arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || log "sudoers dosyası güncellenemedi." "ERROR"
}

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
    uuid=$(arch-chroot /mnt blkid -s UUID -o value $part2 2>/dev/null)
    if [ -z "$uuid" ]; then
        log "UUID alınamadı. Diskin doğru biçimlendirildiğini ve bağlı olduğunu kontrol edin. Kurulum iptal ediliyor." "ERROR"
        exit 1
    fi

    # arch-chroot içinde yapılan işlemleri bir komut bloğu olarak ele alıyoruz
    arch-chroot /mnt /bin/bash -c "
        # mkinitcpio yapılandırması
        sed -i 's/^FILES=()/FILES=(\/crypto_keyfile.bin)/' /etc/mkinitcpio.conf
        sed -i 's/^MODULES=.*/MODULES=(btrfs crc32c-intel)/' /etc/mkinitcpio.conf
        sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard autodetect keymap modconf microcode consolefont block encrypt resume filesystems fsck)/' /etc/mkinitcpio.conf

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
        if ! grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --removable --bootloader-id=GRUB; then
            echo 'GRUB kurulumu başarısız oldu.' >&2
            exit 1
        fi

        if ! grub-mkconfig -o /efi/grub/grub.cfg; then
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

finalize_installation() {
    log "Chroot'tan çıkılıyor ve sistem yeniden başlatılıyor..." "INFO"
    mkdir -p /mnt/home/$username/test
    cp -r "$(pwd)"/* /mnt/home/$username/test/
    log "Klasör içeriği /mnt/home/$username/test dizinine başarıyla kopyalandı." "INFO"

    # Dosya sahipliğini hedef kullanıcıya geçiriyoruz
    chown -R $username:$username /mnt/home/$username/test
    log "Kopyalanan dosyaların sahipliği $username kullanıcısına geçirildi." "INFO"

    # Diskleri unmount etme
    # umount -R /mnt || log "Unmount işlemi sırasında hata oluştu." "ERROR"
    # reboot
}

main() {
    rotate_logs
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
