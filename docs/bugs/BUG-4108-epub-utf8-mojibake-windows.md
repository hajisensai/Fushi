## BUG-4108 · Windows 中文系统上 EPUB 正文 UTF-8 弯引号显示成「鈥檛」：WebView2 拦截响应丢了 charset

- **报告**：2026-11-04（应用内反馈 ktWIKsgWIz，Windows 10 IoT LTSC 2024，zh-CN，3.3.0-debug.23080）
- **真实性**：✅ 真 bug。截图是英文 EPUB，`didn’t` 显示成「didn鈥檛」、`“` / `”` 显示成「鈥」+「�」：`’t` 的 UTF-8 字节 `E2 80 99 74` 按 GBK 解就是「鈥」「檛」，即 **UTF-8 字节被按 GBK 解码**，不是字体也不是解压问题（Dart 侧 `decodeEpubText` 一律按 UTF-8 解、sanitize 后再以 UTF-8 重编码，下发字节正确）。
  根因 `packages/flutter_inappwebview_windows/windows/types/web_resource_response.cpp:70`（修复前）：platform interface 的 `contentEncoding` 是**字符集**（Android `WebResourceResponse(mimeType, encoding, data)` 的 `encoding`、iOS `URLResponse.textEncodingName`），Windows fork 却把它发成 HTTP `Content-Encoding: utf-8` 头，`Content-Type` 只有裸 `text/html`。阅读器 `fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:316` 下发章节时写的 `contentEncoding: 'utf-8'` 因此从未到达 WebView2；章节只靠 `<?xml encoding="utf-8"?>` 标编码（以 `text/html` 下发时 HTML 解析器不认 XML 声明）、又没有 `<meta charset>` 时，WebView2 退回系统 ANSI 码页（zh-CN = GBK）。`custom_scheme_response.cpp:52` 同病；Linux fork `in_app_webview.cc` 的 `webkit_uri_scheme_request_finish` 也只传裸 media type。日本区系统同理会按 Shift_JIS 解。
- **[x] ① 已修复** — 在 fork 里把 `contentEncoding` 按字符集语义落进 Content-Type 的 `charset=` 参数（HTML 规范里传输层 charset 优先于 `<meta>` 预扫描，书里写错的 meta 也压得住）：
  - 新增 `packages/flutter_inappwebview_windows/windows/utils/content_type.h` `contentTypeWithCharset(type, charset)`：类型为空 / charset 为空 / 插件约定的 `binary`（= 无文本字符集）/ 类型已显式带 `charset=` 时原样返回，否则追加 `; charset=<charset>`。
  - `web_resource_response.cpp` / `custom_scheme_response.cpp`：Content-Type 经 `contentTypeWithCharset`，删掉错误的 `Content-Encoding` 头。
  - Linux fork 同构：`linux/utils/content_type.h`（实现逐字相同），`in_app_webview.cc` custom scheme 的 media type 经 `contentTypeWithCharset`。
  - 记入 `packages/flutter_inappwebview_windows/PATCHES.md`。
- **[x] ② 已加自动化测试** — `fushi/test/build/webview_response_charset_guard_test.dart`：
  - 源码守卫：两份 Windows response 不得再出现 `L"Content-Encoding"`、Content-Type 必须经 `contentTypeWithCharset`；Linux finish 不得传裸 `response->contentType.c_str()`；两份 `content_type.h` 实现逐字相同、纯 ASCII（MSVC 以 936 码页 + `/WX` 编译，非 ASCII 注释触发 C4819 直接编不过——本次实测踩到）；阅读器对 text/* 声明 `utf-8`。
  - 编码样本：只有 XML 声明、无 `<meta charset>`、含 `’` `“” …` 的 UTF-8 章节过 `ReaderResourceSanitizer.buildChapterHtmlBytes`，输出必须是严格合法 UTF-8（声明 `charset=utf-8` 的前提），且 `’t` 字节为 `E2 80 99 74`（反证截图里的 GBK 误解码）。
  - `contentTypeWithCharset` 的真值表（追加 / 空 charset / `binary` / 已带 `Charset=` / 空类型）本机用 MSVC `/std:c++17 /W4 /WX` 独立编译跑过 7 条断言全过；fork 无 C++ 测试工程，CI 不跑。
- **备注**：未在真机 / Windows app 里复测原 EPUB（本轮不做）。缺原书：用户书里章节大概率只有 XML 声明，没有 `<meta charset>`；带 meta 的书本来就不受影响。
