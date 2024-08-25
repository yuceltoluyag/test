#!/bin/bash

# Renkler
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # Renk sıfırlama

# Terminus font yükleme ve ayarlama
install_font() {
    echo -e "${YELLOW}Terminus fontu yükleniyor...${NC}"
    if ! pacman -Qi terminus-font > /dev/null; then
        pacman -Sy --noconfirm terminus-font
    fi
    setfont ter-v24n
}

# Klavye düzeni seçimi
select_keyboard_layout() {
    echo -e "${YELLOW}Mevcut klavye düzenleri listeleniyor...${NC}"
    available_layouts=$(localectl list-keymaps)
    echo "$available_layouts" | column

    echo -e "${YELLOW}Lütfen bir klavye düzeni seçin (Varsayılan: trq):${NC}"
    read -p "Klavye düzenini girin: " keyboard_layout

    # Eğer kullanıcı boş bırakırsa varsayılan trq olarak ayarlanır
    keyboard_layout=${keyboard_layout:-trq}

    # Geçerli bir klavye düzeni olup olmadığını kontrol etme
    if echo "$available_layouts" | grep -qw "$keyboard_layout"; then
        echo -e "${YELLOW}Klavye düzeni ${keyboard_layout} olarak ayarlanıyor...${NC}"
        loadkeys $keyboard_layout
    else
        echo -e "${RED}Hatalı klavye düzeni girdiniz! Varsayılan olarak trq ayarlanıyor...${NC}"
        loadkeys trq
    fi
}

# UEFI mod kontrolü
check_uefi_mode() {
    echo -e "${YELLOW}UEFI modda önyükleme kontrol ediliyor...${NC}"
    if [ -d /sys/firmware/efi/efivars ]; then
        echo -e "${GREEN}Sistem UEFI modda önyüklenmiş.${NC}"
    else
        echo -e "${RED}Sistem BIOS modda önyüklenmiş. Bu kurulum rehberi UEFI tabanlıdır.${NC}"
        echo -e "${RED}Lütfen BIOS modda kurulum yapıyorsanız Arch Wiki'den ilgili rehberi inceleyin.${NC}"
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
    echo -e "${YELLOW}Kurulum için kullanılacak disk seçiliyor...${NC}"
    lsblk -f
    while true; do
        read -p "Lütfen kurulumu yapacağınız diski tam adıyla girin (örn: /dev/sda, /dev/nvme0n1): " disk
        if [ -b "$disk" ]; then
            echo -e "${GREEN}Kurulum için $disk diski seçildi.${NC}"
            export disk
            setup_partitions
            break
        else
            echo -e "${RED}Geçersiz bir disk adı girdiniz. Lütfen tekrar deneyin.${NC}"
        fi
    done
}

# Bölüm silme ve yeniden yapılandırma
configure_partitions() {
    echo -e "${YELLOW}Eski bölüm düzeni siliniyor...${NC}"
    wipefs -af $disk
    sgdisk --zap-all --clear $disk
    partprobe $disk
    echo -e "${GREEN}Eski bölüm düzeni başarıyla silindi.${NC}"

    echo -e "${YELLOW}Disk bölümlendiriliyor...${NC}"
    sgdisk -n 0:0:+512MiB -t 0:ef00 -c 0:esp $disk
    sgdisk -n 0:0:0 -t 0:8309 -c 0:luks $disk
    partprobe $disk

    echo -e "${YELLOW}Yeni bölüm tablosu:${NC}"
    sgdisk -p $disk
}

# LUKS şifreleme ve dosya sistemlerini yapılandırma
setup_filesystems() {
    echo -e "${YELLOW}${part2} bölümü LUKS1 ile şifreleniyor...${NC}"
    cryptsetup --type luks1 -v -y luksFormat $part2
    cryptsetup open $part2 cryptdev

    echo -e "${YELLOW}ESP bölümü formatlanıyor...${NC}"
    mkfs.vfat -F32 -n ESP $part1

    echo -e "${YELLOW}Kök bölümü (cryptdev) BTRFS olarak formatlanıyor...${NC}"
    mkfs.btrfs -L archlinux /dev/mapper/cryptdev

    echo -e "${GREEN}Bölümler başarıyla formatlandı.${NC}"
}

