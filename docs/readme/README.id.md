<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | **Bahasa Indonesia** | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Unduh versi terbaru](https://img.shields.io/badge/%E2%AC%87%20Unduh%20versi%20terbaru-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Gabung Discord](https://img.shields.io/badge/Gabung%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Dukungan Platform

| Platform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Minimum Android 7.0 (API 24). Bahasa yang tersedia untuk pencarian kamus ditentukan oleh kamus yang diimpor dan tabel transformasi Yomitan, terlepas dari bahasa antarmuka.

### Bahasa Antarmuka (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Instalasi & Pembangunan

Persiapan satu perintah (`flutter pub get` + apply patches), lalu bangun:

```bash
# Dari root repositori
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
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
| Platform | Android / Windows / macOS / iOS (Material Design 3) |
| Pembaca | Mesin paginasi WebView (diturunkan dari keluarga Hoshi Reader) |
| Video | media_kit (inti libmpv) |
| Penyimpanan | Drift (SQLite, WAL) + fushidicts (mesin kamus C++ FFI) |
| NLP | Tabel transformasi Yomitan (lematisasi multibahasa) + kana_kit (konversi kana); tokenisasi melalui fushidicts FFI |
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
│   │   │   ├── pages/       # Pages (bookshelf, reader, dictionary, settings, etc.)
│   │   │   ├── reader/      # Reader WebView JS/CSS scripts
│   │   │   ├── media/       # Audiobook, subtitle parsing, reader source
│   │   │   └── models/      # Data models and state management (AppModel)
│   │   └── main.dart
│   └── android/             # Android project (manifest, native fushidicts)
├── packages/                # Internal packages + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # fushidicts C++ dictionary engine (FFI)
├── third_party/             # Vendored patched packages (dependency_overrides)
├── ci/                      # Build patches and integration test scripts
├── tool/                    # bootstrap / i18n_sync and other scripts
└── docs/                    # Development documentation (incl. docs/agent/ operations manual)
```

</details>

## Privasi & Data

Fushi menyimpan buku, kamus, font, data buku audio, video, progres baca, sorotan, statistik, dan pengaturan yang diimpor di penyimpanan lokal aplikasi.

Sinkronisasi awan (Google Drive / OneDrive / Dropbox) menggunakan kredensial OAuth yang dikonfigurasi pengguna; WebDAV / FTP / SFTP menggunakan alamat server dan kredensial yang disediakan pengguna; Fushi Interconnect terhubung langsung melalui alamat yang dikonfigurasi pengguna. Pembuatan kartu Anki berkomunikasi dengan AnkiDroid atau alamat AnkiConnect yang dikonfigurasi.

## Penghargaan

Fushi dibangun di atas proyek dan ekosistem berikut:

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
| [Niratan](https://github.com/W1ght/Niratan) | Rangkaian belajar bahasa imersif untuk macOS |

## Lisensi

Didistribusikan di bawah GNU General Public License v3.0. Lihat [LICENSE](../../LICENSE) untuk detailnya.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | **Bahasa Indonesia** | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
