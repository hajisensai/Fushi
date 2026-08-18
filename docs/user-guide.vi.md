# Hướng dẫn Fushi mà đến Yui Hirasawa cũng cài đặt xong trong 5 phút

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | **Tiếng Việt** | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Hướng dẫn tiếng Trung giản thể được lưu trữ trên Feishu (liên kết ở trên). Hướng dẫn tiếng Anh cũng có sẵn [trên GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## Giới thiệu

**Fushi — biến việc đọc ngấu nghiến và xem ngấu nghiến thành đầu vào ngôn ngữ.**

Chạm vào bất kỳ từ nào để tra cứu trong khi bạn đọc tiểu thuyết, xem anime hoặc nghe sách nói, và gửi từ mới sang Anki cùng với câu chứa nó.

Không có danh sách từ vựng dựng sẵn — bạn chỉ ôn lại những từ mà bạn thực sự gặp phải. Hoạt động với mọi ngôn ngữ.

- 📖 Đọc EPUB · chạm để tra từ
- 🎧 Sách nói với tô sáng theo từng câu
- 🎬 Tra cứu phụ đề video và tạo thẻ
- 🃏 Tạo thẻ Anki chỉ với một chạm + thống kê ôn tập
- 📚 Đọc manga · tra từ ngay trên trang truyện bằng OCR
- ⬇️ Tải anime và manga ngay trong ứng dụng chỉ với một chạm — tự động thêm vào thư viện của bạn, và xem được ngay cả khi vẫn đang tải
- 🎮 Khai thác lồng tiếng Galgame (Windows) · câu thoại lồng tiếng gốc được đưa vào thẻ cùng với văn bản

Nền tảng: Android / Windows / macOS / iOS (Linux có thể build từ mã nguồn; chưa có gói dựng sẵn)

### URL dự án

https://github.com/hajisensai/Fushi

Đang được phát triển tích cực — phản hồi của bạn sẽ được xử lý nhanh chóng. Hoan nghênh các báo cáo lỗi và yêu cầu tính năng. Nếu bạn thấy Fushi hữu ích, chúng tôi rất cảm kích nếu bạn chia sẻ nó với người khác hoặc để lại một ⭐ cho kho lưu trữ.

### Tải xuống

https://github.com/hajisensai/Fushi/releases/latest

Chọn tệp phù hợp với nền tảng của bạn: **Android** — tệp APK `arm64-v8a` (mọi điện thoại trong vài năm gần đây đều dùng loại này; chỉ các thiết bị cũ hơn mới cần `armeabi-v7a`, còn trình giả lập dùng `x86_64`); **Windows** — `windows-setup.exe`; **macOS** — `macos.zip`; **iOS** — `ios.ipa`. **Linux** chưa có gói dựng sẵn, nên phải build từ mã nguồn.

Các tệp APK có tên bắt đầu bằng `bridge-` là cầu nối chuyển đổi dành cho **người dùng Hibiki cũ**; bạn có thể bỏ qua chúng.

## Hướng dẫn cấu hình

### 1. Nhập các từ điển được đề xuất (từ điển từ vựng + trọng âm cao độ + tần suất) và âm thanh cục bộ (cơ sở dữ liệu âm thanh tiếng Nhật và tiếng Anh) (Rất khuyến khích cho người mới!!! · tùy chọn)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Tải xuống qua Cloudflare (9,5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

Trong ứng dụng: Cài đặt -> Đồng bộ & Sao lưu -> nhấn **Nhập bản sao lưu**.

![Màn hình nhập bản sao lưu](static-assets/user-guide/import-backup.png)

### 2. Tải xuống và cấu hình Anki từ trang web chính thức của Anki

Anki — được đặt tên theo 暗記 (あんき) — là [hệ thống lặp lại ngắt quãng (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) được sử dụng rộng rãi nhất trên thế giới, và là một công cụ rất quan trọng.

Liên kết: [Trang chính thức của Anki](https://apps.ankiweb.net/) · [Sổ tay (tiếng Trung)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [Câu hỏi thường gặp](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(tiếng Trung)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Trang tải xuống Anki](static-assets/user-guide/anki-download.png)

Bạn có thể đưa cho Anki bất kỳ tài liệu nào bạn muốn ghi nhớ, và nó giúp bạn đạt được khả năng ghi nhớ tốt nhất với thời gian học ít nhất.

Anki tích hợp sẵn [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) — một trong những thuật toán lặp lại ngắt quãng tốt nhất thế giới.

**NHƯNG!!!** Thuật toán mặc định của Anki là SM2, một thuật toán đã hơn 30 năm tuổi và hoạt động kém. Hãy chắc chắn chuyển thuật toán mà Anki sử dụng sang **FSRS**.

#### Anki

##### Android

1. Cài đặt và mở Anki.
2. Quay lại Fushi, vào Cài đặt -> Tạo thẻ.
3. Nhấn **Làm mới bộ thẻ và loại ghi chú** (được đánh dấu "1" trong hình); Fushi sẽ yêu cầu quyền — nhấn Cho phép.
4. Nhấn **Tạo bộ thẻ Lapis** (được đánh dấu "2" trong hình).
5. Nếu không có cảnh báo hay lỗi màu đỏ, thiết lập đã thành công.

![Thiết lập Anki trên Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Cài đặt và mở Anki.
2. Nhấp vào **Công cụ (Tools)** ở góc trên bên trái.

![Menu Công cụ của Anki trên Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Dán mã tiện ích bổ sung Anki bên dưới để cài đặt: `2055492159`
4. Quay lại Fushi, vào Cài đặt -> Tạo thẻ.
5. Nhấn **Làm mới bộ thẻ và loại ghi chú** (đánh dấu "1").
6. Nhấn **Tạo bộ thẻ Lapis** (đánh dấu "2").
7. Nếu không có cảnh báo hay lỗi màu đỏ, thiết lập đã thành công.

![Thiết lập Anki trên Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Xem qua các tùy chọn trong phần Cài đặt và kiểm tra xem có điều gì bạn muốn điều chỉnh không. (Tùy chọn)

Đã đến lúc bắt đầu đắm chìm.

## Tính năng được đề xuất

### Tra từ bên ngoài ứng dụng

**Android:** chọn một từ, rồi nhấn **Dịch** hoặc **Fushi** trong menu chọn văn bản.

**Windows:** chọn một từ, rồi nhấn **Ctrl+Alt+D** (có thể đổi phím tắt trong Cài đặt -> Phím tắt).

### Tra từ từ bộ nhớ tạm

Mọi thứ bạn sao chép đều được tra cứu tự động. Có hai chế độ hiển thị — **bảng nổi** và **cửa sổ văn bản trong suốt** — cả hai đều cấu hình được trong Cài đặt -> Tra cứu.

### Tra từ trên trình duyệt / khai thác phụ đề dịch vụ phát trực tuyến (Netflix)

Cài đặt tiện ích mở rộng trình duyệt từ trang chủ của Fushi.

## Lời cảm ơn

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
