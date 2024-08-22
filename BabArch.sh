#!/bin/bash
set -euo pipefail
source ./common.sh  # Ortak fonksiyon ve değişkenleri dahil et

# Mevcut sistemde disklerin doğru biçimlendirilip biçimlendirilmediğini kontrol eden fonksiyon
check_existing_setup() {
    # /mnt dizininin dolu olup olmadığını kontrol et
    if mountpoint -q /mnt && [ "$(ls -A /mnt)" ]; then
        echo "Diskler zaten bağlanmış görünüyor ve /mnt dizini dolu."
        
        # /mnt/etc/fstab dosyasının olup olmadığını ve içeriğinin doğru olup olmadığını kontrol et
        if [ -f /mnt/etc/fstab ] && grep -q "/mnt" /mnt/etc/fstab; then
            echo "/mnt/etc/fstab dosyası doğru oluşturulmuş."
            return 0  # Her şey doğru ise 0 (başarı) döndür
        else
            echo "fstab dosyasında bir sorun var veya doğru oluşturulmamış."
            return 1  # fstab dosyasında sorun varsa 1 (hata) döndür
        fi
    else
        echo "Diskler doğru biçimlendirilmemiş veya /mnt dizini boş."
        return 1  # Diskler doğru biçimlendirilmemişse veya /mnt boşsa 1 (hata) döndür
    fi
}

# Ana betikte kontrol yapalım
main() {
    printf "${YELLOW}Kurulum başlıyor, arkanıza yaslanın ve kahvenizi yudumlayın...${RESET}\n"
    
    setup_keyboard_and_font
    check_required_packages
    check_uefi
    check_internet
    check_microcode

    # Eğer mevcut kurulum doğruysa, disk işlemlerini atla ve direkt chroot aşamasına geç
    if check_existing_setup; then
        printf "${GREEN}Mevcut kurulum doğrulandı, disk işlemleri atlanıyor...${RESET}\n"
        configure_system
    else
        # Disk işlemleri ve kurulum süreci burada devam edecek
        update_system_clock
        set_disk_variable
        wipe_disk
        partition_disk
        encrypt_partition
        format_partitions
        mount_root_device
        create_btrfs_subvolumes
        mount_btrfs_subvolumes
        mount_esp_partition
        synchronize_package_databases
        generate_mirrorlist
        install_base_system
        generate_fstab
        configure_system
    fi

    printf "${GREEN}Kurulum tamamlandı, sistem yeniden başlatılıyor...${RESET}\n"
    reboot_system
}

# İlerleme göstergesi ile başlatma
show_progress "İşlemler başlatılıyor" 5
main "$@"
