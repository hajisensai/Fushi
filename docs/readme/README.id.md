<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Baca satu buku, dan jadikan setiap kata baru milikmu.</b></p>
<p align="center">Pembaca imersif multiplatform & multibahasa —— Baca EPUB · Cari kata dengan sekali ketuk · Buat kartu Anki · Sinkronisasi buku audio · Cari kata dari subtitle video</p>

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
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Beranda Proyek (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <b>Bahasa Indonesia</b> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Pendahuluan

**hibiki** adalah pembaca pembelajaran bahasa imersif lintas platform. Di dalam teks EPUB Anda bisa **ketuk untuk mencari kata, pilih kata untuk menganalisis** secara langsung, lalu menjadikan kata baru sebagai kartu Anki hanya dengan sekali ketuk; menyelaraskan audio buku audio dengan teks dan menyorotinya kalimat demi kalimat; bahkan mencari kata dan membuat kartu langsung dari subtitle video. Satu perangkat mencakup ketiga jalur masukan imersif Anda: «baca · dengar · tonton».

Pencarian kamus mencakup **seluruh bahasa transformasi** [Yomitan](https://github.com/yomidevs/yomitan) (dekonjugasi + normalisasi teks sebelum pencarian), antarmuka dilokalkan ke **17 bahasa**, serta mendukung **Android / iOS / macOS / Windows / Linux** kelima platform.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Rak buku" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Cari kata" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Pengaturan & tema" width="300">
</p>
<p align="center"><sub>Rak buku · Cari kata · Pengaturan & tema</sub></p>

---

## Sorotan Utama

### 📖 Baca EPUB, ketuk langsung cari

Pembaca EPUB yang dirender dengan WebView (mesin paginasi turunan dari [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)), ketuk kata apa pun untuk pencarian instan, pilih teks untuk analisis instan. Dua mode gulir berkelanjutan dan paginasi, font serta tema kustom (terang / gelap / hitam pekat / kustom), furigana, statistik membaca, dan penanda halaman semuanya tersedia.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Baca vertikal · furigana · sinkronisasi buku audio" width="300">
</p>
<p align="center"><sub>Teks vertikal · furigana · sorot kata terpilih · bilah kontrol sinkronisasi buku audio di bawah</sub></p>

### 🔍 Cari kata dengan ketuk, mencakup semua bahasa transformasi Yomitan

Impor kamus berbagai format: **Yomitan** (sebelumnya Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Pemulihan bentuk kata multibahasa (tabel transformasi Yomitan) + normalisasi teks sebelum pencarian (huruf besar/kecil / tanda diakritik / harakat Arab), digerakkan per titik kode (code point), tanpa perlu beralih bahasa. Pencarian paralel multi-kamus, prioritas serta aktif-nonaktif sumber turunan, anotasi nada dan frekuensi kata, semua selesai dalam satu jendela.

### 🎴 Buat kartu Anki satu langkah

Setelah menemukan kata baru, ekspor dalam satu langkah ke [AnkiDroid](https://github.com/ankidroid/Anki-Android) dan AnkiConnect. Dilengkapi schema jenis catatan [Lapis](https://github.com/donkuri/lapis) bawaan (vendored 1.7.0), Anda dapat membuat templat kartu dan dek langsung di dalam aplikasi; pengisian otomatis kalimat konteks, dukungan perekaman audio dan pemotongan tangkapan layar, beberapa profil ekspor (Profile), pemetaan bidang kustom, serta aksi cepat pembuatan kartu satu langkah.

### 🎧 Sinkronisasi buku audio (Sasayaki)

Mendukung subtitle SRT / LRC / VTT / ASS, secara otomatis menyelaraskan teks subtitle ke teks EPUB. Saat memutar, **sorot mengikuti bacaan, pergantian halaman tersinkron audio**, dipadukan dengan bilah kontrol pemutaran (progres, lompat, kecepatan); saat mendengarkan, teks menyala kalimat demi kalimat —— bilah kontrol di bagian bawah tangkapan layar membaca di atas halaman ini adalah fungsi ini.

### 🎬 Cari kata dari subtitle video

Pemutar video bawaan berbasis media_kit / libmpv, mendukung subtitle tertanam / eksternal. Saat memutar video Anda bisa **mencari kata dan membuat kartu langsung pada subtitle**, menjadikan materi film juga sebagai masukan imersif; sekaligus mencatat statistik durasi tonton dan jumlah kartu yang dibuat.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Tangkapan layar pemutar video menyusul —— perlu diambil di perangkat nyata / latar depan (gambar video + bilah subtitle + jendela cari kata, lihat keterangan di bawah).</sub></p>

### 🔗 Lainnya

- **17 bahasa antarmuka**, dilokalkan di semua platform
- **Hibiki Interconnect**: sinkronisasi buku / kamus / buku audio / progres membaca antar perangkat
- **Beberapa profil pengguna (Profile)**, beralih otomatis per buku
- **Mode penyamaran**; **bagikan teks dari aplikasi lain untuk langsung mencari kata**

---

## Platform yang Didukung

| Platform | Status | Render / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (fork `flutter_inappwebview_windows` merender EPUB) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Minimal Android 7.0 (API 24). Bahasa pencarian kamus ditentukan oleh kamus yang diimpor dan tabel transformasi Yomitan, terpisah dari bahasa antarmuka.

### Bahasa Antarmuka (17 bahasa)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Instalasi dan Build

Persiapan satu perintah (`flutter pub get` + terapkan patch), lalu build:

```bash
# Di root repositori
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # atau (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` menyatukan ① `flutter pub get` dan ② `ci/apply-patches.sh` menjadi satu perintah. Proyek ini mengunci Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); sebagian dependensi upstream di-vendor ke `third_party/` atau dipatch oleh `ci/apply-patches.sh` —— detail mekanisme, build kelima platform, daftar dependensi dan patch lihat [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Sekilas Tumpukan Teknologi</b></summary>

| Lapisan | Teknologi |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platform | Android / iOS / macOS / Windows / Linux (adaptif Material 3 + Cupertino) |
| Pembaca | Mesin paginasi WebView (turunan dari [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Video | media_kit / libmpv |
| Penyimpanan | Drift (SQLite, WAL) + hoshidicts (mesin kamus C++ FFI) |
| NLP | Tabel transformasi Yomitan (pemulihan bentuk kata multibahasa) + kana_kit (konversi kana); segmentasi lewat hoshidicts FFI |
| Pembuatan kartu | AnkiDroid API + AnkiConnect |
| Internasionalisasi | Slang (17 bahasa) |

</details>

<details>
<summary><b>Struktur Proyek</b></summary>

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
├── native/                  # Mesin kamus C++ hoshidicts (FFI)
├── third_party/             # Paket patch vendored (ditunjuk dependency_overrides)
├── ci/                      # Skrip patch build dan pengujian integrasi
├── tool/                    # Skrip bootstrap / i18n_sync, dll.
└── docs/                    # Dokumentasi pengembangan (termasuk manual operasi agent di docs/agent/)
```

</details>

---

## Penghargaan

| Proyek | Deskripsi |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Alat pembelajaran bahasa Jepang imersif |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Pembaca bahasa Jepang untuk Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Mesin kamus C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Pembaca bahasa Jepang untuk iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solusi sinkronisasi buku audio |
| [Yomitan](https://github.com/yomidevs/yomitan) | Sumber format kamus dan tabel transformasi |
| [Lapis](https://github.com/donkuri/lapis) | Jenis catatan Anki |

## Lisensi

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <b>Bahasa Indonesia</b> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
