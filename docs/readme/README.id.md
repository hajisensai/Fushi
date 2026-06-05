<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Pembaca bahasa Jepang imersif untuk Android</p>
<p align="center">EPUB · Kamus · Anki · Sinkronisasi Buku Audio</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <b>Bahasa Indonesia</b> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Pendahuluan

**hibiki** adalah aplikasi membaca di Android untuk pelajar bahasa Jepang.

## Fitur

### Pembacaan EPUB
- Render EPUB di WebView (mesin paginasi turunan dari [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- Ketuk untuk mencari kata, pilih teks untuk menganalisis
- Font kustom, tema (terang/gelap)
- Statistik membaca dan penanda halaman
- Mode gulir berkelanjutan / halaman

### Kamus
- Impor kamus format [Yomitan](https://github.com/yomidevs/yomitan) (sebelumnya Yomichan)
- Data aksen nada dan frekuensi kata
- Pencarian paralel multi-kamus, riwayat pencarian
- Dekonjugasi Ve

### Kartu Anki
- Ekspor satu ketuk ke [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Pengisian otomatis kalimat konteks
- Dukungan perekaman audio, pemotongan tangkapan layar
- Beberapa profil ekspor, pemetaan bidang kustom
- Aksi Cepat (Quick Actions) pembuatan kartu satu langkah

### Sinkronisasi Buku Audio (Sasayaki)
- Format subtitle: SRT / LRC / VTT / ASS
- Penyelarasan otomatis subtitle dengan teks EPUB
- Penyorotan mengikuti audio, pergantian halaman sinkron
- Kontrol pemutaran (progres, lompat, kecepatan)

### Lainnya
- 17 bahasa antarmuka
- Beberapa profil pengguna
- Mode penyamaran
- Bagikan teks dari aplikasi lain untuk mencari kata

## Bahasa yang Didukung

Antarmuka mendukung bahasa-bahasa berikut:

| Bahasa | Kode |
|---|---|
| English | `en` |
| 简体中文 | `zh-CN` |
| 繁體中文 | `zh-HK` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español | `es` |
| Français | `fr` |
| Deutsch | `de` |
| Português (Brasil) | `pt-BR` |
| Русский | `ru` |
| Tiếng Việt | `vi` |
| ภาษาไทย | `th` |
| Bahasa Indonesia | `id` |
| Italiano | `it` |
| Nederlands | `nl` |
| Türkçe | `tr` |
| العربية | `ar` |

## Tumpukan Teknologi

| Lapisan | Teknologi |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platform | Android / iOS / macOS / Windows / Linux (adaptif Material 3 + Cupertino) |
| Pembaca | Mesin paginasi WebView (turunan dari [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Penyimpanan | Drift (SQLite, WAL) + hoshidicts (mesin kamus C++ FFI) |
| NLP | Ve (dekonjugasi) |
| Pembuatan kartu | AnkiDroid API |
| Internasionalisasi | Slang (17 bahasa) |
| Versi minimum | Android 7.0 (API 24) |

## Build

Persiapan satu perintah (`flutter pub get` + terapkan patch), lalu build:

```bash
# Di root repositori
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # atau (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` menyatukan dua hal menjadi satu perintah: ① `flutter pub get`;
② menjalankan `ci/apply-patches.sh`. `melos bootstrap` melakukan hal yang sama melalui post hook
(di Windows melos punya bug encoding CJK, jadi gunakan `tool/bootstrap.ps1`).

> **Catatan patch:** `ci/apply-patches.sh` menimpa perubahan di `ci/patches/` ke pub cache yang sebenarnya. Setiap kali pub cache dihapus atau `flutter pub get` dijalankan ulang harus dijalankan kembali (bootstrap sudah mencakup langkah ini). Ketika skrip tidak menemukan target patch apa pun, ia melewati dan memberi peringatan alih-alih berpura-pura berhasil.

## Dependensi & Patch

Proyek ini dikunci ke Flutter 3.44.0, beberapa dependensi upstream belum diadaptasi. Patching dibagi menjadi dua mekanisme: ① paket yang perlu menjadi input build dan direproduksi konsisten antar mesin di-vendor langsung ke `third_party/` dan ditunjuk dengan `dependency_overrides` (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **tanpa** patch pub-cache); ② paket selebihnya dipatch sumbernya di pub cache oleh `ci/apply-patches.sh`. Detail mekanisme lihat [docs/agent/build.md](../agent/build.md). Tabel lipat di bawah adalah daftar historis yang dikelompokkan berdasarkan perubahan; untuk paket yang tumpang tindih dengan mekanisme ①, versi vendored yang berlaku.

<details>
<summary><b>Patch Perubahan Flutter API</b></summary>

| Paket | Perubahan |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; ganti `imageCache.putIfAbsent` yang dihapus |
| `flutter_blurhash` 0.7.0 | Sama: `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Tambahkan `hide CarouselController` pada import internal untuk menghindari konflik nama |
| `fading_edge_scrollview` 3.0.0 | Perbaikan `PageView.controller` nullable |

</details>

<details>
<summary><b>Patch Penghapusan v1 Embedding</b></summary>

Flutter 3.44.0 sepenuhnya menghapus v1 embedding API (`PluginRegistry.Registrar`). Plugin berikut perlu referensi terkait dihapus:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Patch Gradle / Kotlin</b></summary>

| Target | Perubahan |
|---|---|
| `android/build.gradle` afterEvaluate | Paksa `compileSdk` pada subproyek (default 36, beberapa 34); hapus `-Werror` |
| `audio_session` 0.1.14 | Hapus `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Perbaikan Kotlin null safety |
| `receive_intent` (git) | Perbaikan Kotlin null safety |

</details>

<details>
<summary><b>Dependensi Git</b></summary>

| Paket | Sumber |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

</details>

## Struktur Proyek

```
hibiki/                      # Root repo (Melos workspace: hibiki_workspace)
├── hibiki/                  # Direktori utama aplikasi Flutter
│   ├── lib/
│   │   ├── i18n/            # Internasionalisasi (17 bahasa, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Halaman (rak buku, pembaca, kamus, pengaturan, dll.)
│   │   │   ├── reader/      # Skrip JS/CSS WebView pembaca
│   │   │   ├── media/       # Buku audio, penguraian subtitle, reader source
│   │   │   └── models/      # Model data & manajemen state (AppModel)
│   │   └── main.dart
│   └── android/             # Proyek Android (manifest, native hoshidicts)
├── packages/                # Paket internal + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # Paket patch vendored (ditunjuk dependency_overrides)
├── ci/                      # Skrip patch build dan pengujian integrasi
├── tool/                    # Skrip bootstrap / i18n_sync, dll.
└── docs/                    # Dokumentasi pengembangan (termasuk manual operasi agent docs/agent/)
```

## Penghargaan

| Proyek | Deskripsi |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Alat pembelajaran bahasa Jepang imersif |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Pembaca bahasa Jepang untuk Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Mesin kamus C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Pembaca bahasa Jepang untuk iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solusi sinkronisasi buku audio |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Mesin render EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Versi komunitas ttu (SvelteKit v2), basis upstream hibiki fork |
| [Yomitan](https://github.com/yomidevs/yomitan) | Sumber format kamus |

## Lisensi

[GNU General Public License v3.0](../../LICENSE)
