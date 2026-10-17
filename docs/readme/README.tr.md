<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="Fushi logosu" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | **Türkçe** | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![En son sürümü indir](https://img.shields.io/badge/%E2%AC%87%20En%20son%20s%C3%BCr%C3%BCm%C3%BC%20indir-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Discord'a katıl](https://img.shields.io/badge/Discord%27a%20kat%C4%B1l-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Platform Desteği

| Platform | Durum | Notlar |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) veya üzeri |
| Windows | ✅ | Galgame metin ve ses hook'lama yalnızca Windows'ta çalışır |
| macOS | ✅ | Yalnızca Apple Silicon; Intel Mac'ler desteklenmez |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Keşif, çevrimiçi kaynaklar ve indirme merkezi yok (App Store yönergeleri) |
| Linux | 🔧 Kaynaktan derleyin | Henüz hazır sürüm yok; EPUB okuyucu WPE WebKit gerektirir |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Linux / Windows / macOS için web arayüzlü başsız (headless) sunucu — bkz. [packages/fushi_server](../../packages/fushi_server/README.md) |

**Tasarım sistemi** — her platformda varsayılan **Material 3 Expressive**'dir; *Ayarlar › Görünüm › Tasarım sistemi* bölümünden bir **Cupertino** (Apple tarzı) tasarım sistemi seçilebilir; Cupertino ile pencere arka planı Windows 11'de Mica, macOS'ta vibrancy kullanır (sistemin saydamlığı azalt veya yüksek karşıtlık ayarı açık değilse).

> Aramada kullanılabilen diller, arayüz dilinden bağımsız olarak içe aktarılan sözlükler ve Yomitan dönüşüm tabloları tarafından belirlenir. iOS güncellemeleri TestFlight üzerinden diğer platformlardan birkaç gün sonra gelir.

### Arayüz Dilleri (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Kurulum

