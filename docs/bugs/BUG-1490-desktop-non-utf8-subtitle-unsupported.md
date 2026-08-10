## BUG-1490 · 桌面端非 UTF-8 字幕全被误报为不支持
- **报告**：2026-08-10（用户：Windows 端加载 `[VCB-Studio&philosophy-raws] kiss×sis [07][…].tc.ass` 提示「不支持」）
- **真实性**：✅ 真 bug，已在 `flutter test` 宿主（与桌面端同为「无插件实现」环境）实测复现：
  `MissingPluginException(No implementation found for method autoDecode on channel flutter_charset_detector)`，
  栈顶 `packages/fushi_audio/lib/src/parsers/text_file_io.dart:17`。

### 根因链（四环，缺一不成立）
1. **样本是 UTF-16LE with BOM**：hexdump 首字节 `ff fe`，其后每个 ASCII 字符跟一个 `00`。
   内容是正常的 `[Script Info]` ASS 脚本（52164 字节 / 319 条 Dialogue）。
2. **`utf8.decode` 严格解码抛 `FormatException`**：`packages/fushi_audio/lib/src/parsers/text_file_io.dart:15`。
3. **退路 `CharsetDetector.autoDecode` 在桌面端根本没有实现**：
   `flutter_charset_detector` 1.0.2 的 pubspec 只声明 `flutter.plugin.platforms.{android,ios}`，
   pub cache 里也只有 `flutter_charset_detector_android` / `_ios` 两个联邦包。
   Windows / macOS / Linux 落回 `MethodChannelCharsetDetector`，`invokeMethod` 必抛
   `MissingPluginException`（`text_file_io.dart:17`）。
4. **`catch (_)` 把异常压成空 cue 列表**：`fushi/lib/src/media/video/video_subtitle_source.dart:1235`
   `catch (_) { return const <AudioCue>[]; }`，无日志、无分类。空列表在
   `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart:1032` 触发
   `t.video_subtitle_load_failed`，中文文案是「无法加载该字幕（可能是**图形或不支持**的字幕轨）」
   —— 用户读到的「不支持」出自这里，**不是** `video_subtitle_import_unsupported`
   （那条对 `.ass` 结构性不可达：FilePicker 白名单与 `subtitleFormatForPath` 同集合）。

### 爆炸半径（不是单个文件的问题）
`readTextWithEncoding` 是 8 个子系统的共用入口：字幕 parser（srt/vtt/ass/lrc/smil/json-alignment）、
外挂/内封字幕加载、弹幕 sidecar、m3u8 播放列表、source library 扫描、txt→epub 导入、互联 host 转发。
桌面三端上**任何非 UTF-8 文本**（UTF-16 / Shift-JIS / GBK / Big5 / EUC-JP）经此入口都会抛异常，
再被各自的 `catch` 吞成「空 / 静默失败」。顺带确认的两处既有静默缺陷：
- `packages/fushi_audio/lib/src/parsers/json_alignment_parser.dart:47`：带 UTF-8 BOM 的对齐 JSON
  `jsonDecode` 直接抛（不 catch）。
- `fushi/lib/src/media/video/video_danmaku_source.dart:121`：带 BOM 的弹弹play JSON 被
  `catch (_)` 吞成 0 条弹幕。

