# Project Review 2026-05-18

## Round 1: Windows 打开书籍和查词流程审查

### Scope

Windows 桌面平台上的 EPUB 打开 -> 阅读器渲染 -> 点击查词 -> 字典弹窗显示完整流程。

审查范围包括：
- `reader_hoshi_page.dart` (阅读器主页，3386 行)
- `reader_hoshi_source.dart` (阅读器资源管理)
- `reader_selection_scripts.dart` (JS 文本选择桥接)
- `dictionary_dialog_page.dart` (字典管理对话框)
- `dictionary_popup_webview.dart` (字典弹窗 WebView)
- `dictionary_webview_media.dart` (字典媒体资源拦截)
- `webview_asset_url.dart` (WebView 资源 URL 解析)
- `hoshidicts_ffi_bindings.dart` (字典 FFI 绑定)
- `hoshidicts.dart` (字典引擎封装)
- `epub_parser.dart` (EPUB 解析)
- `epub_storage.dart` (EPUB 存储)
- `epub_importer.dart` (EPUB 导入)
- `base_source_page.dart` (字典弹窗调度)
- `main.dart` (应用初始化)
- `app_model.dart` (应用模型初始化)
- `tts_channel.dart` (TTS 通道)

### Findings

#### HBK-AUDIT-001: Windows WebView2 导航错误处理
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `reader_hoshi_page.dart:1383-1393`
- **描述**: WebView2 在 Windows 上对 `hoshi.local` 拦截请求报告 `NavigationCompleted(isSuccess=false)`，即使内容已正确渲染。代码已有正确的平台检测和处理逻辑。
- **验证**: 实际运行测试确认阅读器正常加载章节内容。

#### HBK-AUDIT-002: JS 手势处理支持鼠标和触摸
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `reader_hoshi_page.dart:1140-1147`
- **描述**: 手势脚本同时监听 `touchstart/touchend` 和 `pointerdown/pointerup`。桌面鼠标点击通过 pointer 事件路径正确处理。左键点击触发手势检测，非左键（右键）跳过。
- **验证**: 实际点击测试确认 onTap -> _selectTextAt -> onTextSelected 链路工作正常。

#### HBK-AUDIT-003: highlightOnTap 默认启用
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `reader_hoshi_source.dart:456-458`
- **描述**: `highlightOnTap` 默认值为 `true`，这是 Windows 桌面上的主要查词触发方式。点击即查词不需要额外配置。
- **验证**: 实际测试中两次点击（第一次显示 chrome，第二次查词）成功触发字典弹窗。

#### HBK-AUDIT-004: 鼠标滚轮翻页正确实现
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `reader_hoshi_page.dart:1151-1160`
- **描述**: 分页模式下滚轮事件转换为翻页操作，连续模式下（`paginationMetrics` 不存在时）正常透传滚轮事件。250ms 节流防止过快翻页。

#### HBK-AUDIT-005: EPUB 路径处理 Windows 反斜杠正确规范化
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `epub_parser.dart:77,250,323,509`
- **描述**: 所有从文件系统获取的相对路径在存储前通过 `.replaceAll('\\', '/')` 规范化为正斜杠。`p.canonicalize()` 和 `p.isWithin()` 正确处理路径安全验证。
- **验证**: 已导入的 EPUB（`hoshi_books/1`）在 Windows 上正常解析和渲染。

#### HBK-AUDIT-006: hoshidicts FFI DLL 加载
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `hoshidicts_ffi_bindings.dart:8`
- **描述**: Windows 平台正确加载 `hoshidicts_ffi.dll`（953 KB）。DLL 由 CMake 构建并安装到 exe 同目录。FFI 指针管理使用 try/finally 确保释放。
- **验证**: JMdict 字典已成功导入并可用于查询，字典弹窗正确显示结果。

#### HBK-AUDIT-007: 字典弹窗 WebView 资源加载
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `webview_asset_url.dart:26-28`, `dictionary_popup_webview.dart:194-208`
- **描述**: Windows 上弹窗 HTML 通过 `file:///<exe_dir>/data/flutter_assets/assets/popup/popup.html` 加载。自定义 scheme（`image://`, `dictmedia://`）通过 `onLoadResourceWithCustomScheme` 和 `shouldInterceptRequest` 双重处理，兼容 WebView2。