# Alt birimlerin oluşturulması ve bağlanması
setup_btrfs_subvolumes() {
    echo -e "${YELLOW}BTRFS alt birimleri oluşturuluyor...${NC}"
    
    # Disk ilk kez /mnt dizinine monte ediliyor
    mount /dev/mapper/cryptdev /mnt
    
    # Alt birimler oluşturuluyor
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    btrfs subvolume create /mnt/@cache
    btrfs subvolume create /mnt/@libvirt
    btrfs subvolume create /mnt/@log
    btrfs subvolume create /mnt/@tmp
    echo -e "${GREEN}BTRFS alt birimleri başarıyla oluşturuldu.${NC}"

    echo -e "${YELLOW}Kök bölümü umount ediliyor...${NC}"
    umount /mnt

    export sv_opts="rw,noatime,compress-force=zstd:1,space_cache=v2"

    # Alt birimler monte ediliyor
    echo -e "${YELLOW}Kök alt birimi (subvol=@) monte ediliyor...${NC}"
    mount -o ${sv_opts},subvol=@ /dev/mapper/cryptdev /mnt

    mkdir -p /mnt/{home,.snapshots,var/cache,var/lib/libvirt,var/log,var/tmp}

    echo -e "${YELLOW}Ek alt birimler monte ediliyor...${NC}"
    mount -o ${sv_opts},subvol=@home /dev/mapper/cryptdev /mnt/home
    mount -o ${sv_opts},subvol=@snapshots /dev/mapper/cryptdev /mnt/.snapshots
    mount -o ${sv_opts},subvol=@cache /dev/mapper/cryptdev /mnt/var/cache
    mount -o ${sv_opts},subvol=@libvirt /dev/mapper/cryptdev /mnt/var/lib/libvirt
    mount -o ${sv_opts},subvol=@log /dev/mapper/cryptdev /mnt/var/log
    mount -o ${sv_opts},subvol=@tmp /dev/mapper/cryptdev /mnt/var/tmp

    echo -e "${GREEN}Tüm alt birimler başarıyla monte edildi.${NC}"
}

# ESP bölümü monte etme
mount_esp() {
    echo -e "${YELLOW}ESP bölümü ${part1} /mnt/efi dizinine monte ediliyor...${NC}"
    mkdir -p /mnt/efi
    if mount ${part1} /mnt/efi; then
        echo -e "${GREEN}ESP bölümü ${part1} başarıyla /mnt/efi dizinine monte edildi.${NC}"

    else
        echo -e "${RED}EFI bölümünü ${part1} monte etme başarısız oldu!${NC}"
        exit 1
    fi
}

# Temel yapılandırma işlemleri
configure_system() {
    # Temel paketlerin yüklenmesi
    echo -e "${YELLOW}Paket veritabanları senkronize ediliyor...${NC}"
    pacman -Syy

    echo -e "${YELLOW}En iyi Alman aynaları seçiliyor...${NC}"
    reflector --verbose --protocol https --latest 5 --sort rate --country Germany --save /etc/pacman.d/mirrorlist
    echo -e "${GREEN}Ayna listesi başarıyla güncellendi.${NC}"

    # İşlemciye göre microcode seçimi
    echo -e "${YELLOW}İşlemci türü kontrol ediliyor...${NC}"
    if grep -q "GenuineIntel" /proc/cpuinfo; then
        export microcode="intel-ucode"
        echo -e "${GREEN}Intel işlemci tespit edildi, intel-ucode seçildi.${NC}"
    elif grep -q "AuthenticAMD" /proc/cpuinfo; then
        export microcode="amd-ucode"
        echo -e "${GREEN}AMD işlemci tespit edildi, amd-ucode seçildi.${NC}"
    else
        echo -e "${RED}İşlemci türü tespit edilemedi, microcode paketi seçilemedi.${NC}"
        exit 1
    fi

    # Temel sistemi yükleme
    echo -e "${YELLOW}Temel sistem yükleniyor...${NC}"
    pacstrap /mnt --needed base base-devel ${microcode} btrfs-progs linux linux-firmware bash-completion cryptsetup htop man-db mlocate neovim networkmanager openssh pacman-contrib pkgfile reflector sudo grub efibootmgr terminus-font vim tmux
    echo -e "${GREEN}Temel sistem başarıyla yüklendi.${NC}"

    # fstab dosyasını oluşturma
    echo -e "${YELLOW}fstab dosyası oluşturuluyor...${NC}"
    genfstab -U -p /mnt >> /mnt/etc/fstab
    echo -e "${GREEN}fstab dosyası başarıyla oluşturuldu.${NC}"
}

