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
        pacman -Syy --noconfirm terminus-font || log "Terminus font kurulumu başarısız." "ERROR"
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
            systemctl enable qemu-guest-agent --root=/mnt &>/dev/null || log "qemu-guest-agent etkinleştirilemedi." "ERROR"
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
    
    # Kullanılabilir diskleri listeleme
    disks=$(lsblk -dpno NAME,SIZE,MODEL | grep -P "/dev/sd|/dev/nvme|/dev/vd")

    # Disk listesini kullanıcıya seçenek olarak göster
    PS3="Lütfen kurulumu yapacağınız diskin numarasını seçin (örn: 1, 2, 3): "
    select disk in $(echo "$disks" | awk '{print $1}'); do
        if [ -n "$disk" ]; then
            log "Kurulum için seçilen disk: $disk" "INFO"
            echo "$disks" | grep "$disk"  # Seçilen diskin detaylarını göster
            read -p "Lütfen seçiminizi onaylayın (y/N): " confirm
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                export disk
                setup_partitions
                break
            else
                log "Disk seçimi iptal edildi, lütfen tekrar deneyin." "WARN"
            fi
        else
            log "Geçersiz bir seçim yaptınız. Lütfen tekrar deneyin." "ERROR"
        fi
    done
}
# Disk silme (wipe) işlemi
wipe_disk() {
    log "DİKKAT: $disk tamamen sıfırlanacak. Bu işlem geri alınamaz!" "WARN"
    read -p "Disk silme işlemine devam etmek istediğinizden emin misiniz? (y/N): " confirm
    if [[ "$confirm" != [yY] ]]; then
        log "Disk silme işlemi iptal edildi." "INFO"
        return
    fi

    disk_size_bytes=$(lsblk -b -n -o SIZE "$disk")
    disk_size_mb=$(awk -v size_bytes="$disk_size_bytes" 'BEGIN {print int(size_bytes / 1024 / 1024 * 0.99)}')  # %99 güvenlik marjı
    
    log "Disk boyutu: $disk_size_mb MB" "INFO"
    log "Disk silme işlemi başlatılıyor..." "INFO"

    cryptsetup open --type plain -d /dev/urandom "$disk" wipe_me || {
        log "Geçici şifreleme konteyneri oluşturulamadı." "ERROR"
        exit 1
    }

    (
        dd if=/dev/zero of=/dev/mapper/wipe_me bs=1M count="$disk_size_mb" status=progress oflag=sync conv=fdatasync | {
            while IFS= read -r line; do
                if [[ "$line" =~ bytes.*copied ]]; then
                    copied=$(echo "$line" | grep -oP '\d+(?= bytes)')
                    duration=$(echo "$line" | grep -oP '(?<=, )\d+(\.\d+)?(?= s)')
                    speed=$(awk "BEGIN {print $copied / $duration / 1024 / 1024}")
                    log "Mevcut yazma hızı: ${speed} MB/s" "INFO"
                    log "Toplam yazılan veri: ${copied} bytes" "INFO"  # Toplam yazılan veri miktarını göster
                fi
            done
}
    ) &

    log "Disk sıfırlama işlemi devam ediyor... İptal etmek için 'q' tuşuna basabilirsiniz." "INFO"
    while kill -0 $! 2>/dev/null; do
        read -t 1 -n 1 key
        if [[ "$key" == "q" ]]; then
            log "Disk sıfırlama işlemi iptal edildi, çıkılıyor..." "WARN"
            kill $! 2>/dev/null
            sync
            sleep 2
            cryptsetup close wipe_me || log "Geçici şifreleme konteyneri kapatılamadı." "ERROR"
            return
        fi
    done

    wait $!
    sync
    sleep 2

    if ! cryptsetup close wipe_me; then
        log "Geçici şifreleme konteyneri kapatılamadı, manuel olarak kapatılmaya çalışılıyor..." "ERROR"
        if ! dmsetup remove wipe_me; then
            log "Geçici şifreleme konteyneri manuel olarak kapatılamadı." "ERROR"
            return
        fi
    fi

    log "Disk sıfırlama işlemi başarıyla tamamlandı." "INFO"
}
ask_for_wipe_disk() {
    log "50 GB'lik bir Hard-disk, 61.9 MB/s hızla sıfırlanırken yaklaşık 13 dakika 28 saniye sürüyor." "INFO"
    log "Eğer yazma hızınız düşükse ve sabırlı değilseniz, wipe_disk fonksiyonunun çalıştırılmasını tekrar düşünün." "WARN"
    log "Bu işlem, diskteki tüm verileri geri alınamaz şekilde siler ve diskteki tüm mevcut bölümleri kaldırır." "WARN"
    log "Bu işlemden sonra verilerin geri yüklenmesi mümkün değildir!" "ERROR"

    read -p "Disk sıfırlama işlemini başlatmak istiyor musunuz? (y/N): " confirm
    if [[ "$confirm" =~ ^[yY]$ ]]; then
        wipe_disk
    else
        log "Disk sıfırlama işlemi atlandı, diğer adımlara geçiliyor..." "INFO"
    fi
}
# Bölüm silme ve yeniden yapılandırma
configure_partitions() {
    log "Güvenli Disk Sıfırlama İşlemi Başlatılıyor..." "INFO"
    ask_for_wipe_disk
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

# Dosya sistemleri oluşturuluyor
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


# Alt birimlerin oluşturulması ve bağlanması
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

    export sv_opts="ssd,rw,noatime,compress-force=zstd:6,space_cache=v2,discard=async"

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
# ESP bölümü monte etme
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

# Temel yapılandırma işlemleri
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
    pacstrap -K /mnt --needed base base-devel linux linux-headers linux-firmware $microcode btrfs-progs grub efibootmgr vim networkmanager gvfs exfatprogs dosfstools e2fsprogs man-db man-pages texinfo openssh git reflector wget cryptsetup wpa_supplicant terminus-font bash-completion htop mlocate neovim pacman-contrib pkgfile sudo tmux || log "Temel sistem kurulumu başarısız." "ERROR"

    log "fstab dosyası oluşturuluyor..." "INFO"
    genfstab -U -p /mnt >> /mnt/etc/fstab || log "fstab oluşturma başarısız." "ERROR"

    log "fstab dosyası kontrol ediliyor..." "INFO"
    cat /mnt/etc/fstab
}

