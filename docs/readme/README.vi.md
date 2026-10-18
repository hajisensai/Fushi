<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | **Tiếng Việt** | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Tải bản mới nhất](https://img.shields.io/badge/%E2%AC%87%20T%E1%BA%A3i%20b%E1%BA%A3n%20m%E1%BB%9Bi%20nh%E1%BA%A5t-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Tham gia Discord](https://img.shields.io/badge/Tham%20gia%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Nền tảng hỗ trợ

| Nền tảng | Trạng thái | Ghi chú |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) trở lên |
| Windows | ✅ | Hook văn bản và giọng nói của galgame chỉ có trên Windows |
| macOS | ✅ | Chỉ Apple Silicon; không hỗ trợ Mac Intel |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Không có khám phá, nguồn trực tuyến và trung tâm tải xuống (nguyên tắc của App Store) |
| Linux | 🔧 Tự biên dịch từ mã nguồn | Chưa có bản phát hành dựng sẵn; trình đọc EPUB cần WPE WebKit |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Máy chủ headless cho Linux / Windows / macOS kèm giao diện web — xem [packages/fushi_server](../../packages/fushi_server/README.md) |

**Hệ thống thiết kế**: mọi nền tảng mặc định dùng **Material 3 Expressive**; có thể chuyển sang hệ thống thiết kế **Cupertino** (phong cách Apple) tại *Cài đặt › Giao diện › Hệ thống thiết kế*. Khi dùng Cupertino, nền cửa sổ dùng Mica trên Windows 11 và vibrancy trên macOS (trừ khi bật tùy chọn giảm độ trong suốt hoặc độ tương phản cao của hệ thống).

> Các ngôn ngữ khả dụng để tra từ điển do các từ điển đã nhập và bảng biến đổi Yomitan quyết định, độc lập với ngôn ngữ giao diện. Bản iOS được cập nhật qua TestFlight nên đến muộn hơn vài ngày so với các nền tảng khác.

### Ngôn ngữ giao diện (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Cài đặt

Tải bản mới nhất từ [trang web Fushi](https://fushi.moe/) — có APK Android, trình cài đặt Windows và bản dựng macOS (chỉ Apple Silicon; không hỗ trợ Mac Intel); iOS được cài đặt qua [TestFlight](https://testflight.apple.com/join/j88d69jx). Linux chưa có bản phát hành ứng dụng dựng sẵn; hãy biên dịch từ mã nguồn. Fushi Server (headless) được phát hành riêng tại [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases).

> Yêu cầu Android 7.0 (API 24) trở lên.

## Biên dịch

Chuẩn bị bằng một lệnh (`flutter pub get` + áp dụng bản vá), sau đó biên dịch:

```bash
# Từ thư mục gốc của kho
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Máy tính để bàn
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Máy chủ headless (từ packages/fushi_server; dùng `dart build cli`, không dùng `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` gộp `flutter pub get` và `ci/apply-patches.sh` thành một lệnh duy nhất. Dự án này được khóa ở Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`); các phiên bản Flutter cũ hơn không thể biên dịch vì Material và Cupertino được dùng dưới dạng các gói `material_ui` / `cupertino_ui`. Một số phụ thuộc thượng nguồn được vendored trong `third_party/` hoặc được vá bởi `ci/apply-patches.sh` — xem [docs/agent/build.md](../agent/build.md) để biết chi tiết, bao gồm các phụ thuộc để biên dịch bản Linux desktop.

<details>
<summary><b>Công nghệ sử dụng</b></summary>

| Tầng | Công nghệ |
|---|---|
| Framework | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Nền tảng | Android / Windows / macOS / iOS / Linux, cùng máy chủ headless |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Trình đọc | Engine phân trang WebView (phát triển từ dòng Hoshi Reader) |
| Video | media_kit (lõi libmpv) + libplacebo |
| Lưu trữ | Drift (SQLite, WAL) + fushidicts (engine từ điển C++ FFI) |
| NLP | Bảng biến đổi Yomitan (đưa về dạng gốc đa ngôn ngữ) + kana_kit (chuyển đổi kana); tách token qua fushidicts FFI |
| AI trên thiết bị | ONNX Runtime cho nhận dạng giọng nói (tạo phụ đề) và OCR manga; thuật toán nằm ở [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Tải xuống | libtorrent 2.x qua cầu nối C-ABI FFI (qBittorrent bên ngoài làm phương án dự phòng) |
| Đồng bộ | Backend đám mây + Fushi Interconnect (LAN, địa chỉ từ xa và đường hầm P2P iroh) |
| Engine dùng chung | `fushi_engine` — lõi Dart thuần dùng chung giữa ứng dụng và Fushi Server |
| Tạo thẻ | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 ngôn ngữ) |