### 修复
- **[x] ① 已修复** — 提交 `e98dc5a5b6`
  1. `packages/fushi_audio/lib/src/parsers/text_file_io.dart` 重写解码策略，**纯 Dart、零新依赖**：
     `detectEncodingFromBom`（UTF-32 LE/BE 优先于 UTF-16 LE/BE，消除 `FF FE 00 00` 与 `FF FE`
     的前缀歧义）→ `detectBomlessUtf16`（无 BOM 启发式：某奇偶位 `0x00` 占比 >30% 且另一位 <5%）
     → UTF-8 严格解码 → 平台字符集检测 → `utf8.decode(allowMalformed: true)` 兜底。
     **启发式必须排在 UTF-8 严格解码之前**：纯 ASCII 的 UTF-16LE 字节在 UTF-8 眼里全合法
     （`0x00` 是合法 NUL），旧顺序会静默产出夹满 NUL 的垃圾串而不是抛异常。
     BOM 统一在此剥除；UTF-16 用 `ByteData.getUint16` 逐 code unit 读（不用 `Uint16List.view`，
     避开宿主字节序与对齐约束），代理对经 Dart String 原样透传。
  2. `tryPlatformCharsetDecode` 把插件调用包成显式降级策略（`MissingPluginException` /
     `UnimplementedError` / `PlatformException` → null → 宽松 UTF-8），并在 doc 注释里写明
     这是上游依赖的平台覆盖缺口、影响范围与清理条件。
  3. `fushi/lib/src/media/video/video_subtitle_source.dart` 引入 `SubtitleCueLoadFailure` 四态
     （`unsupportedFormat` / `extractionFailed` / `fileUnreadable` / `parseFailed`）+
     `SubtitleCueLoadResult`，新增 `loadSubtitleCueResult`；`loadCuesForSource` 保留为丢原因的
     薄封装（其余 8 个调用方零改动）。读文件与解析的 catch 分开，各自带 `debugPrint`。
  4. `subtitle.part.dart` 主/副字幕两条选择路径改走 `loadSubtitleCueResult`，新增纯映射
     `_subtitleFailureMessage`：只有 `unsupportedFormat` / `extractionFailed` 仍说「图形或不支持的轨」，
     `fileUnreadable` / `parseFailed` 改用新 key `video_subtitle_read_failed`
     （「无法读取该字幕文件（内容损坏或为空）」）。
- **[x] ② 已加自动化测试** — 提交 `e98dc5a5b6`
  - `fushi/test/media/audiobook/text_file_io_encoding_test.dart`（33 条）：BOM 判定全枚举、
    UTF-32/UTF-16 前缀歧义、无 BOM UTF-16 启发式正负例、代理对往返、
    真文件端到端（UTF-8 / UTF-8+BOM / UTF-16LE+BOM / UTF-16BE+BOM / UTF-16LE 无 BOM /
    UTF-32LE+BOM / 非法字节降级不抛 / 空文件）、UTF-16 ASS 解析出 cue、UTF-8+BOM 对齐 JSON 可解析。
  - `fushi/test/media/video/subtitle_cue_load_failure_test.dart`（9 条）：失败原因四态分类 +
    结果不变式 + `loadCuesForSource` 向后兼容 + UI 文案分流源码守卫。
  - 变异实测（改坏源码确认变红，均用反向替换还原，未对未提交文件用 `git checkout --`）：
    禁用 UTF-32 BOM 优先 → 5 红；去掉无 BOM 启发式 → 4 红；`MissingPluginException` 改 rethrow → 1 红；
    `fileUnreadable` 误标成 `parseFailed` → 1 红；文案映射改回旧 key → 1 红。
  - 夹具是**手写的最小 UTF-16LE ASS 片段**，未把用户的 52KB 原件入库。

### 真样本验证
用户原始文件走改后的路径：52164 字节 → 26081 字符，`[Script Info]` 开头，
`startsWithBom=false / hasNul=false / hasReplacement=false`，`AssParser.parse` 得 **319 条 cue**，
`loadSubtitleCueResult` 返回 `failure=null`。

### 备注
- 未验证：桌面端真机 UI 上的实际 OSD 文案（只做了源码守卫）；移动端 Android/iOS 上
  `CharsetDetector` 仍可用时的 Shift-JIS 路径未回归实测（该分支未改语义，只多了前置的
  Unicode 判定，而 Shift-JIS 字节在 `decodeUnicodeText` 里返回 null 已有单测覆盖）。
- 桌面端 Shift-JIS / GBK / Big5 / EUC-JP 仍无法正确识别（降级为宽松 UTF-8，少数字符变 U+FFFD）。
  彻底解决需要纯 Dart 的字符集检测实现或上游补齐桌面端，属独立后续项。
