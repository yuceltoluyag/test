# Arch Linux Otomatik Kurulum Scripti

Bu repo, Arch Linux'un otomatik kurulum ve yapılandırma sürecini kolaylaştırmak için hazırlanmış bash scriptlerini içerir. Kurulum süreci, sistemin temel yapılandırmasından post-installation (sonraki kurulum) adımlarına kadar tüm adımları kapsamaktadır.

## İçerik

- **main-installation.sh**: Arch Linux'un temel kurulumunu gerçekleştiren script.
- **post-installation.sh**: Sistem kurulduktan sonra çeşitli araçların ve yapılandırmaların yapılmasını sağlayan script.

## Kurulum ve Kullanım

### 1. Arch Linux Temel Kurulumu (main-installation.sh)

Bu script, sistemin ilk kurulumu için kullanılır. Sistem, disk yapılandırmasından GRUB yüklemeye kadar tüm işlemleri otomatik olarak gerçekleştirir.

**Kullanım:**

1. Script dosyasını çalıştırın:

   ```bash
   sudo bash main-installation.sh
   ```

2. Script çalışmaya başladığında sizden aşağıdaki bilgileri isteyecektir:

   - Klavye düzeni
   - Disk seçimi
   - Hostname (sistem adı)
   - Root şifresi
   - Yeni kullanıcı adı ve şifresi

3. Kurulum tamamlandığında sistem otomatik olarak yeniden başlatılır.

**Not:** Kurulum sırasında UEFI kontrolü yapılır. Eğer sistem BIOS modda başlatılmışsa kurulum durdurulacaktır.

### 2. Post-Installation (post-installation.sh)

Sistem kurulduktan sonra, bu script temel paketlerin kurulmasını ve yapılandırılmasını sağlar.

**Kullanım:**

1. Script dosyasını çalıştırın:

   ```bash
   sudo bash post-installation.sh
   ```

2. Script şu işlemleri gerçekleştirir:
   - X.Org, LightDM, i3 pencere yöneticisi kurulumu
   - Ağ yönetimi araçları ve Python geliştirme araçları kurulumu
   - Snapper yapılandırması
   - Zram swap yapılandırması
   - Ek araçların kurulumu (ttyd, nmap vb.)

### Kurulumdan Sonra Yapılacaklar

- Sistemin yeniden başlatılmasının ardından kullanıcı hesabınızla giriş yapabilirsiniz.
- Ağ bağlantısını `nmtui` arayüzü üzerinden yapılandırabilirsiniz.

### Notlar

- Script renkli terminal çıktısı sunmaktadır.
- Kurulum ve yapılandırma adımları tamamen otomatikleştirilmiştir.
- Eğer scriptlerde herhangi bir hatayla karşılaşırsanız, lütfen geri bildirimde bulunun.

## Geliştirici Notları

- Bu scriptler varsayılan olarak Türkçe klavye düzeni ve yerelleştirme ayarlarını kullanmaktadır.
- Yükleme sürecinde UEFI desteği zorunludur.

## Lisans

Bu proje MIT Lisansı ile lisanslanmıştır. Detaylar için `LICENSE` dosyasına bakabilirsiniz.