# Kullanıcıyı oluşturma ve şifre belirleme
set_user_and_password() {
    local user=$1
    local pass
    local pass_confirm
    local retry_limit=3
    local attempts=0

    # Kullanıcıyı kontrol et ve varsa sadece şifresini güncelle
    if arch-chroot /mnt id -u "$user" >/dev/null 2>&1; then
        echo "Kullanıcı $user zaten mevcut. Şifresi güncellenecek."
    else
        # Kullanıcıyı oluştur
        arch-chroot /mnt useradd -m -G wheel -s /bin/bash "$user"
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
                echo "Şifre belirlenirken bir hata oluştu. Tekrar deneyin."
            fi
        else
            echo "Şifreler eşleşmiyor, tekrar deneyin."
        fi
        attempts=$((attempts + 1))
        if [ "$attempts" -ge "$retry_limit" ]; then
            echo "Çok fazla başarısız deneme. İşlem iptal ediliyor."
            exit 1
        fi
    done
}

# Chroot işlemi öncesi kontrol
check_mounts_before_chroot() {
    echo -e "${YELLOW}Chroot öncesi disklerin doğru monte edildiği kontrol ediliyor...${NC}"
    if mountpoint -q /mnt && mountpoint -q /mnt/efi && mountpoint -q /mnt/home && mountpoint -q /mnt/.snapshots; then
        echo -e "${GREEN}Tüm montajlar başarılı.${NC}"
    else
        echo -e "${RED}Montajlarda sorun var. Lütfen tekrar kontrol edin.${NC}"
        exit 1
    fi
}