# Kullanıcıyı oluşturma ve şifre belirleme
set_user_and_password() {
    local user=$1
    local pass
    local pass_confirm
    local retry_limit=3
    local attempts=0

    # Kullanıcı var mı kontrolü
    if arch-chroot /mnt id -u "$user" >/dev/null 2>&1; then
        log "Kullanıcı $user zaten mevcut. Şifresi güncellenecek." "INFO"
    else
        arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$user" || log "Kullanıcı $user oluşturulamadı." "ERROR"
    fi

    # Şifreyi güvenli şekilde alma ve doğrulama
    while true; do
        read -r -s -p "$user için bir şifre belirleyin: " pass
        echo
        read -r -s -p "Şifreyi tekrar girin: " pass_confirm
        echo
        if [ "$pass" == "$pass_confirm" ]; then
            if echo "$user:$pass" | arch-chroot /mnt chpasswd; then
                log "Kullanıcı $user için şifre başarıyla ayarlandı." "INFO"
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
    # /mnt/etc/sudoers dosyasının mevcut olup olmadığını kontrol et
    if [ ! -f /mnt/etc/sudoers ]; then
        log "/mnt/etc/sudoers dosyası bulunamadı. sudo paketini yeniden yüklüyoruz..." "WARN"
        arch-chroot /mnt pacman -Syy --noconfirm sudo || log "Sudo paketi yüklenemedi." "ERROR"
    fi
    # Sudoers dosyasını düzenleme (NOPASSWD yetkisi geçici olarak veriliyor)
    arch-chroot /mnt sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers || log "sudoers dosyası güncellenemedi." "ERROR"
    log "Sudoers dosyası yeniden oluşturuluyor..." "INFO"
    arch-chroot /mnt bash -c 'echo "%wheel ALL=(ALL) ALL" > /etc/sudoers'
    # Geçici NOPASSWD yetkisini kaldırma
    arch-chroot /mnt sed -i "/^$user ALL=(ALL) NOPASSWD:ALL$/d" /mnt/etc/sudoers
    log "Kullanıcı $user için geçici NOPASSWD yetkisi kaldırıldı." "INFO"
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



# Chroot içindeki yapılandırma
configure_chroot() {
    log "Sisteme chroot ile giriliyor ve yapılandırma adımları gerçekleştiriliyor..." "INFO"

    # UUID'yi dışarıda alın
    uuid=$(blkid -s UUID -o value $part2)
    if [ -z "$uuid" ]; then
        log "UUID alınamadı, kurulum iptal ediliyor." "ERROR"
        exit 1
    fi

    arch-chroot /mnt /bin/bash -e <<EOF
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

# mkinitcpio yapılandırması
sed -i 's/^FILES=()/FILES=(\/crypto_keyfile.bin)/' /etc/mkinitcpio.conf
sed -i 's/^MODULES=.*/MODULES=(btrfs crc32c-intel)/' /etc/mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard kms autodetect keymap modconf microcode consolefont block encrypt resume filesystems fsck)/' /etc/mkinitcpio.conf

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
grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --removable --bootloader-id=GRUB
if [ \$? -ne 0 ]; then
    echo 'GRUB kurulumu başarısız oldu. EFI dizinini ve disk yapısını kontrol edin.' >&2
    exit 1
fi

grub-mkconfig -o /efi/grub/grub.cfg
if [ \$? -ne 0 ]; then
    echo 'GRUB yapılandırması başarısız oldu. Konfigürasyon dosyasını kontrol edin.' >&2
    exit 1
fi

EOF

    if [ $? -ne 0 ]; then
        log "mkinitcpio veya GRUB yapılandırmasında bir hata oluştu." "ERROR"
        exit 1
    fi

    log "mkinitcpio ve GRUB başarıyla yapılandırıldı." "INFO"
}


