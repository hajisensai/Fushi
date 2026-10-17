<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | **Bahasa Indonesia** | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Unduh versi terbaru](https://img.shields.io/badge/%E2%AC%87%20Unduh%20versi%20terbaru-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Gabung Discord](https://img.shields.io/badge/Gabung%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Dukungan Platform

| Platform | Status | Catatan |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) atau lebih baru |
| Windows | ✅ | Hooking teks dan suara galgame hanya untuk Windows |
| macOS | ✅ | Hanya Apple Silicon; Mac Intel tidak didukung |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Tanpa penemuan, sumber daring, atau pusat unduhan (pedoman App Store) |
| Linux | 🔧 Bangun dari sumber | Belum ada rilis siap pakai; pembaca EPUB membutuhkan WPE WebKit |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Host headless untuk Linux / Windows / macOS dengan antarmuka web — lihat [packages/fushi_server](../../packages/fushi_server/README.md) |

**Sistem desain** — setiap platform secara default memakai **Material 3 Expressive**; sistem desain **Cupertino** (gaya Apple) dapat dipilih di *Pengaturan › Tampilan › Sistem Desain*; dengan Cupertino, latar jendela memakai Mica di Windows 11 dan vibrancy di macOS (kecuali pengaturan kurangi transparansi atau kontras tinggi sistem aktif).

> Bahasa yang tersedia untuk pencarian kamus ditentukan oleh kamus yang diimpor dan tabel transformasi Yomitan, terlepas dari bahasa antarmuka. Pembaruan iOS datang lewat TestFlight beberapa hari lebih lambat dari platform lain.

### Bahasa Antarmuka (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Instalasi

Unduh rilis terbaru dari [situs web Fushi](https://fushi.moe/) — tersedia APK Android, installer Windows, dan build macOS (hanya Apple Silicon; Mac Intel tidak didukung); iOS dipasang lewat [TestFlight](https://testflight.apple.com/join/j88d69jx). Linux belum memiliki rilis aplikasi siap pakai; bangun dari sumber. Fushi Server headless dirilis terpisah di [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> Membutuhkan Android 7.0 (API 24) atau lebih tinggi.

## Pembangunan

Persiapan satu perintah (`flutter pub get` + apply patches), lalu bangun:

```bash
# Dari root repositori
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Server headless (dari packages/fushi_server; gunakan `dart build cli`, bukan `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` menggabungkan `flutter pub get` dan `ci/apply-patches.sh` menjadi satu perintah. Proyek ini dikunci ke Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`); versi Flutter yang lebih lama tidak dapat membangunnya karena Material dan Cupertino dipakai sebagai paket `material_ui` / `cupertino_ui`. Beberapa dependensi hulu di-vendor di bawah `third_party/` atau ditambal oleh `ci/apply-patches.sh` — lihat [docs/agent/build.md](../agent/build.md) untuk detailnya, termasuk dependensi build desktop Linux.

<details>
<summary><b>Tumpukan Teknologi</b></summary>

| Lapisan | Teknologi |
|---|---|
| Kerangka kerja | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Platform | Android / Windows / macOS / iOS / Linux, ditambah server headless |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Pembaca | Mesin paginasi WebView (diturunkan dari keluarga Hoshi Reader) |
| Video | media_kit (inti libmpv) + libplacebo |
| Penyimpanan | Drift (SQLite, WAL) + fushidicts (mesin kamus C++ FFI) |
| NLP | Tabel transformasi Yomitan (lematisasi multibahasa) + kana_kit (konversi kana); tokenisasi melalui fushidicts FFI |
| AI di perangkat | ONNX Runtime untuk pengenalan suara (pembuatan subtitle) dan OCR manga; algoritmanya ada di [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Unduhan | libtorrent 2.x lewat jembatan FFI C-ABI (qBittorrent eksternal sebagai cadangan) |
| Sinkronisasi | Backend awan + Fushi Interconnect (LAN, alamat jarak jauh, dan terowongan P2P iroh) |
| Mesin bersama | `fushi_engine` — inti Dart murni yang dipakai bersama oleh aplikasi dan Fushi Server |
| Pembuatan Kartu | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 bahasa) |

</details>

<details>
<summary><b>Struktur Proyek</b></summary>

