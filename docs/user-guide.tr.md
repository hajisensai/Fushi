# Yui Hirasawa'nın bile 5 dakikada kurabildiği Fushi kılavuzu

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | **Türkçe** | [العربية](user-guide.ar.md)

> Basitleştirilmiş Çince kılavuz Feishu'da barındırılmaktadır (yukarıdaki bağlantı). İngilizce kılavuz ayrıca [GitHub'da](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md) mevcuttur.

## Giriş

**Fushi — soluksuz okumayı ve izlemeyi dil girdisine dönüştürün.**

Roman okurken, anime izlerken veya sesli kitap dinlerken herhangi bir kelimeye dokunarak anlamına bakın; yeni kelimeleri geçtikleri cümleyle birlikte Anki'ye gönderin.

Hazır kelime listeleri yok — yalnızca gerçekten karşılaştığınız kelimeleri tekrar edersiniz. Her dille çalışır.

- 📖 EPUB okuma · dokunarak arama
- 🎧 Cümle cümle vurgulamalı sesli kitaplar
- 🎬 Video altyazılarında arama ve kart oluşturma
- 🃏 Tek dokunuşla Anki kartı oluşturma + tekrar istatistikleri
- 📚 Manga okuma · OCR ile kelimeleri doğrudan sayfadan arayın
- ⬇️ Uygulama içinde tek dokunuşla anime ve manga indirme — otomatik olarak kitaplığınıza eklenir ve indirme sürerken bile oynatılabilir
- 🎮 Galgame ses madenciliği (Windows) · özgün seslendirme, metinle birlikte karta eklenir

Platformlar: Android / Windows / macOS / iOS (Linux kaynaktan derlenebilir; henüz hazır paket yok)

### Proje URL'si

https://github.com/hajisensai/Fushi

Aktif olarak geliştiriliyor — geri bildirimleriniz hızla ele alınacaktır. Hata raporları ve özellik istekleri memnuniyetle karşılanır. Fushi'yi faydalı bulursanız, başkalarıyla paylaşmanız ya da depoya bir ⭐ bırakmanız bizi mutlu eder.

### İndir

https://github.com/hajisensai/Fushi/releases/latest

Platformunuza uyan dosyayı seçin: **Android** — `arm64-v8a` APK'si (son birkaç yılın tüm telefonları bunu kullanır; yalnızca daha eski cihazlar `armeabi-v7a` gerektirir, emülatörler ise `x86_64` kullanır); **Windows** — `windows-setup.exe`; **macOS** — `macos.zip`; **iOS** — `ios.ipa`. **Linux** için henüz hazır bir paket yok, bu yüzden kaynaktan derlenmesi gerekiyor.

Adı `bridge-` ile başlayan APK'ler **eski Hibiki kullanıcıları** için geçiş köprüleridir; bunları yok sayabilirsiniz.

## Yapılandırma Eğitimi

### 1. Önerilen sözlükleri (kelime + vurgu + sıklık sözlükleri) ve yerel sesi (Japonca ve İngilizce ses veritabanları) içe aktarma (Yeni başlayanlara şiddetle önerilir!!! · isteğe bağlı)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Cloudflare üzerinden indirme (9,5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

Uygulamada: Ayarlar -> Eşitleme ve Yedekleme -> **Yedeği İçe Aktar** öğesine dokunun.

![Yedeği içe aktarma ekranı](static-assets/user-guide/import-backup.png)

### 2. Anki'yi resmi Anki web sitesinden indirip yapılandırma

Anki — adını 暗記 (あんき) sözcüğünden alır — dünyada en yaygın kullanılan [aralıklı tekrar sistemidir (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) ve çok önemli bir araçtır.

Bağlantılar: [Anki resmi sitesi](https://apps.ankiweb.net/) · [Kılavuz (Çince)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [SSS](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Çince)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Anki indirme sayfası](static-assets/user-guide/anki-download.png)

Ezberlemek istediğiniz her materyali Anki'ye verebilirsiniz; en az çalışma süresiyle en iyi kalıcılığı elde etmenizi sağlar.

Anki, dünyanın en iyi aralıklı tekrar algoritmalarından biri olan [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) ile birlikte gelir.

**ANCAK!!!** Anki'nin varsayılan algoritması, 30 yıldan eski ve performansı zayıf bir algoritma olan SM2'dir. Anki'nin kullandığı algoritmayı mutlaka **FSRS** olarak değiştirin.

#### Anki

##### Android

1. Anki'yi yükleyip açın.
2. Fushi'ye dönün, Ayarlar -> Kart Oluşturma bölümüne gidin.
3. **Desteleri ve not türlerini yenile** öğesine dokunun (görselde "1" ile işaretli); Fushi izin isteyecektir — İzin Ver'e dokunun.
4. **Lapis destesi oluştur** öğesine dokunun (görselde "2" ile işaretli).
5. Kırmızı bir uyarı veya hata yoksa kurulum başarılı olmuştur.

![Android'de Anki kurulumu](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Anki'yi yükleyip açın.
2. Sol üstteki **Araçlar (Tools)** öğesine tıklayın.

![Windows'ta Anki Araçlar menüsü](static-assets/user-guide/anki-windows-tools-menu.png)

3. Yüklemek için aşağıdaki Anki eklenti kodunu yapıştırın: `2055492159`
4. Fushi'ye dönün, Ayarlar -> Kart Oluşturma bölümüne gidin.
5. **Desteleri ve not türlerini yenile** öğesine dokunun ("1" ile işaretli).
6. **Lapis destesi oluştur** öğesine dokunun ("2" ile işaretli).
7. Kırmızı bir uyarı veya hata yoksa kurulum başarılı olmuştur.

![Windows'ta Anki kurulumu](static-assets/user-guide/anki-windows-setup.png)

### 3. Ayarlardaki yapılandırma seçeneklerini gözden geçirin ve değiştirmek istediğiniz bir şey olup olmadığına bakın. (İsteğe bağlı)

Artık dile dalma zamanı.

## Önerilen Özellikler

### Uygulama dışında kelime arama

**Android:** bir kelimeyi seçin, ardından seçim menüsünde **Çevir** veya **Fushi** öğesine dokunun.

**Windows:** bir kelimeyi seçin, ardından **Ctrl+Alt+D** tuşlarına basın (kısayol, Ayarlar -> Kısayollar bölümünden değiştirilebilir).

### Panodan arama

Kopyaladığınız her şey otomatik olarak aranır. İki gösterim biçimi vardır — **kayan panel** ve **saydam metin penceresi** — ikisi de Ayarlar -> Arama bölümünden yapılandırılabilir.

### Tarayıcıda arama / yayın platformu altyazılarından kart oluşturma (Netflix)

Tarayıcı uzantısını Fushi ana sayfasından yükleyin.

## Teşekkürler

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
