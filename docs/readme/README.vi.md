<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Ứng dụng đọc tiếng Nhật chuyên sâu cho Android</p>
<p align="center">EPUB · Từ điển · Anki · Đồng bộ sách nói</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <b>Tiếng Việt</b> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Giới thiệu

**hibiki** là ứng dụng đọc sách trên Android dành cho người học tiếng Nhật.

## Tính năng

### Đọc EPUB
- Hiển thị EPUB trong WebView (engine phân trang phái sinh từ [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- Chạm để tra từ điển, chọn để phân tích
- Phông chữ tùy chỉnh, giao diện (sáng/tối)
- Thống kê đọc và đánh dấu trang
- Cuộn liên tục / chế độ phân trang

### Từ điển
- Nhập từ điển định dạng [Yomitan](https://github.com/yomidevs/yomitan) (trước đây là Yomichan)
- Hỗ trợ thanh điệu và dữ liệu tần suất
- Tra cứu song song nhiều từ điển, lịch sử tìm kiếm
- Chuyển đổi dạng Ve

### Thẻ Anki
- Xuất một chạm sang [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Tự động điền câu ngữ cảnh
- Ghi âm, cắt ảnh chụp màn hình
- Nhiều hồ sơ xuất, ánh xạ trường tùy chỉnh
- Thao tác nhanh (Quick Actions) để tạo thẻ trong một bước

### Đồng bộ sách nói (Sasayaki)
- Định dạng phụ đề: SRT / LRC / VTT / ASS
- Tự động căn chỉnh văn bản phụ đề với nội dung EPUB
- Đánh dấu đồng bộ, lật trang đồng bộ với âm thanh
- Điều khiển phát lại (tiến trình, tua, tốc độ)

### Khác
- 17 ngôn ngữ giao diện
- Nhiều hồ sơ người dùng
- Chế độ ẩn danh
- Chia sẻ văn bản từ ứng dụng khác để tra cứu

## Ngôn ngữ hỗ trợ

Giao diện hỗ trợ các ngôn ngữ sau:

| Ngôn ngữ | Mã |
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

## Công nghệ sử dụng

| Tầng | Công nghệ |
|---|---|
| Framework | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| Nền tảng | Android / iOS / macOS / Windows / Linux (thích ứng Material 3 + Cupertino) |
| Trình đọc | Engine phân trang WebView (phái sinh từ [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Lưu trữ | Drift (SQLite, WAL) + hoshidicts (engine từ điển C++ FFI) |
| NLP | Ve (chuyển đổi dạng) |
| Thẻ ghi nhớ | AnkiDroid API |
| Quốc tế hóa | Slang (17 ngôn ngữ) |
| Phiên bản tối thiểu | Android 7.0 (API 24) |

## Biên dịch

Chuẩn bị một lệnh (tự động seed `dart_defines.env` + `flutter pub get` + áp dụng bản vá), sau đó biên dịch:

```bash
# Tại thư mục gốc của kho
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # hoặc (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define-from-file=dart_defines.env
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` gom ba việc vào một lệnh: ① nếu thiếu
`hibiki/dart_defines.env` thì tự sinh từ `dart_defines.env.example` (giá trị OAuth
giả là đủ để biên dịch, chỉ sao lưu Google Drive mới cần giá trị thật); ② `flutter pub get`;
③ chạy `ci/apply-patches.sh`. `melos bootstrap` thực hiện ②③ tương tự qua post hook
(trên Windows melos có lỗi mã hóa CJK, nên dùng `tool/bootstrap.ps1`).

> **Ghi chú về bản vá:** `ci/apply-patches.sh` ghi đè các thay đổi trong `ci/patches/` lên pub cache thực tế. Mỗi lần xóa pub cache hoặc chạy lại `flutter pub get` đều phải chạy lại (bootstrap đã bao gồm bước này). Khi không tìm thấy mục tiêu bản vá nào, script sẽ bỏ qua và cảnh báo thay vì giả vờ thành công.

## Phụ thuộc và bản vá

Dự án này được khóa ở Flutter 3.41.6, một số phụ thuộc upstream chưa tương thích. Việc vá chia thành hai cơ chế: ① các gói cần làm đầu vào biên dịch, tái lập nhất quán giữa các máy được vendor trực tiếp vào `third_party/` và trỏ tới bằng `dependency_overrides` (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **không** cần vá pub-cache); ② các gói còn lại do `ci/apply-patches.sh` vá mã nguồn trong pub cache. Chi tiết cơ chế xem [docs/agent/build.md](../agent/build.md). Các bảng gập bên dưới là danh sách lịch sử phân loại theo thay đổi; với các gói trùng với cơ chế ①, bản vendored được ưu tiên.

<details>
<summary><b>Bản vá thay đổi API Flutter</b></summary>

| Gói | Thay đổi |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; thay thế `imageCache.putIfAbsent` đã bị xóa |
| `flutter_blurhash` 0.7.0 | Tương tự: `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Thêm `hide CarouselController` vào import nội bộ để tránh xung đột tên |
| `fading_edge_scrollview` 3.0.0 | Sửa nullable cho `PageView.controller` |

</details>

<details>
<summary><b>Bản vá xóa v1 Embedding</b></summary>

Flutter 3.41.6 đã xóa hoàn toàn API v1 embedding (`PluginRegistry.Registrar`). Các plugin sau cần xóa các tham chiếu liên quan:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Bản vá Gradle / Kotlin</b></summary>

| Mục tiêu | Thay đổi |
|---|---|
| `android/build.gradle` afterEvaluate | Ép buộc `compileSdk` cho các dự án con (mặc định 36, một vài 34); xóa `-Werror` |
| `audio_session` 0.1.14 | Xóa `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Sửa Kotlin null safety |
| `receive_intent` (git) | Sửa Kotlin null safety |

</details>

<details>
<summary><b>Phụ thuộc Git</b></summary>

| Gói | Nguồn |
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

## Cấu trúc dự án

```
hibiki/                      # Gốc kho (Melos workspace: hibiki_workspace)
├── hibiki/                  # Thư mục chính ứng dụng Flutter
│   ├── lib/
│   │   ├── i18n/            # Quốc tế hóa (17 ngôn ngữ, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Trang (kệ sách, trình đọc, từ điển, cài đặt, v.v.)
│   │   │   ├── reader/      # Script JS/CSS WebView của trình đọc
│   │   │   ├── media/       # Sách nói, phân tích phụ đề, reader source
│   │   │   └── models/      # Mô hình dữ liệu và quản lý trạng thái (AppModel)
│   │   └── main.dart
│   └── android/             # Dự án Android (manifest, native hoshidicts)
├── packages/                # Package nội bộ + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # Gói vá vendored (dependency_overrides trỏ tới)
├── ci/                      # Script vá biên dịch và kiểm thử tích hợp
├── tool/                    # Script bootstrap / i18n_sync, v.v.
└── docs/                    # Tài liệu phát triển (gồm sổ tay thao tác agent docs/agent/)
```

## Lời cảm ơn

| Dự án | Mô tả |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Công cụ học tiếng Nhật chuyên sâu |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Trình đọc tiếng Nhật cho Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Engine từ điển C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Trình đọc tiếng Nhật cho iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Phương án đồng bộ sách nói |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Engine hiển thị EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Phiên bản ttu do cộng đồng duy trì (SvelteKit v2), nền tảng upstream của fork hibiki |
| [Yomitan](https://github.com/yomidevs/yomitan) | Nguồn định dạng từ điển |

## Giấy phép

[GNU General Public License v3.0](../../LICENSE)
