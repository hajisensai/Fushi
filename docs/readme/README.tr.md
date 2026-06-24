<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Bir kitap oku, her yeni kelimeyi kendine ait kıl.</b></p>
<p align="center">Çok platformlu, çok dilli sürükleyici okuyucu —— EPUB okuma · Dokunarak arama · Anki kartı oluşturma · Sesli kitap senkronizasyonu · Video altyazısında arama</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  &nbsp;·&nbsp;
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Proje sitesi (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <b>Türkçe</b> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Tanıtım

**hibiki**, dil öğrenimi için çok platformlu sürükleyici bir okuyucudur. Bir EPUB metninde **dokunarak sözlükte arayabilir, seçerek analiz edebilir** ve her yeni kelimeyi tek dokunuşla bir Anki kartına dönüştürebilirsin; sesli kitap sesini metinle cümle cümle senkronize vurgular; hatta video altyazılarında doğrudan arama yapıp kart oluşturursun. «Okuma · dinleme · izleme» olmak üzere üç sürükleyici girdi biçimini tek bir araçta toplar.

Sözlük arama, [Yomitan](https://github.com/yomidevs/yomitan)'ın **tüm dönüşüm dillerini** kapsar (çekim çözümleme + aramadan önce metin normalleştirme), arayüz **17 dile** yerelleştirilmiştir ve **Android / iOS / macOS / Windows / Linux** olmak üzere beş platformu destekler.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Kitaplık" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Arama" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Ayarlar ve temalar" width="300">
</p>
<p align="center"><sub>Kitaplık · Arama · Ayarlar ve temalar</sub></p>

---

## Temel özellikler

### 📖 EPUB okuma, dokunarak arama

WebView'de oluşturulan EPUB okuyucu ([Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) türevi sayfalama motoru): herhangi bir kelimeye dokunarak anında arayın, bir metin parçası seçerek anında analiz edin. Sürekli kaydırma ve sayfalama çift modu, özel yazı tipleri ve temalar (açık / koyu / saf siyah / özel), furigana, okuma istatistikleri ve yer imleri dahildir.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Dikey okuma · Furigana · Sesli kitap senkronizasyonu" width="300">
</p>
<p align="center"><sub>Dikey metin · Furigana · Seçim vurgusu · Altta sesli kitap kontrol çubuğu</sub></p>

### 🔍 Dokunarak arama, Yomitan'ın tüm dönüşüm dillerini kapsar

Birden çok biçimde sözlük içe aktarın: **Yomitan** (eski adı Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Çok dilli kök çözümleme (Yomitan dönüşüm tabloları) + aramadan önce metin normalleştirme (büyük/küçük harf / aksan işaretleri / Arapça harakat), kod noktalarıyla yürütülür ve dil değiştirmeye gerek yoktur. Birden çok sözlükte paralel arama, alt kaynak önceliği ve açma/kapama, ton vurgusu açıklaması ve kelime frekansı, hepsi tek bir açılır pencerede.

### 🎴 Tek dokunuşla Anki kartı oluşturma

Yeni bir kelime bulduğunda, tek adımda [AnkiDroid](https://github.com/ankidroid/Anki-Android) ve AnkiConnect'e dışa aktar. Yerleşik [Lapis](https://github.com/donkuri/lapis) not türü şeması (vendored 1.7.0): kart şablonlarını ve desteleri doğrudan uygulamada oluşturabilirsin; bağlam cümlelerinin otomatik doldurulması, ses kaydı ve ekran görüntüsü kırpma desteği, çoklu dışa aktarma yapılandırmaları (Profile), özel alan eşleştirme ve tek adımda kart oluşturmak için hızlı eylemler.

### 🎧 Sesli kitap senkronizasyonu (Sasayaki)

SRT / LRC / VTT / ASS altyazılarını destekler ve altyazı metnini otomatik olarak EPUB içeriğiyle hizalar. Oynatma sırasında **metni okumaya eşlik ederek vurgular ve sesle senkronize sayfa çevirir**, oynatma kontrol çubuğuyla birlikte (ilerleme, atlama, hız): dinlerken metin cümle cümle aydınlanır —— bu sayfanın üstündeki okuma ekran görüntüsünün altındaki kontrol çubuğu tam olarak bu işlevdir.

### 🎬 Video altyazısında arama

media_kit / libmpv tabanlı yerleşik video oynatıcı, gömülü / harici altyazıları destekler. Bir video oynatırken **doğrudan altyazılarda arama yapıp kart oluşturabilirsin**, görsel-işitsel materyali de sürükleyici girdilere dahil edersin; aynı zamanda izleme süresini ve oluşturulan kart sayısını kaydeder.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Video oynatıcı ekran görüntüsü eklenecek.</sub></p>

### 🔗 Daha fazlası

- **17 arayüz dili**, tüm platformlarda yerelleştirme
- **Hibiki Interconnect**: cihazlar arasında kitap / sözlük / sesli kitap / okuma ilerlemesi senkronizasyonu
- **Çoklu kullanıcı profili (Profile)**, kitaba göre otomatik geçiş
- **Gizli mod**; **doğrudan arama için diğer uygulamalardan metin paylaşımı**

---

## Desteklenen platformlar

| Platform | Durum | Oluşturma / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (`flutter_inappwebview_windows` fork'u ile EPUB oluşturma) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Minimum Android 7.0 (API 24). Sözlük arama dili, içe aktarılan sözlükler ve Yomitan dönüşüm tabloları tarafından belirlenir ve arayüz dilinden bağımsızdır.

### Arayüz dilleri (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Kurulum ve derleme

Tek komutla hazırlık (`flutter pub get` + yama uygulama), ardından derleyin:

```bash
# depo kök dizininde
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` tek komutta ① `flutter pub get` ve ② `ci/apply-patches.sh` işlemlerini toplar. Bu proje Flutter 3.44.0'ya (Dart SDK `>=3.5.0 <4.0.0`) kilitlenmiştir; bazı upstream bağımlılıkları `third_party/` altına vendored edilmiş veya `ci/apply-patches.sh` tarafından yamanmıştır —— mekanizma ayrıntıları, beş platformda derleme ve bağımlılık/yama listesi için [docs/agent/build.md](../agent/build.md) bölümüne bakın.

<details>
<summary><b>Teknoloji yığını özeti</b></summary>

| Katman | Teknoloji |
|---|---|
| Çerçeve | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platform | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino uyarlanabilir) |
| Okuyucu | WebView sayfalama motoru ([Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) türevi) |
| Video | media_kit / libmpv |
| Depolama | Drift (SQLite, WAL) + hoshidicts (C++ FFI sözlük motoru) |
| NLP | Yomitan dönüşüm tabloları (çok dilli kök çözümleme) + kana_kit (kana dönüşümü); tokenizasyon hoshidicts FFI üzerinden yürür |
| Kart oluşturma | AnkiDroid API + AnkiConnect |
| Uluslararasılaştırma | Slang (17 dil) |

</details>

<details>
<summary><b>Proje yapısı</b></summary>

```
hibiki/                      # Depo kökü (Melos workspace: hibiki_workspace)
├── hibiki/                  # Flutter uygulama ana dizini
│   ├── lib/
│   │   ├── i18n/            # Uluslararasılaştırma (17 dil, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Sayfalar (kitaplık, okuyucu, sözlük, ayarlar vb.)
│   │   │   ├── reader/      # Okuyucu WebView JS/CSS betikleri
│   │   │   ├── media/       # Sesli kitaplar, altyazı ayrıştırma, reader source
│   │   │   └── models/      # Veri modelleri ve durum yönetimi (AppModel)
│   │   └── main.dart
│   └── android/             # Android projesi (manifest, native hoshidicts)
├── packages/                # Dahili package'lar + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── native/                  # hoshidicts C++ sözlük motoru (FFI)
├── third_party/             # vendored yama paketleri (dependency_overrides ile gösterilir)
├── ci/                      # Derleme yaması ve entegrasyon testi betikleri
├── tool/                    # bootstrap / i18n_sync vb. betikler
└── docs/                    # Geliştirme dokümantasyonu (docs/agent/ agent el kitabı dahil)
```

</details>

---

## Teşekkürler

| Proje | Açıklama |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japonca sürükleyici öğrenme aracı |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android Japonca okuyucu |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ sözlük motoru |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japonca okuyucu |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Sesli kitap senkronizasyon şeması |
| [Yomitan](https://github.com/yomidevs/yomitan) | Sözlük biçimi ve dönüşüm tabloları kaynağı |
| [Lapis](https://github.com/donkuri/lapis) | Anki not türü |

## Lisans

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <b>Türkçe</b> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