</details>

<details>
<summary><b>Cấu trúc dự án</b></summary>

```
Fushi/                      # Thư mục gốc của kho (Melos workspace: fushi_workspace)
├── fushi/                  # Thư mục chính của ứng dụng Flutter
│   ├── lib/
│   │   ├── i18n/            # Quốc tế hóa (17 ngôn ngữ, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Trang (thư viện, trình đọc, trình phát video, cài đặt, v.v.)
│   │   │   ├── reader/      # Script JS/CSS cho WebView của trình đọc
│   │   │   ├── media/       # Sách, manga, video, sách nói, nguồn trực tuyến
│   │   │   ├── lookup/      # Cửa sổ bật lên và lớp phủ tra từ điển
│   │   │   ├── mining/      # Tạo thẻ (gồm tạo thẻ từ galgame)
│   │   │   ├── sync/        # Đồng bộ đám mây, Interconnect, máy chủ media
│   │   │   └── models/      # Mô hình dữ liệu và quản lý trạng thái (AppModel)
│   │   └── main.dart
│   └── android/             # Dự án Android
├── packages/                # Các gói Dart
│   ├── fushi_core/          #   Schema cơ sở dữ liệu, tùy chọn
│   ├── fushi_engine/        #   Engine Dart thuần dùng chung với máy chủ
│   ├── fushi_server/        #   CLI máy chủ headless + giao diện web
│   ├── fushi_cli/           #   Ứng dụng dòng lệnh cho desktop
│   ├── fushi_dictionary/    #   Binding engine từ điển và bộ nhập
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # Binding FFI cho libtorrent / iroh
│   └── …                    #   Các bản fork vendored (inappwebview Windows/Linux, gamepads)
├── native/                  # Mã nguồn native: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Backend thu thập log và bảng xếp hạng (triển khai riêng)
├── tools/browser-extension/ # Tiện ích mở rộng trình duyệt để tra từ
├── third_party/             # Các gói đã vá được vendored (dependency_overrides)
├── ci/                      # Bản vá build và script CI
├── tool/                    # Script bootstrap / setup_worktree / theo dõi lỗi
└── docs/                    # Tài liệu phát triển (gồm sổ tay vận hành docs/agent/)
```

</details>

Nhập video hỗ trợ nhóm theo tác phẩm hoặc thư mục. Xem [quy trình video](../specs/2026-09-07-video-library-workflow.md) và [siêu dữ liệu MAL/TMDB cùng băm tệp AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md) để biết cách đối khớp và các tác vụ nền.

[Thiết lập dịch vụ trực tuyến tùy chọn](../specs/2026-09-07-online-services-setup.md) giải thích các danh tính ứng dụng đi kèm, thông tin xác thực cá nhân và lời nhắc thiết lập video có thể tắt.

## Quyền riêng tư và dữ liệu

Fushi lưu trữ sách, từ điển, phông chữ, dữ liệu sách nói, video, tiến độ đọc, vùng tô sáng, thống kê và cài đặt đã nhập trong bộ nhớ cục bộ của ứng dụng.

