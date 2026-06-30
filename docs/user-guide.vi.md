# Hướng dẫn sử dụng hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | **Tiếng Việt** | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Hướng dẫn tiếng Trung giản thể được lưu trữ trên Feishu (liên kết ở trên). Hướng dẫn tiếng Anh cũng có sẵn [trên GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## Giới thiệu

Đây là phần mềm miễn phí cho Android / Windows (iOS / macOS đang được lên kế hoạch) — một ứng dụng mã nguồn mở đa nền tảng mang tính đột phá, kết hợp việc đọc tiểu thuyết, phát sách nói, phát video và tra cứu từ điển.

### URL dự án

https://github.com/hajisensai/hibiki

Đang được phát triển tích cực — phản hồi của bạn sẽ được xử lý nhanh chóng. Hoan nghênh các báo cáo lỗi và yêu cầu tính năng. Nếu bạn thấy Hibiki hữu ích, chúng tôi rất cảm kích nếu bạn chia sẻ nó với người khác hoặc để lại một ⭐ cho kho lưu trữ.

### Tải xuống

https://github.com/hajisensai/hibiki/releases/latest

Android: chọn **arm64**. Windows: chọn tệp **.exe**.

## Hướng dẫn cấu hình

### 1. Nhập các từ điển được đề xuất và âm thanh cục bộ (tùy chọn)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

Trong ứng dụng: Cài đặt -> Đồng bộ & Sao lưu -> nhấn **Nhập bản sao lưu**.

**Lưu ý: nhập bản sao lưu sẽ xóa dữ liệu cục bộ. Quy trình này sẽ được cải thiện trong bản cập nhật tương lai.**

![Màn hình nhập bản sao lưu](static-assets/user-guide/import-backup.png)

### 2. Tải xuống và cấu hình Anki từ trang web chính thức của Anki

Anki — được đặt tên theo 暗記 (あんき) — là [hệ thống lặp lại ngắt quãng (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) được sử dụng rộng rãi nhất trên thế giới, và là một công cụ rất quan trọng.

Liên kết: [Trang chính thức của Anki](https://apps.ankiweb.net/) · [Sổ tay (tiếng Trung)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [Câu hỏi thường gặp](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(tiếng Trung)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Hình ảnh: minh họa / chú giải]*

Bạn có thể đưa cho Anki bất kỳ tài liệu nào bạn muốn ghi nhớ, và nó giúp bạn đạt được khả năng ghi nhớ tốt nhất với thời gian học ít nhất.

Anki tích hợp sẵn [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) — một trong những thuật toán lặp lại ngắt quãng tốt nhất thế giới.

**NHƯNG!!!** Thuật toán mặc định của Anki là SM2, một thuật toán đã hơn 30 năm tuổi và hoạt động kém. Hãy chắc chắn chuyển thuật toán mà Anki sử dụng sang **FSRS**.

#### Anki

##### Android

1. Cài đặt và mở Anki.
2. Quay lại hibiki, vào Cài đặt -> Tạo thẻ.
3. Nhấn **Làm mới bộ thẻ và loại ghi chú** (được đánh dấu "1" trong hình); hibiki sẽ yêu cầu quyền — nhấn Cho phép.
4. Nhấn **Tạo bộ thẻ Lapis** (được đánh dấu "2" trong hình).
5. Nếu không có cảnh báo hay lỗi màu đỏ, thiết lập đã thành công.

![Thiết lập Anki trên Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Cài đặt và mở Anki.
2. Nhấp vào **Công cụ (Tools)** ở góc trên bên trái.

![Menu Công cụ của Anki trên Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Dán mã tiện ích bổ sung Anki bên dưới để cài đặt: `2055492159`
4. Quay lại hibiki, vào Cài đặt -> Tạo thẻ.
5. Nhấn **Làm mới bộ thẻ và loại ghi chú** (đánh dấu "1").
6. Nhấn **Tạo bộ thẻ Lapis** (đánh dấu "2").
7. Nếu không có cảnh báo hay lỗi màu đỏ, thiết lập đã thành công.

![Thiết lập Anki trên Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Xem qua các tùy chọn trong phần Cài đặt và kiểm tra xem có điều gì bạn muốn điều chỉnh không. (Tùy chọn)

## Lời cảm ơn

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
