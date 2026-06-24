<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>Đọc một cuốn sách, biến mỗi từ mới thành của riêng bạn.</b></p>
<p align="center">Trình đọc chuyên sâu đa nền tảng, đa ngôn ngữ —— Đọc EPUB · Chạm để tra từ · Tạo thẻ Anki · Đồng bộ sách nói · Tra từ trên phụ đề video</p>

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
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 Trang dự án (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <b>Tiếng Việt</b> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Giới thiệu

**hibiki** là trình đọc chuyên sâu đa nền tảng để học ngôn ngữ. Trong nội dung của một cuốn EPUB, bạn có thể **chạm để tra từ điển và chọn để phân tích**, biến mỗi từ mới thành thẻ Anki chỉ với một chạm; đồng bộ âm thanh sách nói với văn bản, làm nổi bật theo từng câu; thậm chí tra từ và tạo thẻ trực tiếp ngay trên phụ đề video. Một công cụ duy nhất cho cả ba hình thức tiếp nhận chuyên sâu: «đọc · nghe · xem».

Việc tra cứu từ điển bao phủ **toàn bộ ngôn ngữ biến đổi** của [Yomitan](https://github.com/yomidevs/yomitan) (khử biến cách + chuẩn hóa văn bản trước khi tra), giao diện được bản địa hóa sang **17 ngôn ngữ** và hỗ trợ năm nền tảng **Android / iOS / macOS / Windows / Linux**.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="Kệ sách" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="Tra từ" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="Cài đặt và giao diện" width="300">
</p>
<p align="center"><sub>Kệ sách · Tra từ · Cài đặt và giao diện</sub></p>

---

## Tính năng nổi bật

### 📖 Đọc EPUB, chạm để tra

Trình đọc EPUB hiển thị trong WebView (engine phân trang phái sinh từ [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)): chạm vào bất kỳ từ nào để tra ngay lập tức, chọn một đoạn văn bản để phân tích tức thì. Hai chế độ cuộn liên tục và phân trang, phông chữ và giao diện tùy chỉnh (sáng / tối / đen tuyền / tùy chỉnh), furigana, thống kê đọc và đánh dấu trang đều có đủ.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="Đọc dọc · Furigana · Đồng bộ sách nói" width="300">
</p>
<p align="center"><sub>Văn bản dọc · Furigana · Tô sáng vùng chọn · Thanh điều khiển sách nói ở dưới</sub></p>

### 🔍 Chạm để tra, bao phủ toàn bộ ngôn ngữ biến đổi của Yomitan

Nhập từ điển ở nhiều định dạng: **Yomitan** (trước đây là Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku**. Chuyển dạng từ vựng đa ngôn ngữ (bảng biến đổi Yomitan) + chuẩn hóa văn bản trước khi tra (hoa/thường / dấu phụ / harakat tiếng Ả Rập), vận hành theo điểm mã và không cần chuyển ngôn ngữ. Tra cứu song song nhiều từ điển, ưu tiên và bật/tắt nguồn con, chú thích thanh điệu và tần suất từ, tất cả trong một cửa sổ bật lên.

### 🎴 Tạo thẻ Anki chỉ một chạm

Tra được từ mới, xuất một bước sang [AnkiDroid](https://github.com/ankidroid/Anki-Android) và AnkiConnect. Tích hợp sẵn schema loại ghi chú [Lapis](https://github.com/donkuri/lapis) (vendored 1.7.0): bạn có thể tạo mẫu thẻ và bộ thẻ ngay trong ứng dụng; tự động điền câu ngữ cảnh, hỗ trợ ghi âm và cắt ảnh chụp màn hình, nhiều cấu hình xuất (Profile), ánh xạ trường tùy chỉnh, và thao tác nhanh để tạo thẻ trong một bước.

### 🎧 Đồng bộ sách nói (Sasayaki)

Hỗ trợ phụ đề SRT / LRC / VTT / ASS, tự động căn chỉnh văn bản phụ đề với nội dung EPUB. Khi phát **tô sáng văn bản theo nhịp đọc và lật trang đồng bộ với âm thanh**, kết hợp thanh điều khiển phát lại (tiến trình, tua, tốc độ): khi nghe, văn bản sáng lên theo từng câu —— thanh điều khiển ở dưới ảnh chụp màn hình đọc ở đầu trang này chính là tính năng này.

### 🎬 Tra từ trên phụ đề video

Trình phát video tích hợp dựa trên media_kit / libmpv, hỗ trợ phụ đề nhúng / phụ đề ngoài. Khi phát video, bạn có thể **tra từ và tạo thẻ trực tiếp ngay trên phụ đề**, đưa cả tư liệu phim ảnh vào nguồn tiếp nhận chuyên sâu; đồng thời thống kê thời lượng xem và số thẻ đã tạo.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 Ảnh chụp màn hình trình phát video sẽ được bổ sung.</sub></p>

### 🔗 Khác

- **17 ngôn ngữ giao diện**, bản địa hóa trên mọi nền tảng
- **Hibiki Interconnect**: đồng bộ sách / từ điển / sách nói / tiến độ đọc giữa các thiết bị
- **Nhiều hồ sơ người dùng (Profile)**, tự động chuyển đổi theo sách
- **Chế độ ẩn danh**; **chia sẻ văn bản từ ứng dụng khác để tra trực tiếp**

---

## Nền tảng hỗ trợ

| Nền tảng | Trạng thái | Hiển thị / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material (hiển thị EPUB qua bản fork `flutter_inappwebview_windows`) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> Tối thiểu Android 7.0 (API 24). Ngôn ngữ tra cứu từ điển do các từ điển đã nhập và bảng biến đổi Yomitan quyết định, độc lập với ngôn ngữ giao diện.

### Ngôn ngữ giao diện (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## Cài đặt và biên dịch

Chuẩn bị bằng một lệnh (`flutter pub get` + áp dụng bản vá), sau đó biên dịch:

```bash
# tại thư mục gốc của kho
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` gom ① `flutter pub get` và ② `ci/apply-patches.sh` vào một lệnh. Dự án này được khóa ở Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); một số phụ thuộc upstream được vendor vào `third_party/` hoặc được `ci/apply-patches.sh` vá —— chi tiết cơ chế, biên dịch trên năm nền tảng và danh sách phụ thuộc/bản vá xem [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Tổng quan công nghệ</b></summary>

| Tầng | Công nghệ |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Nền tảng | Android / iOS / macOS / Windows / Linux (thích ứng Material 3 + Cupertino) |
| Trình đọc | Engine phân trang WebView (phái sinh từ [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Video | media_kit / libmpv |
| Lưu trữ | Drift (SQLite, WAL) + hoshidicts (engine từ điển C++ FFI) |
| NLP | Bảng biến đổi Yomitan (chuyển dạng từ vựng đa ngôn ngữ) + kana_kit (chuyển đổi kana); phân tách từ qua hoshidicts FFI |
| Tạo thẻ | AnkiDroid API + AnkiConnect |
| Quốc tế hóa | Slang (17 ngôn ngữ) |

</details>

<details>
<summary><b>Cấu trúc dự án</b></summary>

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
├── native/                  # Engine từ điển C++ hoshidicts (FFI)
├── third_party/             # Gói vá vendored (dependency_overrides trỏ tới)
├── ci/                      # Script vá biên dịch và kiểm thử tích hợp
├── tool/                    # Script bootstrap / i18n_sync, v.v.
└── docs/                    # Tài liệu phát triển (gồm sổ tay thao tác agent docs/agent/)
```

</details>

---

## Lời cảm ơn

| Dự án | Mô tả |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Công cụ học tiếng Nhật chuyên sâu |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Trình đọc tiếng Nhật cho Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Engine từ điển C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Trình đọc tiếng Nhật cho iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Phương án đồng bộ sách nói |
| [Yomitan](https://github.com/yomidevs/yomitan) | Nguồn định dạng từ điển và bảng biến đổi |
| [Lapis](https://github.com/donkuri/lapis) | Loại ghi chú Anki |

## Giấy phép

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <b>Tiếng Việt</b> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