- **Đồng bộ**: Google Drive / OneDrive / Dropbox dùng đăng nhập OAuth; WebDAV / FTP / SFTP / Fushi Server dùng địa chỉ máy chủ và thông tin xác thực do bạn cung cấp. Fushi Interconnect kết nối trực tiếp các thiết bị đã ghép đôi (LAN, IPv6, mạng lớp phủ hoặc địa chỉ công khai) và chuyển sang đường hầm P2P iroh đầu cuối khi không có đường trực tiếp nào dùng được; liên kết ghép đôi luôn yêu cầu xác nhận.
- **Anki**: việc tạo thẻ chỉ giao tiếp với AnkiDroid hoặc địa chỉ AnkiConnect do bạn cấu hình.
- **Thống kê sử dụng**: mỗi ngày một lần, bản desktop và Android gửi tới fushi.moe một ID cài đặt ngẫu nhiên, phiên bản ứng dụng, nền tảng và kênh cập nhật để đếm người dùng hoạt động; không kèm tài khoản, thư viện hay dữ liệu đọc, và địa chỉ IP không được lưu. Tắt bằng *Chia sẻ thống kê sử dụng* trong phần cài đặt cập nhật. Bản iOS không gửi.
- **Chỉ khi bạn yêu cầu**: tải log lên (sau một lần hỏi đồng ý), phản hồi trong ứng dụng và bảng xếp hạng (mặc định tắt; chỉ tải tiêu đề thư viện và tiến độ của bạn sau khi bạn chủ động bật).
- **OCR manga**: engine mặc định là Google Lens, gửi ảnh trang tới Google; hãy chuyển sang mô hình trên thiết bị hoặc OCR của hệ thống trong cài đặt để giữ ảnh ở máy.
- **Tính năng AI**: yêu cầu chỉ được gửi tới nhà cung cấp LLM mà bạn cấu hình và gán cho một tính năng; nếu chưa gán nhà cung cấp, sẽ không có gì được gửi đi.
- **Dịch vụ bên thứ ba**: các tính năng siêu dữ liệu, phụ đề và nguồn trực tuyến chỉ liên hệ các dịch vụ được liệt kê tại [Nguồn nội dung và tích hợp](#nguồn-nội-dung-và-tích-hợp) khi bạn sử dụng chúng.

## Hoạt động phát triển

[![Hoạt động phát triển](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Công việc hằng ngày được đưa vào `develop`; `main` chỉ nhận các lần merge phát hành. Biểu đồ được hiển thị ở đây trên `main` nhưng được tạo từ `develop`, nên phản ánh hoạt động phát triển thực tế chứ không phải lưu lượng merge.

Ba làn là các kênh cập nhật mà chính ứng dụng cung cấp, và mỗi làn được co giãn theo đỉnh riêng — số bản debug nhiều hơn bản ổn định hai bậc độ lớn, nên dùng chung một thang đo sẽ làm hai làn còn lại phẳng như không có.

| Làn | Đếm gì | Cách nhận |
|---|---|---|
| **Debug (cuốn chiếu)** | Các bản dựng push thành công của [release.yml](../../.github/workflows/release.yml) | Bản phát hành thử cuốn chiếu, được phát hành lại sau mỗi lần push |
| **Beta** | Các bản phát hành thử `v<version>-beta.<seq>` | Bản thử nghiệm được kích hoạt thủ công |
| **Stable** | Các bản phát hành `v<version>` | Bản phát hành mới nhất |

> Biểu đồ trên được tạo ngay trong kho này (không dùng dịch vụ bên thứ ba) và được workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml) làm mới hằng ngày.

## Lịch sử Star

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Lịch sử Star](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> Biểu đồ trên được tạo ngay trong kho này (không dùng dịch vụ bên thứ ba) và được workflow [Update Star History](../../.github/workflows/star-history.yml) làm mới hằng ngày.

## Lời cảm ơn

Fushi được xây dựng dựa trên các dự án và hệ sinh thái sau:

### Công cụ học tập và tiền lệ

| Dự án | Mô tả |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Công cụ học tiếng Nhật theo phương pháp đắm chìm |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Trình đọc tiếng Nhật trên iOS; tham khảo engine phân trang của trình đọc |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Trình đọc tiếng Nhật native trên Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Engine từ điển C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Giải pháp đồng bộ sách nói |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Thuật toán căn thời gian phụ đề theo track tham chiếu (GPL-3.0); cơ sở để tự động căn phụ đề tải về theo các track nhúng |
| [Yomitan](https://github.com/yomidevs/yomitan) | Tham khảo định dạng từ điển, bảng biến đổi và trải nghiệm tra từ |
| [Lapis](https://github.com/donkuri/lapis) | Loại ghi chú Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Tích hợp tạo thẻ trên Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Tham khảo về âm thanh cục bộ và tương tác với AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Tham khảo khả năng tương thích về trình đọc, thống kê và đồng bộ |
| [media_kit](https://github.com/media-kit/media-kit) | Framework phát video cho Flutter (lõi libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Bộ công cụ học ngôn ngữ đắm chìm trên macOS |

### Engine và thành phần native

| Dự án | Mô tả |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Engine hook văn bản galgame (DLL vendored, được trình inject nạp) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Thư viện inline hook mà trình inject galgame sử dụng |
| [libtorrent](https://github.com/arvidn/libtorrent) | Engine tải torrent tích hợp |
| [mpv](https://github.com/mpv-player/mpv) | Lõi phát libmpv đứng sau media_kit |
| [FFmpeg](https://ffmpeg.org) | Phân tích media, cắt đoạn và trích xuất âm thanh |
| [libplacebo](https://github.com/haasn/libplacebo) | Shader video GPU và tone mapping HDR |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | Engine WebView hiển thị trình đọc EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Suy luận trên thiết bị cho nhận dạng giọng nói và OCR |
| [iroh](https://github.com/n0-computer/iroh) | Đường hầm P2P cho các kết nối Fushi Interconnect từ xa |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Các phụ thuộc của engine từ điển |

### Mô hình trên thiết bị

| Dự án | Mô tả |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Gói mô hình nhận dạng giọng nói Zipformer và bản dựng VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Mô hình nhận dạng giọng nói tiếng Nhật |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Mô hình nhận dạng giọng nói tiếng Nhật |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Mô hình nhận dạng giọng nói tiếng Nhật (CC BY-NC 4.0, tải trực tiếp từ kho Hugging Face của nó) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Mô hình nhận dạng giọng nói CTC đa ngôn ngữ |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Mô hình phát hiện hoạt động giọng nói |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Mô hình phát hiện chữ và bóng thoại trong manga |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Mô hình phát hiện khung tranh manga, huấn luyện trên [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Phát hiện và nhận dạng dòng chữ; bộ rec tinh chỉnh cho manga (huấn luyện bằng [Manga109-s](http://www.manga109.org/en/download_s.html) và [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) vận hành mô hình OCR cục bộ CTC theo từng cột |

> Mô hình phát hiện khung tranh manga và PP-OCRv6_manga được huấn luyện bằng bộ dữ liệu Manga109-s (Matsui et al. 2017; Aizawa et al. 2020), điều khoản của bộ dữ liệu này yêu cầu nêu rõ việc sử dụng nó. PP-OCRv6_manga (Apache-2.0) còn được huấn luyện thêm bằng bộ dữ liệu AnimeText, được cấp phép theo CC BY-NC-SA 4.0; ứng dụng tải mô hình đó từ kho Hugging Face của nó và không phân phối lại.

### Nguồn nội dung và tích hợp

| Dự án | Mô tả |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Hệ sinh thái tiện ích mở rộng nguồn manga |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Hệ sinh thái tiện ích mở rộng nguồn anime (extensions-lib 14–16, cùng một runtime) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Runtime tiện ích mở rộng manga cho desktop (vendored, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Tham khảo cách điều chỉnh tiện ích mở rộng Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Hệ sinh thái plugin nguồn light novel |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Máy chủ media có thể duyệt từ thư viện video |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Tham khảo cầu nối phụ đề streaming cho tiện ích mở rộng trình duyệt |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Tham khảo kiến trúc nhận diện và thu thập dữ liệu anime |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Tham khảo kiến trúc thông tin thư viện galgame |
| [AniDB](https://anidb.net) | Định danh anime, tập phim và tệp |
| [MyAnimeList](https://myanimelist.net) (qua [Jikan](https://jikan.moe)) | Siêu dữ liệu anime |
| [TMDB](https://www.themoviedb.org) | Siêu dữ liệu và hình ảnh bổ sung |
| [VNDB](https://vndb.org) | Siêu dữ liệu visual novel |
| [Jimaku](https://jimaku.cc) | Nguồn phụ đề tiếng Nhật |
| [OpenSubtitles](https://www.opensubtitles.com) | Nguồn phụ đề |

> Ứng dụng này sử dụng TMDB và các API của TMDB nhưng không được xác nhận, chứng nhận hay phê duyệt bởi TMDB.

## Giấy phép

Phân phối theo Giấy phép Công cộng GNU phiên bản 3.0 (GNU General Public License v3.0). Xem [LICENSE](../../LICENSE) để biết chi tiết.

## Người bảo trì

Fushi được bảo trì bởi [hajisensai](https://github.com/hajisensai). Trang web: [fushi.moe](https://fushi.moe). Liên hệ: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | **Tiếng Việt** | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