En son sürümü [Fushi web sitesinden](https://fushi.moe/) indirin — Android APK, Windows yükleyicisi ve macOS sürümleri mevcuttur (yalnızca Apple Silicon; Intel Mac'ler desteklenmez); iOS, [TestFlight](https://testflight.apple.com/join/j88d69jx) üzerinden kurulur. Linux için henüz hazır bir uygulama sürümü yoktur; kaynaktan derleyin. Başsız Fushi Server ise ayrıca [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases) adresinden yayımlanır.

> Android 7.0 (API 24) veya üzeri gerekir.

## Derleme

Tek komutla hazırlık (`flutter pub get` + yamaları uygula), ardından derleyin:

```bash
# Depo kök dizininden
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Masaüstü
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Başsız sunucu (packages/fushi_server içinden; `dart compile exe` değil, `dart build cli` kullanın)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1`, `flutter pub get` ve `ci/apply-patches.sh` komutlarını tek bir komutta birleştirir. Bu proje Flutter 3.47.6 sürümüne sabitlenmiştir (Dart SDK `>=3.8.0 <4.0.0`); Material ve Cupertino `material_ui` / `cupertino_ui` paketleri olarak kullanıldığından önceki Flutter sürümleri projeyi derleyemez. Bazı üst akış bağımlılıkları `third_party/` altında gömülüdür veya `ci/apply-patches.sh` tarafından yamalanır — Linux masaüstü derleme bağımlılıkları dahil ayrıntılar için bkz. [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Teknoloji Yığını</b></summary>

| Katman | Teknoloji |
|---|---|
| Çerçeve | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Platformlar | Android / Windows / macOS / iOS / Linux, ayrıca başsız bir sunucu |
| Arayüz | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Reader | WebView sayfalama motoru (Hoshi Reader ailesinden türetilmiştir) |
| Video | media_kit (libmpv çekirdeği) + libplacebo |
| Depolama | Drift (SQLite, WAL) + fushidicts (C++ FFI sözlük motoru) |
| NLP | Yomitan dönüşüm tabloları (çok dilli kök bulma) + kana_kit (kana dönüşümü); belirteçleme fushidicts FFI üzerinden |
| Cihaz üstü yapay zekâ | Konuşma tanıma (altyazı üretimi) ve manga OCR için ONNX Runtime; algoritmalar [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) içinde yer alır |
| İndirmeler | C-ABI FFI köprüsüyle libtorrent 2.x (yedek olarak harici qBittorrent) |
| Eşitleme | Bulut arka uçları + Fushi Interconnect (LAN, uzak adresler ve bir iroh P2P tüneli) |
| Ortak motor | `fushi_engine` — uygulama ile Fushi Server'ın paylaştığı saf Dart çekirdeği |
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
│   │   │   ├── pages/       # Sayfalar (kitaplık sayfaları, okuyucu, video oynatıcı, ayarlar vb.)
│   │   │   ├── reader/      # Okuyucu WebView JS/CSS betikleri
│   │   │   ├── media/       # Kitaplar, manga, video, sesli kitaplar, çevrimiçi kaynaklar
│   │   │   ├── lookup/      # Sözlük arama açılır pencereleri ve katmanları
│   │   │   ├── mining/      # Kart oluşturma (galgame mining dahil)
│   │   │   ├── sync/        # Bulut eşitleme, Interconnect, medya sunucuları
│   │   │   └── models/      # Veri modelleri ve durum yönetimi (AppModel)
│   │   └── main.dart
│   └── android/             # Android projesi
├── packages/                # Dart paketleri
│   ├── fushi_core/          #   Veritabanı şeması, tercihler
│   ├── fushi_engine/        #   Sunucuyla paylaşılan saf Dart motoru
│   ├── fushi_server/        #   Başsız sunucu CLI + web arayüzü
│   ├── fushi_cli/           #   Masaüstü komut satırı istemcisi
│   ├── fushi_dictionary/    #   Sözlük motoru bağlamaları ve içe aktarıcılar
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # libtorrent / iroh FFI bağlamaları
│   └── …                    #   Gömülü fork'lar (inappwebview Windows/Linux, gamepads)
├── native/                  # Yerel kaynaklar: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Günlük toplayıcı ve leaderboard arka uçları (ayrı dağıtılır)
├── tools/browser-extension/ # Tarayıcı arama eklentisi
├── third_party/             # Gömülü yamalı paketler (dependency_overrides)
├── ci/                      # Derleme yamaları ve CI betikleri
├── tool/                    # bootstrap / setup_worktree / hata takip betikleri
└── docs/                    # Geliştirme belgeleri (docs/agent/ işletim kılavuzu dahil)
```

</details>

Video içe aktarma, esere veya klasöre göre gruplamayı destekler. Eşleştirme ve arka plan görevleri için [video iş akışı](../specs/2026-09-07-video-library-workflow.md) ile [AniDB dosya karması kullanan MAL/TMDB meta verileri](../specs/2026-09-07-mal-tmdb-anidb-hash.md) belgelerine bakın.

[İsteğe bağlı çevrimiçi hizmet kurulumu](../specs/2026-09-07-online-services-setup.md), paketlenmiş uygulama kimliklerini, kişisel kimlik bilgilerini ve kapatılabilir video kurulum hatırlatıcısını açıklar.

## Gizlilik & Veri

Fushi, içe aktarılan kitapları, sözlükleri, yazı tiplerini, sesli kitap verilerini, videoları, okuma ilerlemesini, vurguları, istatistikleri ve ayarları uygulamanın yerel deposunda saklar.

- **Eşitleme** — Google Drive / OneDrive / Dropbox OAuth ile oturum açmayı kullanır; WebDAV / FTP / SFTP / Fushi Server, sizin verdiğiniz sunucu adresini ve kimlik bilgilerini kullanır. Fushi Interconnect eşleştirilmiş cihazları doğrudan bağlar (LAN, IPv6, bindirme ağları veya genel adresler); doğrudan yol çalışmazsa uçtan uca bir iroh P2P tüneline geçer; eşleştirme bağlantıları her zaman onay ister.
- **Anki** — kart oluşturma, AnkiDroid ile veya yapılandırdığınız AnkiConnect adresiyle iletişim kurar.
- **Kullanım istatistikleri** — masaüstü ve Android sürümleri günde bir kez, etkin kullanıcıları saymak için fushi.moe'ye rastgele bir kurulum kimliği, uygulama sürümü, platform ve güncelleme kanalını gönderir; hesap, kitaplık veya okuma verisi dahil değildir ve IP adresleri saklanmaz. Güncelleme ayarlarındaki *Kullanım istatistiklerini paylaş* ile kapatabilirsiniz. iOS sürümleri bunu göndermez.
- **Yalnızca siz istediğinizde** — günlük yükleme (tek seferlik bir onay isteminden sonra), uygulama içi geri bildirim ve leaderboard (varsayılan olarak kapalı; kitaplık başlıklarınızı ve ilerlemenizi yalnızca siz katıldıktan sonra yükler).
- **Manga OCR** — varsayılan motor, sayfa görüntüsünü Google'a gönderen Google Lens'tir; görüntüleri yerel tutmak için ayarlardan cihaz üstü modele veya sistem OCR'ına geçin.
- **Yapay zekâ özellikleri** — istekler yalnızca sizin yapılandırdığınız ve bir özelliğe atadığınız LLM sağlayıcısına gider; atanmış sağlayıcı yoksa hiçbir şey gönderilmez.
- **Üçüncü taraf hizmetler** — meta veri, altyazı ve çevrimiçi kaynak özellikleri, [İçerik kaynakları ve entegrasyonlar](#i̇çerik-kaynakları-ve-entegrasyonlar) altında listelenen hizmetlere yalnızca onları kullandığınızda bağlanır.

## Geliştirme Etkinliği

[![Geliştirme Etkinliği](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Günlük çalışma `develop` dalına iner; `main` yalnızca sürüm birleştirmelerini alır. Grafik burada `main` üzerinde gösterilir ancak `develop` üzerinden üretilir; böylece birleştirme trafiğini değil gerçek geliştirmeyi yansıtır.

Üç şerit, uygulamanın kendisinin sunduğu güncelleme kanallarıdır ve her biri kendi zirvesine göre ölçeklenir — debug derlemeleri kararlı sürümlerden iki kat büyüklük sırası fazladır, bu yüzden ortak bir ölçek diğer iki şeridi sıfıra ezerdi.

| Şerit | Neyi sayar | Nasıl edinilir |
|---|---|---|
| **Debug (sürekli)** | [release.yml](../../.github/workflows/release.yml) dosyasının başarılı push derlemeleri | Sürekli ön sürüm, her push'ta yeniden yayımlanır |
| **Beta** | `v<version>-beta.<seq>` ön sürümleri | Elle tetiklenen test derlemesi |
| **Kararlı** | `v<version>` sürümleri | En son sürüm |

> Yukarıdaki grafik bu depo içinde üretilir (üçüncü taraf hizmet yok) ve [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml) iş akışı tarafından her gün yenilenir.

## Yıldız Geçmişi

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Yıldız Geçmişi](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> Yukarıdaki grafik bu depo içinde üretilir (üçüncü taraf hizmet yok) ve [Update Star History](../../.github/workflows/star-history.yml) iş akışı tarafından her gün yenilenir.

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
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Altyazıyı referansa göre zamanlama hizalama algoritması (GPL-3.0); indirilen altyazıları gömülü kanallara otomatik hizalamanın temeli |
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
| [iroh](https://github.com/n0-computer/iroh) | Uzak Fushi Interconnect bağlantıları için P2P tüneli |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Sözlük motoru bağımlılıkları |

### Cihaz üstü modeller

| Proje | Açıklama |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer konuşma tanıma model paketleri ve VAD derlemeleri |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Japonca konuşma tanıma modeli |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Japonca konuşma tanıma modeli |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Japonca konuşma tanıma modeli (CC BY-NC 4.0, Hugging Face deposundan indirilir) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Çok dilli CTC konuşma tanıma modeli |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Ses etkinliği algılama modeli |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Manga metni ve konuşma balonu algılama modeli |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Manga karesi algılama modeli, [Manga109-s](http://www.manga109.org/en/download_s.html) ile eğitilmiştir |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Metin satırı algılama ve tanıma; manga için ayarlanmış rec ([Manga109-s](http://www.manga109.org/en/download_s.html) ve [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText) ile eğitilmiştir) sütun başına CTC yerel OCR modelini besler |

> Manga karesi algılama modeli ve PP-OCRv6_manga, Manga109-s veri kümesiyle (Matsui et al. 2017; Aizawa et al. 2020) eğitilmiştir; veri kümesinin koşulları bu kullanımın açıkça belirtilmesini gerektirir. PP-OCRv6_manga (Apache-2.0) ayrıca CC BY-NC-SA 4.0 lisanslı AnimeText veri kümesiyle eğitilmiştir; uygulama bu modeli Hugging Face deposundan indirir ve yeniden dağıtmaz.

### İçerik kaynakları ve entegrasyonlar

| Proje | Açıklama |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Manga kaynak eklentisi ekosistemi |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Anime kaynak eklentisi ekosistemi (extensions-lib 14–16, aynı çalışma zamanı) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Masaüstü için manga eklenti çalışma zamanı (gömülü, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Mihon / Aniyomi eklenti uyarlaması referansı |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Hafif roman kaynak eklentisi ekosistemi |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Video kitaplığından gezilebilen medya sunucuları |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Tarayıcı eklentisi için akış altyazı köprüsü referansı |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Anime tanımlama ve kazıma mimarisi referansı |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Galgame kitaplığı bilgi mimarisi referansı |
| [AniDB](https://anidb.net) | Anime, bölüm ve dosya kimliği |
| [MyAnimeList](https://myanimelist.net) ([Jikan](https://jikan.moe) üzerinden) | Anime meta verileri |
| [TMDB](https://www.themoviedb.org) | Tamamlayıcı meta veriler ve görseller |
| [VNDB](https://vndb.org) | Görsel roman meta verileri |
| [Jimaku](https://jimaku.cc) | Japonca altyazı kaynağı |
| [OpenSubtitles](https://www.opensubtitles.com) | Altyazı kaynağı |

> Bu uygulama TMDB ve TMDB API'lerini kullanır ancak TMDB tarafından onaylanmamış, sertifikalandırılmamış veya başka şekilde desteklenmemiştir.

## Lisans

GNU General Public License v3.0 altında dağıtılır. Ayrıntılar için bkz. [LICENSE](../../LICENSE).

## Bakımcı

Fushi, [hajisensai](https://github.com/hajisensai) tarafından sürdürülmektedir. Web sitesi: [fushi.moe](https://fushi.moe). İletişim: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | **Türkçe** | [العربية](README.ar.md)

</div>
