# Panduan Pengguna hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | **Bahasa Indonesia** | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Panduan dalam bahasa Tionghoa Sederhana di-host di Feishu (tautan di atas). Panduan bahasa Inggris juga tersedia [di GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## Pendahuluan

Ini adalah perangkat lunak gratis untuk Android / Windows (iOS / macOS direncanakan) — aplikasi sumber terbuka lintas platform yang inovatif, yang menggabungkan membaca novel, pemutaran buku audio, pemutaran video, dan pencarian kamus.

### URL proyek

https://github.com/hajisensai/hibiki

Sedang dikembangkan secara aktif — masukan Anda akan ditangani dengan cepat. Laporan bug dan permintaan fitur sangat diterima. Jika Anda merasa Hibiki bermanfaat, kami berterima kasih jika Anda membagikannya kepada orang lain atau memberikan ⭐ pada repositori.

### Unduh

https://github.com/hajisensai/hibiki/releases/latest

Android: pilih **arm64**. Windows: pilih berkas **.exe**.

## Tutorial Konfigurasi

### 1. Mengimpor kamus yang direkomendasikan dan audio lokal (opsional)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

Di dalam aplikasi: Pengaturan -> Sinkronisasi & Cadangan -> ketuk **Impor Cadangan**.

**Catatan: mengimpor cadangan akan menghapus data lokal. Alur ini akan ditingkatkan pada pembaruan mendatang.**

![Layar impor cadangan](static-assets/user-guide/import-backup.png)

### 2. Mengunduh dan mengonfigurasi Anki dari situs resmi Anki

Anki — dinamai dari 暗記 (あんき) — adalah [sistem pengulangan berjarak (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) yang paling banyak digunakan di dunia, dan merupakan alat yang sangat penting.

Tautan: [Situs resmi Anki](https://apps.ankiweb.net/) · [Manual (Tionghoa)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Tionghoa)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Gambar: ilustrasi / keterangan]*

Anda dapat memberikan materi apa pun yang ingin Anda hafal kepada Anki, dan ia memungkinkan Anda mencapai retensi terbaik dengan waktu belajar paling sedikit.

Anki memiliki [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) bawaan — salah satu algoritme pengulangan berjarak terbaik di dunia.

**TETAPI!!!** Algoritme bawaan Anki adalah SM2, algoritme dari lebih dari 30 tahun lalu yang berkinerja buruk. Pastikan untuk mengubah algoritme yang digunakan Anki menjadi **FSRS**.

#### Anki

##### Android

1. Pasang dan buka Anki.
2. Kembali ke hibiki, buka Pengaturan -> Pembuatan Kartu.
3. Ketuk **Segarkan dek dan tipe catatan** (ditandai "1" pada gambar); hibiki akan meminta izin — ketuk Izinkan.
4. Ketuk **Buat dek Lapis** (ditandai "2" pada gambar).
5. Jika tidak ada peringatan atau kesalahan berwarna merah, penyiapan berhasil.

![Penyiapan Anki di Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Pasang dan buka Anki.
2. Klik **Alat (Tools)** di kiri atas.

![Menu Alat Anki di Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Tempel kode add-on Anki di bawah untuk memasangnya: `2055492159`
4. Kembali ke hibiki, buka Pengaturan -> Pembuatan Kartu.
5. Ketuk **Segarkan dek dan tipe catatan** (ditandai "1").
6. Ketuk **Buat dek Lapis** (ditandai "2").
7. Jika tidak ada peringatan atau kesalahan berwarna merah, penyiapan berhasil.

![Penyiapan Anki di Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Telusuri opsi konfigurasi di Pengaturan dan lihat apakah ada yang ingin Anda sesuaikan. (Opsional)

## Ucapan Terima Kasih

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