# Chroot içindeki yapılandırma
configure_chroot() {
    echo -e "${YELLOW}Sisteme chroot ile giriliyor ve yapılandırma adımları gerçekleştiriliyor...${NC}"
    arch-chroot /mnt /bin/bash -e <<EOF

# 2.1 Zaman dilimini ayarlama (Istanbul)
ln -sf /usr/share/zoneinfo/Europe/Istanbul /etc/localtime
hwclock --systohc

# 2.2 Hostname ayarlama (kullanıcı girdisi)
read -p "Lütfen hostname adını girin: " hostname
echo "\$hostname" > /etc/hostname
cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   \$hostname.localdomain \$hostname
EOL

# 2.3 Locale ayarlama (tr_TR.UTF-8 ve en_US.UTF-8)
sed -i "s/^#\(tr_TR.UTF-8\)/\1/" /etc/locale.gen
sed -i "s/^#\(en_US.UTF-8\)/\1/" /etc/locale.gen
echo "LANG=tr_TR.UTF-8" > /etc/locale.conf
echo "LC_MESSAGES=en_US.UTF-8" >> /etc/locale.conf
locale-gen

# 2.5 Varsayılan editör ayarlama (neovim)
echo "EDITOR=nvim" > /etc/environment
echo "VISUAL=nvim" >> /etc/environment

# 2.8 NetworkManager'ı başlatmada etkinleştirme
systemctl enable NetworkManager
echo -e "${GREEN}NetworkManager etkinleştirildi. Kablosuz ağ bağlantısı için nmtui kullanabilirsiniz.${NC}"

# 2.9 SSH sunucusunu etkinleştirme
echo -e "${YELLOW}SSH sunucusu etkinleştiriliyor...${NC}"
systemctl enable sshd.service
echo -e "${GREEN}SSH sunucusu başarıyla etkinleştirildi.${NC}"

# 2.10 Keyfile oluşturma ve LUKS'e ekleme
echo -e "${YELLOW}LUKS için keyfile oluşturuluyor...${NC}"
dd bs=512 count=4 iflag=fullblock if=/dev/random of=/crypto_keyfile.bin
chmod 600 /crypto_keyfile.bin
cryptsetup luksAddKey $part2 /crypto_keyfile.bin

# 2.11 mkinitcpio yapılandırması
echo -e "${YELLOW}mkinitcpio yapılandırılıyor...${NC}"
sed -i "s/^FILES=()/FILES=(\/crypto_keyfile.bin)/" /etc/mkinitcpio.conf
sed -i "s/^MODULES=()/MODULES=(btrfs)/" /etc/mkinitcpio.conf
sed -i "s/^HOOKS=.*/HOOKS=(base udev keyboard autodetect keymap consolefont modconf block encrypt filesystems fsck)/" /etc/mkinitcpio.conf

# 2.12 initramfs imajını oluşturma
mkinitcpio -P
echo -e "${GREEN}initramfs imajı başarıyla oluşturuldu.${NC}"

# Şifreli bölümün UUID'sini belirleme
uuid=$(blkid -s UUID -o value $part2)
if [ -z "$uuid" ]; then
    echo -e "${RED}UUID alınamadı, kurulum iptal ediliyor.${NC}"
    exit 1
fi
# /etc/default/grub yapılandırması
sed -i "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet cryptdevice=UUID=$uuid:cryptdev\"/" /etc/default/grub
sed -i "s/^#GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES=\"part_gpt part_msdos luks\"/" /etc/default/grub
sed -i "s/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/" /etc/default/grub

# GRUB'u ESP'ye yükleme
grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/efi --bootloader-id=GRUB

# GRUB yapılandırma dosyasını oluşturma
grub-mkconfig -o /efi/grub/grub.cfg

# GRUB yapılandırmasında cryptodisk ve luks modüllerinin doğru yüklendiğini doğrulama
if grep -q 'cryptodisk\|luks' /efi/grub/grub.cfg; then
  echo -e "${GREEN}GRUB yapılandırması başarıyla tamamlandı ve gerekli modüller yüklendi.${NC}"
else
  echo -e "${RED}GRUB yapılandırması sırasında bir hata oluştu. cryptodisk veya luks modülleri eksik.${NC}"
  exit 1  # Hata oluştuğunda kurulumu durdurma
fi 
EOF
}

# Chroot'tan çıkış ve sistemin yeniden başlatılması
finalize_installation() {
    # Chroot işlemi başarıyla tamamlandıysa finalize işlemlerine geç
    echo -e "${YELLOW}Chroot'tan çıkılıyor ve sistem yeniden başlatılıyor...${NC}"
    # Bulunduğunuz klasörün içeriğini /mnt/home/kullanıcıadı/test klasörüne kopyalama
    mkdir -p /mnt/home/$username/test
    cp -r "$(pwd)"/* /mnt/home/$username/test/
    echo -e "${GREEN}Klasör içeriği /mnt/home/$username/test dizinine başarıyla kopyalandı.${NC}"
    # Diskleri unmount etme
    #umount -R /mnt || { echo -e "${RED}Unmount işlemi sırasında hata oluştu.${NC}"; exit 1; }
    #reboot
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
    configure_system
    check_mounts_before_chroot
    configure_chroot
    read -r -p "Lütfen bir kullanıcı hesabı için ad girin: " username
    set_user_and_password "$username"
    set_user_and_password "root"
    finalize_installation
}

main
