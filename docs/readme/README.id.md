<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="logo hibiki" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | **Bahasa Indonesia** | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[Panduan Pengguna](../user-guide.id.md) | [Unduh versi terbaru](https://github.com/hajisensai/hibiki/releases)

> **Tonton apa yang ingin kamu tonton, lalu bahasanya ikut terkuasai.**

hibiki mengubah novel yang kamu baca, serial yang kamu ikuti, dan buku audio yang kamu dengar menjadi input bahasamu — ketuk kata asing mana pun untuk mencarinya, lalu jadikan kartu Anki dengan konteks aslinya hanya dengan sekali ketuk. Ia tidak menyuruhmu menghafal daftar kata yang sudah ditetapkan, melainkan hanya membantumu menangkap kata yang **benar-benar kamu baca dan dengar**.

Cara paling efektif untuk belajar bahasa adalah paparan dalam jumlah besar terhadap konten nyata, bukan menghafal kata-kata terisolasi dari buku kosakata. Tetapi "imersi" selalu punya dua kerepotan: mencari kata memutus alur, dan kamu lupa begitu mengalihkan pandangan. hibiki menyambungkan rantai itu:

📖 **Baca**: ketuk kata di pembaca EPUB untuk mencarinya, tanpa keluar dari halaman saat ini.<br>
🎧 **Dengar**: buku audio menyorot kalimat demi kalimat dan membalik halaman secara otomatis.<br>
🎬 **Tonton**: cari kata dan buat kartu langsung di subtitel video — mengikuti serial *adalah* input.<br>
🃏 **Endapkan**: kirim kata apa pun yang kamu cari, dari skenario mana pun, langsung ke Anki, dan tinjau ulang hanya kata yang benar-benar kamu temui.

Semua skenario berbagi kamus, statistik, dan alur peninjauan yang sama. Cocok untuk bahasa apa pun (Jepang, Inggris, …), dan terutama untuk pembelajar imersif yang meyakini **banyak input + hanya kartu buatan sendiri**. Tersedia untuk Android dan Windows (iOS dan macOS direncanakan).

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="Rak Buku" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="Pustaka Video" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="Pembacaan vertikal di desktop dengan popup pencarian" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="Pencarian kata video (popup bertingkat)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="Pencarian kata video (daftar subtitel)" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-mobile.png" alt="Pencarian via seleksi teks di luar aplikasi (ponsel)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-out-of-app-lookup-desktop.png" alt="Pencarian via seleksi teks di luar aplikasi (desktop)" width="100%"></td>
  </tr>
</table>

**Demo pembuatan kartu Anki sekali ketuk**

<video src="https://github.com/hajisensai/hibiki/raw/main/docs/static-assets/screenshots/hibiki-readme-anki-mining-demo.mp4" controls muted width="100%"></video>

> Video tidak muncul? [Lihat demo pembuatan kartu sekali klik ▶](https://github.com/hajisensai/hibiki/raw/main/docs/static-assets/screenshots/hibiki-readme-anki-mining-demo.mp4)

</div>

## Fitur

### Rak Buku

- Impor EPUB satu per satu, secara massal, atau rekursif berdasarkan folder; lihat progres baca di rak.
- Atur buku dengan rak buku khusus, penyaringan tag, dan seret untuk menyusun ulang.
- Seret dan letakkan berkas untuk mengimpor buku, subtitel, atau video (desktop).
- Otomatis mengaitkan berkas subtitel / audio bernama sama saat impor.

### Membaca

- Baca dalam tata letak vertikal atau horizontal; beralih antara mode berhalaman dan gulir berkelanjutan.
- Sesuaikan tema (terang / gelap / hitam pekat / khusus), font, jarak paragraf, dan kontrol pembaca.
- Anotasi Furigana (ふりがな).
- Skala antarmuka yang dapat disesuaikan; kontrol bilah bawah mengikuti skala.
- Profil multi-pengguna (Profile), beralih otomatis per buku.

### Pencarian Kata

- Impor kamus [Yomitan](https://github.com/yomidevs/yomitan) (dahulu Yomichan), ABBYY Lingvo (DSL), MDict (MDX), dan Migaku.
- Ketuk teks di pembaca untuk mencari kata, cari di halaman kamus, atau bagikan teks dari aplikasi lain.
- Deinfleksi yang mencakup **semua bahasa tabel transformasi Yomitan** + normalisasi teks sebelum pencarian (huruf besar/kecil / diakritik / harakat Arab), digerakkan oleh titik kode (code points) tanpa pergantian bahasa.
- Ketuk kata di dalam definisi untuk pencarian rekursif (popup bertingkat).
- Kueri multi-kamus paralel, prioritas dan pengalihan sub-sumber, anotasi aksen nada (pitch-accent) dan frekuensi.
- Audio kata daring dan lokal.
- Sisipkan CSS khusus.

### Sorotan & Statistik

- Tambahkan sorotan lima warna saat membaca; lompat ke sorotan mana pun kapan saja.
- Statistik baca: jumlah karakter terbaca, durasi, kecepatan baca — ditampilkan secara real-time saat membaca.
- Statistik video: waktu tonton, kartu yang dibuat, dan favorit.

### Pembuatan Kartu Anki

- Buat kartu melalui [AnkiDroid](https://github.com/ankidroid/Anki-Android) atau AnkiConnect.
- Tipe catatan [Lapis](https://github.com/donkuri/lapis) bawaan (vendored 1.7.0); buat templat kartu dan dek di dalam aplikasi sekali ketuk.
- Isi otomatis kalimat konteks; perekaman audio dan pemotongan tangkapan layar.
- Beberapa profil ekspor (Profile) dan pemetaan bidang khusus.
- Kata favorit; kartu yang dibuat dan favorit dihitung dalam statistik.

### Sinkronisasi Buku Audio (Sasayaki)

- Dukungan subtitel SRT / LRC / VTT / ASS; secara otomatis menyelaraskan teks subtitel dengan isi EPUB.
- Penyorotan kalimat yang mengikuti dan pembalik halaman otomatis selama pemutaran.
- Kecepatan pemutaran, aksi pencarian posisi, dan kontrol media sistem.
- "Putar dari kalimat ini" dengan kelanjutan lintas bab tanpa jeda.

### Pencarian Kata dari Subtitel Video

- Pemutar video bawaan berbasis [media_kit](https://github.com/media-kit/media-kit) (inti libmpv).
- Subtitel tertanam (trek teks + grafik) dan eksternal; impor daftar putar .m3u8.
- Cari kata dan buat kartu langsung dari subtitel selama pemutaran.
- Manajemen pustaka video, penyaringan tag, pengelompokan seri, dan operasi massal.

### Sinkronisasi Data

- Tujuh backend sinkronisasi: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP, dan Hibiki P2P.
- Sinkronkan progres baca, statistik, dan buku.

### Lainnya

- **17 bahasa antarmuka**, dilokalkan sepenuhnya di semua platform.
- Bagikan teks dari aplikasi lain untuk langsung mencari kata.

## Dukungan Platform

| Platform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> Minimum Android 7.0 (API 24). Bahasa yang tersedia untuk pencarian kamus ditentukan oleh kamus yang diimpor dan tabel transformasi Yomitan, terlepas dari bahasa antarmuka.

### Bahasa Antarmuka (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Instalasi & Pembangunan

Persiapan satu perintah (`flutter pub get` + apply patches), lalu bangun:

```bash
# Dari root repositori
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` menggabungkan `flutter pub get` dan `ci/apply-patches.sh` menjadi satu perintah. Proyek ini dikunci ke Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); beberapa dependensi hulu di-vendor di bawah `third_party/` atau ditambal oleh `ci/apply-patches.sh` — lihat [docs/agent/build.md](../agent/build.md) untuk detailnya.

<details>
<summary><b>Tumpukan Teknologi</b></summary>

| Lapisan | Teknologi |
|---|---|
| Kerangka kerja | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platform | Android / Windows (Material Design 3) |
| Pembaca | Mesin paginasi WebView (diturunkan dari keluarga Hoshi Reader) |
| Video | media_kit (inti libmpv) |
| Penyimpanan | Drift (SQLite, WAL) + hoshidicts (mesin kamus C++ FFI) |
| NLP | Tabel transformasi Yomitan (lematisasi multibahasa) + kana_kit (konversi kana); tokenisasi melalui hoshidicts FFI |
| Pembuatan Kartu | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 bahasa) |

</details>

<details>
<summary><b>Struktur Proyek</b></summary>

```
hibiki/                      # Repository root (Melos workspace: hibiki_workspace)
├── hibiki/                  # Flutter app main directory
│   ├── lib/
│   │   ├── i18n/            # Internationalization (17 languages, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bookshelf, reader, dictionary, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Audiobook, subtitle parsing, reader source
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project (manifest, native hoshidicts)
├── packages/                # Internal packages + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # hoshidicts C++ dictionary engine (FFI)
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

## Privasi & Data

hibiki menyimpan buku, kamus, font, data buku audio, video, progres baca, sorotan, statistik, dan pengaturan yang diimpor di penyimpanan lokal aplikasi.

Sinkronisasi awan (Google Drive / OneDrive / Dropbox) menggunakan kredensial OAuth yang dikonfigurasi pengguna; WebDAV / FTP / SFTP menggunakan alamat server dan kredensial yang disediakan pengguna; Hibiki P2P terhubung langsung melalui alamat yang dikonfigurasi pengguna. Pembuatan kartu Anki berkomunikasi dengan AnkiDroid atau alamat AnkiConnect yang dikonfigurasi.

## Penghargaan

hibiki dibangun di atas proyek dan ekosistem berikut:

| Proyek | Deskripsi |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Alat belajar imersif bahasa Jepang |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Pembaca bahasa Jepang iOS; referensi mesin paginasi pembaca |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Pembaca bahasa Jepang native Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Mesin kamus C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solusi sinkronisasi buku audio |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referensi format kamus, tabel transformasi, dan pengalaman pencarian kata |
| [Lapis](https://github.com/donkuri/lapis) | Tipe catatan Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Integrasi pembuatan kartu Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referensi audio lokal dan interaksi AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referensi pembaca, statistik, dan kompatibilitas sinkronisasi |
| [media_kit](https://github.com/media-kit/media-kit) | Kerangka pemutaran video Flutter (inti libmpv) |

## Lisensi

Didistribusikan di bawah GNU General Public License v3.0. Lihat [LICENSE](../../LICENSE) untuk detailnya.

<div align="center">

<br>

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | **Bahasa Indonesia** | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