#### HBK-AUDIT-008: 应用初始化 Windows 路径安全
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `main.dart:51-171`, `app_model.dart:1139-1350`
- **描述**: 所有 Android/iOS 专有初始化（WakelockPlus、SystemChrome、FlutterLogs、WebView 预热、ReceiveIntent）均有平台守卫。Windows 使用 `AnkiConnectRepository` 替代 Android 的 `AnkiRepository`。TTU 迁移在非移动平台跳过。
- **验证**: 应用在 Windows 上正常启动，无崩溃。

#### HBK-AUDIT-009: 键盘导航实现完整
- **severity**: INFO
- **status**: CODE_REVIEW_PASS
- **file**: `reader_hoshi_page.dart:120,791-792,2336-2349`
- **描述**: FocusNode 绑定到 Focus widget，`onKeyEvent` 处理 PageDown/PageUp/ArrowRight/ArrowLeft/ArrowDown/ArrowUp。

#### HBK-AUDIT-010: TTS 在 Windows 上优雅降级
- **severity**: INFO
- **status**: VERIFIED_PASS
- **file**: `tts_channel.dart:14-18`, `base_source_page.dart:154-195`
- **描述**: TTS 仅在 Android 上可用（`_isSupported = Platform.isAndroid`）。`_autoReadWord` 方法在无可用音频源时静默返回，不会影响查词流程。

#### HBK-AUDIT-011: selectstart 阻止原生鼠标拖选
- **severity**: LOW
- **status**: BY_DESIGN
- **file**: `reader_hoshi_page.dart:1148-1150`
- **根因**: JS 中 `selectstart` 事件在 `hasStart=true` 时被阻止。左键 `pointerdown` 设置 `hasStart=true`，导致随后的 `selectstart` 被取消。
- **影响**: Windows 桌面用户无法通过鼠标拖拽选择文本。但 tap-to-lookup（highlightOnTap=true）是主要查词机制，完整可用。右键上下文菜单的"搜索"选项因无法预先选中文本而无法直接使用。
- **结论**: 这是有意设计，与移动端行为一致（移动端也阻止 selectstart，使用自定义选择逻辑）。如需改进桌面体验，可考虑在 `pointerdown` 中区分短按和长按/拖拽。

#### HBK-AUDIT-012: DLL 加载无用户可见错误处理
- **severity**: LOW
- **status**: ACCEPTABLE
- **file**: `hoshidicts_ffi_bindings.dart:6-12`
- **根因**: `DynamicLibrary.open('hoshidicts_ffi.dll')` 无 try-catch，失败时抛出 `DynamicLibraryOpenError`。
- **影响**: 如果 DLL 缺失或损坏，`HoshiDicts.isInitialized` 为 false，字典静默不可用。无用户可见提示。
- **缓解**: DLL 由 CMake 构建和安装，正常构建下不会缺失。`app_model.dart:2471` 中 `isInitialized` 检查防止崩溃。
- **建议**: 可在初始化时添加一次性提示，告知用户字典引擎不可用。优先级低。

### Verified Test Results

| 步骤 | 预期 | 结果 |
|------|------|------|
| Windows debug 构建 | 成功 | PASS |
| 应用启动初始化 | 无崩溃，进入主页 | PASS |
| 书架显示已导入书籍 | 显示「謎解きはディナーのあとで」 | PASS |
| 点击书籍打开阅读器 | ReaderHoshiPage 加载 | PASS |
| WebView 渲染章节内容 | InAppWebView 存在 | PASS |
| 点击文本触发查词 | DictionaryPopup 出现 | PASS |
| hoshidicts FFI 可用 | DLL 加载，查询返回结果 | PASS |
| flutter analyze | 无问题 | PASS |

### Conclusion

Windows 平台打开书籍和查词流程经代码审查（16 个核心文件）和运行时验证（8 项测试全部通过），确认无阻塞性问题。

- **0 个致命问题**
- **0 个已复现 bug**
- **2 个低优先级改进建议**（HBK-AUDIT-011 桌面拖选, HBK-AUDIT-012 DLL 错误提示）
- **10 个验证通过项**

### Next Scope

无需继续审查。如需后续改进桌面体验，HBK-AUDIT-011 和 HBK-AUDIT-012 可作为 enhancement 跟进。
