<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="hibiki logosu" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | **Türkçe** | [العربية](README.ar.md)

[Kullanım Kılavuzu](../user-guide.tr.md) | [En son sürümü indir](https://github.com/hajisensai/hibiki/releases)

hibiki, Android ve Windows için EPUB okuma, sesli kitap eşitleme, video altyazılarında sözcük arama ve tek dokunuşla Anki kartı oluşturmayı bir araya getiren sürükleyici bir dil öğrenme aracıdır — böylece her girdi doğal olarak tekrar edilebilir kelime dağarcığına dönüşür.

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="Kitaplık" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="Video Kitaplığı" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="Arama açılır penceresiyle masaüstünde dikey okuma" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="Videoda arama (iç içe açılır pencereler)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="Videoda arama (altyazı listesi)" width="100%"></td>
  </tr>
</table>

</div>

## Özellikler

### Kitaplık

- EPUB'ları tek tek, toplu olarak veya klasöre göre özyinelemeli içe aktarın; okuma ilerlemesini doğrudan raftan görün.
- Kitapları özel kitaplıklar, etiket filtreleme ve yeniden sıralamak için sürükleme ile düzenleyin.
- Kitap, altyazı veya video içe aktarmak için dosyaları sürükleyip bırakın (masaüstü).
- İçe aktarırken aynı adlı altyazı / ses dosyalarını otomatik olarak ilişkilendirin.

### Okuma

- Dikey veya yatay düzende okuyun; sayfalı ve sürekli kaydırma modları arasında geçiş yapın.
- Temaları (açık / koyu / saf siyah / özel), yazı tiplerini, paragraf aralığını ve okuyucu denetimlerini özelleştirin.
- Furigana (ふりがな) ek açıklamaları.
- Ayarlanabilir arayüz ölçeği; alt çubuk denetimleri ölçeği izler.
- Çok kullanıcılı profiller (Profile), her kitap için otomatik geçiş.

### Arama

- [Yomitan](https://github.com/yomidevs/yomitan) (eski adıyla Yomichan), ABBYY Lingvo (DSL), MDict (MDX) ve Migaku sözlüklerini içe aktarın.
- Sözcükleri aramak için okuyucudaki metne dokunun, sözlük sayfasında arayın veya diğer uygulamalardan metin paylaşın.
- **Tüm Yomitan dönüşüm dilleri** için çekim çözümleme + arama öncesi metin normalleştirme (büyük/küçük harf / aksan işaretleri / Arapça hareke), dil değiştirmeden kod noktalarıyla çalışır.
- Özyinelemeli arama için tanımların içindeki sözcüklere dokunun (iç içe açılır pencereler).
- Paralel çoklu sözlük sorguları, alt kaynak önceliği ve açma/kapatma, ton vurgusu ve sıklık ek açıklamaları.
- Çevrimiçi ve yerel sözcük sesi.
- Özel CSS enjekte edin.

### Vurgular & İstatistikler

- Okurken beş renkli vurgular ekleyin; istediğiniz zaman herhangi bir vurguya atlayın.
- Okuma istatistikleri: okunan karakter sayısı, süre, okuma hızı — okurken gerçek zamanlı olarak gösterilir.
- Video istatistikleri: izleme süresi, oluşturulan kartlar ve favoriler.

### Anki Kartı Oluşturma

- [AnkiDroid](https://github.com/ankidroid/Anki-Android) veya AnkiConnect aracılığıyla kart oluşturun.
- Yerleşik [Lapis](https://github.com/donkuri/lapis) not türü (gömülü 1.7.0); kart şablonlarını ve desteleri uygulama içinde tek dokunuşla oluşturun.
- Bağlam cümlelerini otomatik doldurun; ses kaydı ve ekran görüntüsü kırpma.
- Birden çok dışa aktarma profili (Profile) ve özel alan eşleme.
- Sözcükleri favorilere ekleyin; oluşturulan kartlar ve favoriler istatistiklere dahil edilir.

### Sesli Kitap Eşitleme (Sasayaki)

- SRT / LRC / VTT / ASS altyazı desteği; altyazı metnini otomatik olarak EPUB gövdesiyle hizalar.
- Oynatma sırasında takip eden cümle vurgulama ve otomatik sayfa çevirme.
- Oynatma hızı, atlama işlemleri ve sistem medya denetimleri.
- Sorunsuz bölümler arası devamla „bu cümleden oynat”.

### Video Altyazısında Arama

- [media_kit](https://github.com/media-kit/media-kit) (libmpv çekirdeği) tabanlı yerleşik video oynatıcı.
- Gömülü (metin + grafik izler) ve harici altyazılar; .m3u8 oynatma listesi içe aktarma.
- Oynatma sırasında doğrudan altyazılardan sözcük arayın ve kart oluşturun.
- Video kitaplığı yönetimi, etiket filtreleme, dizi gruplama ve toplu işlemler.

### Veri Eşitleme

- Yedi eşitleme arka ucu: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP ve Hibiki P2P.
- Okuma ilerlemesini, istatistikleri ve kitapları eşitleyin.

### Daha Fazlası

- **17 arayüz dili**, tüm platformlarda tamamen yerelleştirilmiş.
- Sözcükleri doğrudan aramak için diğer uygulamalardan metin paylaşın.

## Platform Desteği

| Platform | Durum | Oluşturma / Arayüz |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> En az Android 7.0 (API 24). Aramada kullanılabilen diller, arayüz dilinden bağımsız olarak içe aktarılan sözlükler ve Yomitan dönüşüm tabloları tarafından belirlenir.

### Arayüz Dilleri (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Kurulum & Derleme

Tek komutla hazırlık (`flutter pub get` + yamaları uygula), ardından derleyin:

```bash
# Depo kök dizininden
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows masaüstü
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1`, `flutter pub get` ve `ci/apply-patches.sh` komutlarını tek bir komutta birleştirir. Bu proje Flutter 3.44.0 sürümüne sabitlenmiştir (Dart SDK `>=3.5.0 <4.0.0`); bazı üst akış bağımlılıkları `third_party/` altında gömülüdür veya `ci/apply-patches.sh` tarafından yamalanır — ayrıntılar için bkz. [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Teknoloji Yığını</b></summary>

| Katman | Teknoloji |
|---|---|
| Çerçeve | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platformlar | Android / Windows (Material Design 3) |
| Reader | WebView sayfalama motoru (Hoshi Reader ailesinden türetilmiştir) |
| Video | media_kit (libmpv çekirdeği) |
| Depolama | Drift (SQLite, WAL) + hoshidicts (C++ FFI sözlük motoru) |
| NLP | Yomitan dönüşüm tabloları (çok dilli kök bulma) + kana_kit (kana dönüşümü); belirteçleme hoshidicts FFI üzerinden |
| Kart Oluşturma | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 dil) |

</details>

<details>
<summary><b>Proje Yapısı</b></summary>

```
hibiki/                      # Depo kök dizini (Melos çalışma alanı: hibiki_workspace)
├── hibiki/                  # Flutter uygulamasının ana dizini
│   ├── lib/
│   │   ├── i18n/            # Uluslararasılaştırma (17 dil, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Sayfalar (kitaplık, okuyucu, sözlük, ayarlar vb.)
│   │   │   ├── reader/      # Okuyucu WebView JS/CSS betikleri
│   │   │   ├── media/       # Sesli kitap, altyazı ayrıştırma, okuyucu kaynağı
│   │   │   └── models/      # Veri modelleri ve durum yönetimi (AppModel)
│   │   └── main.dart
│   └── android/             # Android projesi (manifest, yerel hoshidicts)
├── packages/                # Dahili paketler + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # hoshidicts C++ sözlük motoru (FFI)
├── third_party/             # Gömülü yamalı paketler (dependency_overrides)
├── ci/                      # Derleme yamaları ve entegrasyon testi betikleri
├── tool/                    # bootstrap / i18n_sync ve diğer betikler
└── docs/                    # Geliştirme belgeleri (docs/agent/ işletim kılavuzu dahil)
```

</details>

## Gizlilik & Veri

hibiki, içe aktarılan kitapları, sözlükleri, yazı tiplerini, sesli kitap verilerini, videoları, okuma ilerlemesini, vurguları, istatistikleri ve ayarları uygulamanın yerel deposunda saklar.

Bulut eşitleme (Google Drive / OneDrive / Dropbox), kullanıcı tarafından yapılandırılan OAuth kimlik bilgilerini kullanır; WebDAV / FTP / SFTP, kullanıcı tarafından sağlanan sunucu adreslerini ve kimlik bilgilerini kullanır; Hibiki P2P, kullanıcı tarafından yapılandırılan bir adres üzerinden doğrudan bağlanır. Anki kartı oluşturma, AnkiDroid ile veya yapılandırılmış bir AnkiConnect adresiyle iletişim kurar.

## Teşekkürler

hibiki aşağıdaki projeler ve ekosistem üzerine kuruludur:

| Proje | Açıklama |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japonca sürükleyici öğrenme aracı |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japonca okuyucu; okuyucu sayfalama motoru referansı |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android yerel Japonca okuyucu |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ sözlük motoru |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Sesli kitap eşitleme çözümü |
| [Yomitan](https://github.com/yomidevs/yomitan) | Sözlük biçimi, dönüşüm tabloları ve arama deneyimi referansı |
| [Lapis](https://github.com/donkuri/lapis) | Anki not türü |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android kart oluşturma entegrasyonu |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Yerel ses ve AnkiDroid etkileşimi referansı |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Okuyucu, istatistik ve eşitleme uyumluluğu referansı |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter video oynatma çerçevesi (libmpv çekirdeği) |

## Lisans

GNU General Public License v3.0 altında dağıtılır. Ayrıntılar için bkz. [LICENSE](../../LICENSE).

<div align="center">

<br>

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | **Türkçe** | [العربية](README.ar.md)

</div>