```
Fushi/                      # Repository root (Melos workspace: fushi_workspace)
├── fushi/                  # Flutter app main directory
│   ├── lib/
│   │   ├── i18n/            # Internationalization (17 languages, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (library pages, reader, video player, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Books, manga, video, audiobooks, online sources
│   │   │   ├── lookup/      # Dictionary lookup popups and overlays
│   │   │   ├── mining/      # Card creation (incl. galgame mining)
│   │   │   ├── sync/        # Cloud sync, Interconnect, media servers
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project
├── packages/                # Dart packages
│   ├── fushi_core/          #   Database schema, preferences
│   ├── fushi_engine/        #   Pure-Dart engine shared with the server
│   ├── fushi_server/        #   Headless server CLI + web UI
│   ├── fushi_cli/           #   Desktop command-line client
│   ├── fushi_dictionary/    #   Dictionary engine bindings and importers
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # libtorrent / iroh FFI bindings
│   └── …                    #   Vendored forks (inappwebview Windows/Linux, gamepads)
├── native/                  # Native sources: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Log collector and leaderboard backends (deployed separately)
├── tools/browser-extension/ # Browser lookup extension
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and CI scripts
├── tool/                    # bootstrap / setup_worktree / bug tracker scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

Impor video mendukung pengelompokan menurut karya atau folder. Lihat [alur kerja video](../specs/2026-09-07-video-library-workflow.md) dan [metadata MAL/TMDB dengan hashing berkas AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md) untuk pencocokan dan tugas latar belakang.

[Penyiapan layanan daring opsional](../specs/2026-09-07-online-services-setup.md) menjelaskan identitas aplikasi bawaan, kredensial pribadi, dan pengingat penyiapan video yang dapat ditutup.

## Privasi & Data

Fushi menyimpan buku, kamus, font, data buku audio, video, progres baca, sorotan, statistik, dan pengaturan yang diimpor di penyimpanan lokal aplikasi.

- **Sinkronisasi** — Google Drive / OneDrive / Dropbox memakai login OAuth; WebDAV / FTP / SFTP / Fushi Server memakai alamat server dan kredensial yang Anda berikan. Fushi Interconnect menghubungkan perangkat yang dipasangkan secara langsung (LAN, IPv6, jaringan overlay, atau alamat publik), dan beralih ke terowongan P2P iroh end-to-end bila tidak ada rute langsung yang berfungsi; tautan pemasangan selalu meminta konfirmasi.
- **Anki** — pembuatan kartu berkomunikasi dengan AnkiDroid atau alamat AnkiConnect yang Anda konfigurasi.
- **Statistik penggunaan** — sekali sehari, build desktop dan Android mengirim ID instalasi acak, versi aplikasi, platform, dan kanal pembaruan ke fushi.moe untuk menghitung pengguna aktif; tidak ada data akun, pustaka, atau bacaan yang disertakan dan alamat IP tidak disimpan. Matikan lewat *Bagikan statistik penggunaan* di pengaturan pembaruan. Build iOS tidak mengirimnya.
- **Hanya saat Anda memintanya** — unggah log (setelah satu kali permintaan persetujuan), umpan balik dalam aplikasi, dan papan peringkat (nonaktif secara default; mengunggah judul pustaka dan progres Anda hanya setelah Anda ikut serta).
- **OCR manga** — mesin default adalah Google Lens, yang mengirim gambar halaman ke Google; beralihlah ke model di perangkat atau OCR sistem di pengaturan agar gambar tetap lokal.
- **Fitur AI** — permintaan hanya dikirim ke penyedia LLM yang Anda konfigurasi dan tetapkan ke suatu fitur; tanpa penyedia yang ditetapkan, tidak ada yang dikirim.
- **Layanan pihak ketiga** — fitur metadata, subtitle, dan sumber daring menghubungi layanan yang tercantum di [Sumber konten dan integrasi](#sumber-konten-dan-integrasi) hanya saat Anda menggunakannya.

## Aktivitas Pengembangan

[![Aktivitas Pengembangan](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Pekerjaan sehari-hari masuk ke `develop`; `main` hanya menerima merge rilis. Grafik ditampilkan di sini pada `main` tetapi dibuat dari `develop`, sehingga mencerminkan pengembangan sebenarnya, bukan lalu lintas merge.

Tiga jalur adalah kanal pembaruan yang ditawarkan aplikasi itu sendiri, dan masing-masing diskalakan terhadap puncaknya sendiri — build debug jumlahnya dua orde magnitudo lebih banyak daripada rilis stabil, sehingga skala bersama akan meratakan dua jalur lainnya menjadi nol.

| Jalur | Yang dihitung | Cara mendapatkannya |
|---|---|---|
| **Debug (bergulir)** | Build push yang berhasil dari [release.yml](../../.github/workflows/release.yml) | Prarilis bergulir, dirilis ulang di setiap push |
| **Beta** | Prarilis `v<version>-beta.<seq>` | Build uji yang dijalankan secara manual |
| **Stabil** | Rilis `v<version>` | Rilis terbaru |

> Grafik di atas dibuat di dalam repositori ini (tanpa layanan pihak ketiga) dan diperbarui setiap hari oleh workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml).

## Riwayat Bintang

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Riwayat Bintang](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> Grafik di atas dibuat di dalam repositori ini (tanpa layanan pihak ketiga) dan diperbarui setiap hari oleh workflow [Update Star History](../../.github/workflows/star-history.yml).

## Penghargaan

Fushi dibangun di atas proyek dan ekosistem berikut:

### Alat belajar dan rujukan terdahulu

| Proyek | Deskripsi |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Alat belajar imersif bahasa Jepang |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Pembaca bahasa Jepang iOS; referensi mesin paginasi pembaca |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Pembaca bahasa Jepang native Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Mesin kamus C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solusi sinkronisasi buku audio |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Algoritma penyelarasan waktu subtitle terhadap acuan (GPL-3.0); dasar untuk menyelaraskan otomatis subtitle unduhan dengan trek tertanam |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referensi format kamus, tabel transformasi, dan pengalaman pencarian kata |
| [Lapis](https://github.com/donkuri/lapis) | Tipe catatan Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Integrasi pembuatan kartu Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referensi audio lokal dan interaksi AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referensi pembaca, statistik, dan kompatibilitas sinkronisasi |
| [media_kit](https://github.com/media-kit/media-kit) | Kerangka pemutaran video Flutter (inti libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Rangkaian belajar bahasa imersif untuk macOS |

### Mesin dan komponen native

| Proyek | Deskripsi |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Mesin hook teks galgame (DLL bawaan, dimuat oleh injector) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Pustaka inline hook yang dipakai injector galgame |
| [libtorrent](https://github.com/arvidn/libtorrent) | Mesin unduhan torrent bawaan |
| [mpv](https://github.com/mpv-player/mpv) | Inti pemutaran libmpv di balik media_kit |
| [FFmpeg](https://ffmpeg.org) | Pemeriksaan media, pemotongan, dan ekstraksi audio |
| [libplacebo](https://github.com/haasn/libplacebo) | Shader video GPU dan tone mapping HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Mesin WebView yang merender pembaca EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Inferensi di perangkat untuk pengenalan suara dan OCR |
| [iroh](https://github.com/n0-computer/iroh) | Terowongan P2P untuk koneksi Fushi Interconnect jarak jauh |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Dependensi mesin kamus |

### Model di perangkat

| Proyek | Deskripsi |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Paket model pengenalan suara Zipformer dan build VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Model pengenalan suara bahasa Jepang |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Model pengenalan suara bahasa Jepang |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Model pengenalan suara bahasa Jepang (CC BY-NC 4.0, diunduh dari repositori Hugging Face-nya) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Model pengenalan suara CTC multibahasa |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Model deteksi aktivitas suara |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Model deteksi teks dan balon percakapan manga |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Model deteksi panel manga, dilatih dengan [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Deteksi dan pengenalan baris teks; rec yang disetel untuk manga (dilatih dengan [Manga109-s](http://www.manga109.org/en/download_s.html) dan [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) menjadi tenaga model OCR lokal CTC per kolom |

> Model deteksi panel manga dan PP-OCRv6_manga dilatih dengan dataset Manga109-s (Matsui et al. 2017; Aizawa et al. 2020), yang ketentuannya mensyaratkan penggunaan dataset ini dinyatakan dengan jelas. PP-OCRv6_manga (Apache-2.0) juga dilatih dengan dataset AnimeText, yang berlisensi CC BY-NC-SA 4.0; aplikasi mengunduh model tersebut dari repositori Hugging Face-nya dan tidak mendistribusikannya ulang.

### Sumber konten dan integrasi

| Proyek | Deskripsi |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Ekosistem ekstensi sumber manga |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Ekosistem ekstensi sumber anime (extensions-lib 14–16, runtime yang sama) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Runtime ekstensi manga untuk desktop (di-vendor, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Rujukan adaptasi ekstensi Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Ekosistem plugin sumber novel ringan |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Server media yang dapat dijelajahi dari pustaka video |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Rujukan jembatan subtitle streaming untuk ekstensi peramban |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Rujukan arsitektur identifikasi dan scraping anime |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Rujukan arsitektur informasi pustaka galgame |
| [AniDB](https://anidb.net) | Identitas anime, episode, dan berkas |
| [MyAnimeList](https://myanimelist.net) (via [Jikan](https://jikan.moe)) | Metadata anime |
| [TMDB](https://www.themoviedb.org) | Metadata dan gambar pelengkap |
| [VNDB](https://vndb.org) | Metadata visual novel |
| [Jimaku](https://jimaku.cc) | Sumber subtitle bahasa Jepang |
| [OpenSubtitles](https://www.opensubtitles.com) | Sumber subtitle |

> Aplikasi ini menggunakan TMDB dan API TMDB tetapi tidak didukung, disertifikasi, atau disetujui oleh TMDB.

## Lisensi

Didistribusikan di bawah GNU General Public License v3.0. Lihat [LICENSE](../../LICENSE) untuk detailnya.

## Pengelola

Fushi dikelola oleh [hajisensai](https://github.com/hajisensai). Situs web: [fushi.moe](https://fushi.moe). Kontak: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | **Bahasa Indonesia** | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
