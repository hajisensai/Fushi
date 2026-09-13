<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="Fushi logosu" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | **Türkçe** | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![En son sürümü indir](https://img.shields.io/badge/%E2%AC%87%20En%20son%20s%C3%BCr%C3%BCm%C3%BC%20indir-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Discord'a katıl](https://img.shields.io/badge/Discord%27a%20kat%C4%B1l-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Platform Desteği

| Platform | Durum | Oluşturma / Arayüz |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Material Design 3 |

> En az Android 7.0 (API 24). Aramada kullanılabilen diller, arayüz dilinden bağımsız olarak içe aktarılan sözlükler ve Yomitan dönüşüm tabloları tarafından belirlenir. iOS sürümü TestFlight üzerinden dağıtılır: App Store yönergelerinin izin vermediği keşif ve indirme özelliklerini içermez ve güncellemeleri diğer platformlardan birkaç gün sonra gelir.

### Arayüz Dilleri (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Kurulum & Derleme

Tek komutla hazırlık (`flutter pub get` + yamaları uygula), ardından derleyin:

```bash
# Depo kök dizininden
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
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
| Platformlar | Android / Windows / macOS / iOS (Material Design 3) |
| Reader | WebView sayfalama motoru (Hoshi Reader ailesinden türetilmiştir) |
| Video | media_kit (libmpv çekirdeği) |
| Depolama | Drift (SQLite, WAL) + fushidicts (C++ FFI sözlük motoru) |
| NLP | Yomitan dönüşüm tabloları (çok dilli kök bulma) + kana_kit (kana dönüşümü); belirteçleme fushidicts FFI üzerinden |
| Kart Oluşturma | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 dil) |

</details>

<details>
<summary><b>Proje Yapısı</b></summary>

```
Fushi/                      # Depo kök dizini (Melos çalışma alanı: fushi_workspace)
├── fushi/                  # Flutter uygulamasının ana dizini
│   ├── lib/
│   │   ├── i18n/            # Uluslararasılaştırma (17 dil, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Sayfalar (kitaplık, okuyucu, sözlük, ayarlar vb.)
│   │   │   ├── reader/      # Okuyucu WebView JS/CSS betikleri
│   │   │   ├── media/       # Sesli kitap, altyazı ayrıştırma, okuyucu kaynağı
│   │   │   └── models/      # Veri modelleri ve durum yönetimi (AppModel)
│   │   └── main.dart
│   └── android/             # Android projesi (manifest, yerel fushidicts)
├── packages/                # Dahili paketler + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # fushidicts C++ sözlük motoru (FFI)
├── third_party/             # Gömülü yamalı paketler (dependency_overrides)
├── ci/                      # Derleme yamaları ve entegrasyon testi betikleri
├── tool/                    # bootstrap / i18n_sync ve diğer betikler
└── docs/                    # Geliştirme belgeleri (docs/agent/ işletim kılavuzu dahil)
```

</details>

## Gizlilik & Veri

Fushi, içe aktarılan kitapları, sözlükleri, yazı tiplerini, sesli kitap verilerini, videoları, okuma ilerlemesini, vurguları, istatistikleri ve ayarları uygulamanın yerel deposunda saklar.

Bulut eşitleme (Google Drive / OneDrive / Dropbox), kullanıcı tarafından yapılandırılan OAuth kimlik bilgilerini kullanır; WebDAV / FTP / SFTP, kullanıcı tarafından sağlanan sunucu adreslerini ve kimlik bilgilerini kullanır; Fushi Interconnect, kullanıcı tarafından yapılandırılan bir adres üzerinden doğrudan bağlanır. Anki kartı oluşturma, AnkiDroid ile veya yapılandırılmış bir AnkiConnect adresiyle iletişim kurar.

## Teşekkürler

Fushi aşağıdaki projeler ve ekosistem üzerine kuruludur:

### Öğrenme araçları ve önceki projeler

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
| [Niratan](https://github.com/W1ght/Niratan) | macOS için sürükleyici dil öğrenme paketi |

### Motorlar ve yerel bileşenler

| Proje | Açıklama |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Galgame metin hook motoru (paketlenmiş DLL'ler, injector tarafından yüklenir) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Galgame injector'ının kullandığı inline hook kütüphanesi |
| [libtorrent](https://github.com/arvidn/libtorrent) | Dahili torrent indirme motoru |
| [mpv](https://github.com/mpv-player/mpv) | media_kit'in arkasındaki libmpv oynatma çekirdeği |
| [FFmpeg](https://ffmpeg.org) | Medya inceleme, kırpma ve ses çıkarma |
| [libplacebo](https://github.com/haasn/libplacebo) | GPU video gölgelendiricileri ve HDR ton eşleme |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | EPUB okuyucuyu çizen WebView motoru |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Konuşma tanıma ve OCR için cihaz üstü çıkarım |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Sözlük motoru bağımlılıkları |

### Cihaz üstü modeller

| Proje | Açıklama |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer konuşma tanıma model paketleri ve VAD derlemeleri |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Japonca konuşma tanıma modeli |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Çok dilli CTC konuşma tanıma modeli |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Ses etkinliği algılama modeli |
| [manga-ocr](https://github.com/kha-white/manga-ocr) / [manga-ocr-onnx](https://huggingface.co/mayocream/manga-ocr-onnx) | Manga OCR modeli |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Manga metni ve konuşma balonu algılama modeli |

### İçerik kaynakları ve entegrasyonlar

| Proje | Açıklama |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Manga kaynak eklentisi ekosistemi |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Masaüstü için manga eklenti çalışma zamanı |
| [aidoku-rs](https://github.com/Aidoku/aidoku-rs) | Manga kaynak çalışma zamanı ABI'si |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Tarayıcı eklentisi için akış altyazı köprüsü referansı |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Anime tanımlama ve kazıma mimarisi referansı |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Galgame kitaplığı bilgi mimarisi referansı |
| [AniDB](https://anidb.net) | Anime, bölüm ve dosya kimliği |
| [TMDB](https://www.themoviedb.org) | Tamamlayıcı meta veriler ve görseller |
| [Jimaku](https://jimaku.cc) | Japonca altyazı kaynağı |
| [OpenSubtitles](https://www.opensubtitles.com) | Altyazı kaynağı |

> Bu uygulama TMDB ve TMDB API'lerini kullanır ancak TMDB tarafından onaylanmamış, sertifikalandırılmamış veya başka şekilde desteklenmemiştir.

## Lisans

GNU General Public License v3.0 altında dağıtılır. Ayrıntılar için bkz. [LICENSE](../../LICENSE).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | **Türkçe** | [العربية](README.ar.md)

</div>
