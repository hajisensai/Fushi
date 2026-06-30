# hibiki Kullanım Kılavuzu

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | **Türkçe** | [العربية](user-guide.ar.md)

> Basitleştirilmiş Çince kılavuz Feishu'da barındırılmaktadır (yukarıdaki bağlantı). İngilizce kılavuz ayrıca [GitHub'da](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md) mevcuttur.

## Giriş

Bu, Android / Windows için ücretsiz bir yazılımdır (iOS / macOS planlanıyor) — roman okumayı, sesli kitap oynatmayı, video oynatmayı ve sözlükte arama yapmayı bir araya getiren, çığır açan, çok platformlu bir açık kaynak uygulamadır.

### Proje URL'si

https://github.com/hajisensai/hibiki

Aktif olarak geliştiriliyor — geri bildirimleriniz hızla ele alınacaktır. Hata raporları ve özellik istekleri memnuniyetle karşılanır. Hibiki'yi faydalı bulursanız, başkalarıyla paylaşmanız ya da depoya bir ⭐ bırakmanız bizi mutlu eder.

### İndir

https://github.com/hajisensai/hibiki/releases/latest

Android: **arm64** seçin. Windows: **.exe** dosyasını seçin.

## Yapılandırma Eğitimi

### 1. Önerilen sözlükleri ve yerel sesi içe aktarma (isteğe bağlı)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

Uygulamada: Ayarlar -> Eşitleme ve Yedekleme -> **Yedeği İçe Aktar** öğesine dokunun.

**Not: Bir yedeği içe aktarmak yerel verileri siler. Bu akış gelecekteki bir güncellemede iyileştirilecektir.**

![Yedeği içe aktarma ekranı](static-assets/user-guide/import-backup.png)

### 2. Anki'yi resmi Anki web sitesinden indirip yapılandırma

Anki — adını 暗記 (あんき) sözcüğünden alır — dünyada en yaygın kullanılan [aralıklı tekrar sistemidir (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) ve çok önemli bir araçtır.

Bağlantılar: [Anki resmi sitesi](https://apps.ankiweb.net/) · [Kılavuz (Çince)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [SSS](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Çince)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Görsel: çizim / açıklama]*

Ezberlemek istediğiniz her materyali Anki'ye verebilirsiniz; en az çalışma süresiyle en iyi kalıcılığı elde etmenizi sağlar.

Anki, dünyanın en iyi aralıklı tekrar algoritmalarından biri olan [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) ile birlikte gelir.

**ANCAK!!!** Anki'nin varsayılan algoritması, 30 yıldan eski ve performansı zayıf bir algoritma olan SM2'dir. Anki'nin kullandığı algoritmayı mutlaka **FSRS** olarak değiştirin.

#### Anki

##### Android

1. Anki'yi yükleyip açın.
2. hibiki'ye dönün, Ayarlar -> Kart Oluşturma bölümüne gidin.
3. **Desteleri ve not türlerini yenile** öğesine dokunun (görselde "1" ile işaretli); hibiki izin isteyecektir — İzin Ver'e dokunun.
4. **Lapis destesi oluştur** öğesine dokunun (görselde "2" ile işaretli).
5. Kırmızı bir uyarı veya hata yoksa kurulum başarılı olmuştur.

![Android'de Anki kurulumu](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Anki'yi yükleyip açın.
2. Sol üstteki **Araçlar (Tools)** öğesine tıklayın.

![Windows'ta Anki Araçlar menüsü](static-assets/user-guide/anki-windows-tools-menu.png)

3. Yüklemek için aşağıdaki Anki eklenti kodunu yapıştırın: `2055492159`
4. hibiki'ye dönün, Ayarlar -> Kart Oluşturma bölümüne gidin.
5. **Desteleri ve not türlerini yenile** öğesine dokunun ("1" ile işaretli).
6. **Lapis destesi oluştur** öğesine dokunun ("2" ile işaretli).
7. Kırmızı bir uyarı veya hata yoksa kurulum başarılı olmuştur.

![Windows'ta Anki kurulumu](static-assets/user-guide/anki-windows-setup.png)

### 3. Ayarlardaki yapılandırma seçeneklerini gözden geçirin ve değiştirmek istediğiniz bir şey olup olmadığına bakın. (İsteğe bağlı)

## Teşekkürler

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
