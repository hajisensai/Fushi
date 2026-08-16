# Panduan Fushi yang bahkan Yui Hirasawa bisa siapkan dalam 5 menit

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | **Bahasa Indonesia** | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Panduan dalam bahasa Tionghoa Sederhana di-host di Feishu (tautan di atas). Panduan bahasa Inggris juga tersedia [di GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## Pendahuluan

**Fushi — ubah maraton membaca dan menonton menjadi input bahasa.**

Ketuk kata apa pun untuk mencarinya saat Anda membaca novel, menonton anime, atau mendengarkan buku audio, lalu kirim kata baru ke Anki bersama kalimat asalnya.

Tanpa daftar kata bawaan — Anda hanya mengulang kata yang benar-benar Anda temui. Bekerja dengan bahasa apa pun.

- 📖 Membaca EPUB · ketuk untuk mencari
- 🎧 Buku audio dengan penyorotan kalimat per kalimat
- 🎬 Pencarian pada takarir video dan pembuatan kartu
- 🃏 Pembuatan kartu Anki sekali ketuk + statistik pengulangan
- 📚 Membaca manga · cari kata langsung dari halaman melalui OCR
- ⬇️ Unduh anime dan manga sekali ketuk di dalam aplikasi — otomatis ditambahkan ke pustaka Anda dan bisa diputar meski masih diunduh
- 🎮 Penambangan suara Galgame (Windows) · suara asli ikut masuk ke kartu bersama teksnya

Platform: Android / Windows / macOS / iOS (Linux dapat dibangun dari kode sumber; belum ada paket siap pakai)

### URL proyek

https://github.com/hajisensai/Fushi

Sedang dikembangkan secara aktif — masukan Anda akan ditangani dengan cepat. Laporan bug dan permintaan fitur sangat diterima. Jika Anda merasa Fushi bermanfaat, kami berterima kasih jika Anda membagikannya kepada orang lain atau memberikan ⭐ pada repositori.

### Unduh

https://github.com/hajisensai/Fushi/releases/latest

Pilih berkas yang sesuai dengan platform Anda: **Android** — APK `arm64-v8a` (semua ponsel beberapa tahun terakhir memakai ini; hanya perangkat lama yang membutuhkan `armeabi-v7a`, dan emulator memakai `x86_64`); **Windows** — `windows-setup.exe`; **macOS** — `macos.zip`; **iOS** — `ios.ipa`. **Linux** belum memiliki paket siap pakai, jadi harus dibangun dari kode sumber.

APK yang namanya diawali `bridge-` adalah jembatan migrasi untuk **pengguna Hibiki lama**; Anda bisa mengabaikannya.

## Tutorial Konfigurasi

### 1. Mengimpor kamus yang direkomendasikan (kamus kata + aksen nada + frekuensi) dan audio lokal (basis data audio bahasa Jepang dan Inggris) (Sangat direkomendasikan untuk pemula!!! · opsional)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Unduhan Cloudflare (9,5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

Di dalam aplikasi: Pengaturan -> Sinkronisasi & Cadangan -> ketuk **Impor Cadangan**.

![Layar impor cadangan](static-assets/user-guide/import-backup.png)

### 2. Mengunduh dan mengonfigurasi Anki dari situs resmi Anki

Anki — dinamai dari 暗記 (あんき) — adalah [sistem pengulangan berjarak (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) yang paling banyak digunakan di dunia, dan merupakan alat yang sangat penting.

Tautan: [Situs resmi Anki](https://apps.ankiweb.net/) · [Manual (Tionghoa)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Tionghoa)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Halaman unduh Anki](static-assets/user-guide/anki-download.png)

Anda dapat memberikan materi apa pun yang ingin Anda hafal kepada Anki, dan ia memungkinkan Anda mencapai retensi terbaik dengan waktu belajar paling sedikit.

Anki memiliki [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) bawaan — salah satu algoritme pengulangan berjarak terbaik di dunia.

**TETAPI!!!** Algoritme bawaan Anki adalah SM2, algoritme dari lebih dari 30 tahun lalu yang berkinerja buruk. Pastikan untuk mengubah algoritme yang digunakan Anki menjadi **FSRS**.

#### Anki

##### Android

1. Pasang dan buka Anki.
2. Kembali ke Fushi, buka Pengaturan -> Pembuatan Kartu.
3. Ketuk **Segarkan dek dan tipe catatan** (ditandai "1" pada gambar); Fushi akan meminta izin — ketuk Izinkan.
4. Ketuk **Buat dek Lapis** (ditandai "2" pada gambar).
5. Jika tidak ada peringatan atau kesalahan berwarna merah, penyiapan berhasil.

![Penyiapan Anki di Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Pasang dan buka Anki.
2. Klik **Alat (Tools)** di kiri atas.

![Menu Alat Anki di Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Tempel kode add-on Anki di bawah untuk memasangnya: `2055492159`
4. Kembali ke Fushi, buka Pengaturan -> Pembuatan Kartu.
5. Ketuk **Segarkan dek dan tipe catatan** (ditandai "1").
6. Ketuk **Buat dek Lapis** (ditandai "2").
7. Jika tidak ada peringatan atau kesalahan berwarna merah, penyiapan berhasil.

![Penyiapan Anki di Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Telusuri opsi konfigurasi di Pengaturan dan lihat apakah ada yang ingin Anda sesuaikan. (Opsional)

Saatnya mulai berimersi.

## Fitur yang Direkomendasikan

### Mencari kata di luar aplikasi

**Android:** pilih sebuah kata, lalu ketuk **Terjemahkan** atau **Fushi** pada menu seleksi.

**Windows:** pilih sebuah kata, lalu tekan **Ctrl+Alt+D** (pintasan dapat diubah di Pengaturan -> Pintasan).

### Pencarian lewat papan klip

Apa pun yang Anda salin akan dicari secara otomatis. Tersedia dua mode tampilan — **panel mengambang** dan **jendela teks transparan** — keduanya dapat dikonfigurasi di Pengaturan -> Pencarian.

### Pencarian di peramban / penambangan takarir layanan streaming (Netflix)

Pasang ekstensi peramban dari halaman beranda Fushi.

## Ucapan Terima Kasih

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
