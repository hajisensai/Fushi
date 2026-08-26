<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo Fushi" width="160">

![Nền tảng](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![Giấy phép](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | **Tiếng Việt** | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Tải bản mới nhất](https://img.shields.io/badge/%E2%AC%87%20T%E1%BA%A3i%20b%E1%BA%A3n%20m%E1%BB%9Bi%20nh%E1%BA%A5t-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Tham gia Discord](https://img.shields.io/badge/Tham%20gia%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Nền tảng hỗ trợ

| Nền tảng | Trạng thái | Hiển thị / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Tối thiểu Android 7.0 (API 24). Các ngôn ngữ khả dụng để tra từ điển do các từ điển đã nhập và bảng biến đổi Yomitan quyết định, độc lập với ngôn ngữ giao diện.

### Ngôn ngữ giao diện (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Cài đặt và biên dịch

Chuẩn bị bằng một lệnh (`flutter pub get` + áp dụng bản vá), sau đó biên dịch:

```bash
# tại thư mục gốc của kho
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` gom `flutter pub get` và `ci/apply-patches.sh` vào một lệnh. Dự án được khóa ở Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); một số phụ thuộc upstream được vendor vào `third_party/` hoặc được `ci/apply-patches.sh` vá — chi tiết xem [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Công nghệ</b></summary>

| Tầng | Công nghệ |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Nền tảng | Android / Windows / macOS / iOS (Material Design 3) |
| Trình đọc | Engine phân trang WebView (phái sinh từ dòng Hoshi Reader) |
| Video | media_kit (lõi libmpv) |
| Lưu trữ | Drift (SQLite, WAL) + fushidicts (engine từ điển C++ FFI) |
| NLP | Bảng biến đổi Yomitan (chuyển dạng từ vựng đa ngôn ngữ) + kana_kit (chuyển đổi kana); phân tách từ qua fushidicts FFI |
| Tạo thẻ | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 ngôn ngữ) |

</details>

<details>
<summary><b>Cấu trúc dự án</b></summary>

```
Fushi/                      # Gốc kho (Melos workspace: fushi_workspace)
├── fushi/                  # Thư mục chính ứng dụng Flutter
│   ├── lib/
│   │   ├── i18n/            # Quốc tế hóa (17 ngôn ngữ, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Trang (kệ sách, trình đọc, từ điển, cài đặt, v.v.)
│   │   │   ├── reader/      # Script JS/CSS WebView của trình đọc
│   │   │   ├── media/       # Sách nói, phân tích phụ đề, reader source
│   │   │   └── models/      # Mô hình dữ liệu và quản lý trạng thái (AppModel)
│   │   └── main.dart
│   └── android/             # Dự án Android (manifest, native fushidicts)
├── packages/                # Package nội bộ + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Engine từ điển C++ fushidicts (FFI)
├── third_party/             # Gói vá vendored (dependency_overrides)
├── ci/                      # Bản vá biên dịch và script kiểm thử tích hợp
├── tool/                    # Script bootstrap / i18n_sync, v.v.
└── docs/                    # Tài liệu phát triển (gồm sổ tay thao tác docs/agent/)
```

</details>

## Quyền riêng tư và dữ liệu

Fushi lưu trữ sách, từ điển, phông chữ, dữ liệu sách nói, video, tiến độ đọc, vùng tô sáng, thống kê và cài đặt đã nhập trong bộ nhớ cục bộ của ứng dụng.

Đồng bộ đám mây (Google Drive / OneDrive / Dropbox) sử dụng thông tin xác thực OAuth do người dùng cấu hình; WebDAV / FTP / SFTP sử dụng địa chỉ máy chủ và thông tin xác thực do người dùng cung cấp; Fushi Interconnect kết nối trực tiếp qua địa chỉ do người dùng cấu hình. Việc tạo thẻ Anki giao tiếp với AnkiDroid hoặc địa chỉ AnkiConnect đã cấu hình.

## Lời cảm ơn

Fushi được xây dựng dựa trên các dự án và hệ sinh thái sau:

| Dự án | Mô tả |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Công cụ học tiếng Nhật chuyên sâu |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Trình đọc tiếng Nhật cho iOS; tham chiếu engine phân trang |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Trình đọc tiếng Nhật native cho Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Engine từ điển C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Giải pháp đồng bộ sách nói |
| [Yomitan](https://github.com/yomidevs/yomitan) | Tham chiếu định dạng từ điển, bảng biến đổi và trải nghiệm tra từ |
| [Lapis](https://github.com/donkuri/lapis) | Loại ghi chú Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Tích hợp tạo thẻ trên Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Tham chiếu âm thanh cục bộ và tương tác với AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Tham chiếu khả năng tương thích trình đọc, thống kê và đồng bộ |
| [media_kit](https://github.com/media-kit/media-kit) | Framework phát video cho Flutter (lõi libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Bộ công cụ học ngôn ngữ chuyên sâu cho macOS |

## Giấy phép

Phân phối theo Giấy phép Công cộng GNU phiên bản 3.0 (GNU General Public License v3.0). Xem [LICENSE](../../LICENSE) để biết chi tiết.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | **Tiếng Việt** | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