rotate_logs() {
    if [ -f "$LOG_FILE" ]; then  # Log dosyasının varlığını kontrol et
        if [ $(stat -c%s "$LOG_FILE") -ge 1048576 ]; then  # Dosya boyutunu kontrol et
            mv "$LOG_FILE" "$LOG_FILE.$(date +%F-%T)"
            touch "$LOG_FILE"
            chmod 600 "$LOG_FILE"  # Log dosyası izinlerini ayarla
            log "Log dosyası döndürüldü." "INFO"
        fi
    else
        touch "$LOG_FILE"  # Log dosyası yoksa oluştur
        chmod 600 "$LOG_FILE"  # Log dosyası izinlerini ayarla
        log "Yeni log dosyası oluşturuldu." "INFO"
    fi
}


# Chroot'tan çıkış ve sistemin yeniden başlatılması
finalize_installation() {
    log "Chroot'tan çıkılıyor ve sistem yeniden başlatılıyor..." "INFO"
    mkdir -p /mnt/home/$username/test
    cp -r "$(pwd)"/* /mnt/home/$username/test/
    log "Klasör içeriği /mnt/home/$username/test dizinine başarıyla kopyalandı." "INFO"

    # Dosya sahipliğini hedef kullanıcıya geçiriyoruz
    arch-chroot /mnt chown -R $username:$username /home/$username/test
    log "Kopyalanan dosyaların sahipliği $username kullanıcısına geçirildi." "INFO"
    log "Kurulum tamamlandı. Log dosyasını görüntülüyorsunuz..." "INFO"
    less "$LOG_FILE"
    log "Kurulum tamamlandı! Sistem yeniden başlatılıyor..." "INFO"


    # Diskleri unmount etme
    # umount -R /mnt || log "Unmount işlemi sırasında hata oluştu." "ERROR"
    # reboot
}


# Tüm işlemleri başlatma
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
