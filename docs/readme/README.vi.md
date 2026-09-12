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
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Material Design 3 |

> Tối thiểu Android 7.0 (API 24). Các ngôn ngữ khả dụng để tra từ điển do các từ điển đã nhập và bảng biến đổi Yomitan quyết định, độc lập với ngôn ngữ giao diện. Bản iOS được phát hành qua TestFlight: không có các tính năng khám phá và tải xuống mà nguyên tắc App Store không cho phép, và bản cập nhật đến muộn hơn vài ngày so với các nền tảng khác.

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

### Công cụ học tập và các dự án tham khảo

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

### Engine và thành phần native

| Dự án | Mô tả |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Engine hook văn bản galgame (DLL đi kèm, do injector nạp) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Thư viện inline hook mà injector galgame sử dụng |
| [libtorrent](https://github.com/arvidn/libtorrent) | Engine tải torrent tích hợp |
| [mpv](https://github.com/mpv-player/mpv) | Lõi phát libmpv phía sau media_kit |
| [FFmpeg](https://ffmpeg.org) | Phân tích media, cắt đoạn và trích xuất âm thanh |
| [libplacebo](https://github.com/haasn/libplacebo) | Shader video GPU và tone mapping HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Engine WebView dựng trình đọc EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Suy luận trên thiết bị cho nhận dạng giọng nói và OCR |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Phụ thuộc của engine từ điển |

### Mô hình chạy trên thiết bị

| Dự án | Mô tả |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Gói mô hình nhận dạng giọng nói Zipformer và bản dựng VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Mô hình nhận dạng giọng nói tiếng Nhật |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Mô hình nhận dạng giọng nói CTC đa ngôn ngữ |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Mô hình phát hiện hoạt động giọng nói |
| [manga-ocr](https://github.com/kha-white/manga-ocr) / [manga-ocr-onnx](https://huggingface.co/mayocream/manga-ocr-onnx) | Mô hình OCR cho manga |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Mô hình phát hiện văn bản và bong bóng thoại trong manga |

### Nguồn nội dung và tích hợp

| Dự án | Mô tả |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Hệ sinh thái tiện ích nguồn manga |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Runtime tiện ích mở rộng manga cho máy tính |
| [aidoku-rs](https://github.com/Aidoku/aidoku-rs) | ABI runtime nguồn manga |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Tham khảo cầu nối phụ đề streaming cho tiện ích trình duyệt |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Tham khảo kiến trúc nhận dạng và thu thập dữ liệu anime |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Tham khảo kiến trúc thông tin thư viện galgame |
| [AniDB](https://anidb.net) | Định danh anime, tập phim và tệp |
| [TMDB](https://www.themoviedb.org) | Siêu dữ liệu và hình ảnh bổ sung |
| [Jimaku](https://jimaku.cc) | Nguồn phụ đề tiếng Nhật |
| [OpenSubtitles](https://www.opensubtitles.com) | Nguồn phụ đề |

> Ứng dụng này sử dụng TMDB và các API của TMDB nhưng không được xác nhận, chứng nhận hay phê duyệt bởi TMDB.

## Giấy phép

Phân phối theo Giấy phép Công cộng GNU phiên bản 3.0 (GNU General Public License v3.0). Xem [LICENSE](../../LICENSE) để biết chi tiết.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | **Tiếng Việt** | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
