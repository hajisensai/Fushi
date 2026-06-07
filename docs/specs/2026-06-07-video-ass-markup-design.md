# 视频字幕 ASS inline markup 解析渲染（静态可见子集，保留查词）+ 桌面鼠标自动隐藏

- 日期：2026-06-07
- 关联 bug：**BUG-105**（ASS 标签如 `{\an8}` 直接显示成控制码，应解析渲染）、**BUG-106**（桌面端视频播放鼠标不自动隐藏）
- 范围：`hibiki/lib/src/media/video/` + `packages/hibiki_audio/lib/src/parsers/`

## 1. 问题

### BUG-105 字幕标签当文本显示
用户视频字幕显示 `{\an8}（カンナ）ふわぁ~`，`{\an8}` 是 ASS override tag（顶部居中对齐），不该作为文本出现。

根因（沿真实代码路径）：
- `srt_parser.dart:161 _stripHtml` 只 `replaceAll(RegExp('<[^>]+>'), '')`，不剥 ASS `{...}` 块。
- `vtt_parser.dart:148 _stripTags` 同样只剥 `<...>`。
- 只有 `ass_parser.dart:37 _overrideTag = RegExp(r'\{[^}]*\}')` 会剥。
- 含 ASS 残留标签的外挂 `.srt`（fansub/自动生成常见）走 `SrtParser` → 标签漏出；内封 `mov_text/subrip`（`subtitleFormatForCodec` default→srt）经 ffmpeg 转 srt 保留 `{\an8}` 时同样漏出。

用户诉求升级：**不是剔除，而是解析并渲染**这些标签的语义（`\an8` 真的放到顶部、`\i1` 真的斜体）。

### BUG-106 鼠标不自动隐藏
`video_hibiki_page.dart:935 _desktopControlsTheme` 的 `MaterialDesktopVideoControlsThemeData` 未设 `hideMouseOnControlsRemoval`，media_kit 默认 `false`（`material_desktop.dart:192`），控制条 3s 后隐藏但鼠标光标常驻。

## 2. 硬约束与取舍（已与用户确认）

- **查词/制卡用的纯文本必须无标签**：overlay 逐 grapheme 渲染并逐字符可点查词，`cue.text` 一旦含标签，字符索引错位、Anki 句子混入 `\an8`。所以「纯文本 + 样式元数据」必须分离，纯文本驱动查词，样式只用于渲染。
- **方向：静态可见子集 + 保留查词**（不走 libmpv/libass 原生渲染，因为那会把字幕画进视频纹理，逐字查词与模糊沉浸全失效）。
- **支持**：几何 `\an1-9` + `\pos(x,y)`；行内 `\i \b \u \s`、`\c/\1c` 主色、`\fs` 字号、`\N \h` 换行；`{...}` 块剥离。
- **静默忽略（删标签不渲染）**：卡拉OK `\k`、动画 `\t/\move/\fad`、矢量绘图 `\p`、旋转缩放 `\frx/\fscx`、裁剪 `\clip`、描边阴影 `\bord/\shad`。`\move` 退化到起点 `\pos`。

## 3. 架构与分层

样式解析是**纯数据**（颜色用 int ARGB，不引 Flutter），放 `hibiki_audio`（纯 Dart 包）；Flutter 样式映射放 video 层。三个 parser 与 video 共用同一套「去标签→纯文本」逻辑，**保证纯文本字符索引完全一致**。

### 3.1 新增 `packages/hibiki_audio/lib/src/parsers/subtitle_markup.dart`（纯函数，纯 Dart）

```dart
/// ASS override 块解析出的几何锚点（\an1-9 解码）。
enum SubtitleVAlign { top, middle, bottom }
enum SubtitleHAlign { left, center, right }

class SubtitleAnchor {
  final SubtitleVAlign vertical;
  final SubtitleHAlign horizontal;
  const SubtitleAnchor(this.vertical, this.horizontal);
  /// \an1-9（小键盘布局）→ 锚点。
  static SubtitleAnchor fromAnCode(int an);
}

/// plainText 上 [startGrapheme, endGrapheme) 半开区间的行内样式。
class SubtitleSpan {
  final int startGrapheme;
  final int endGrapheme;
  final bool italic;
  final bool bold;
  final bool underline;
  final bool strike;
  final int? colorArgb;     // \c/\1c &HBBGGRR& → 0xFFRRGGBB；null=默认
  final double? fontSizePx; // \fs；null=默认
}

/// \pos 归一化坐标（0..1），纯 Dart（hibiki_audio 不引 dart:ui/Flutter）。
class SubtitlePos {
  final double xFraction;
  final double yFraction;
  const SubtitlePos(this.xFraction, this.yFraction);
}

class SubtitleMarkup {
  final String plainText;          // 去标签纯文本（查词/制卡用）
  final List<SubtitleSpan> spans;  // 行内样式段（按 grapheme 偏移，可空）
  final SubtitleAnchor? anchor;    // \an；null=未指定
  final SubtitlePos? posFraction;  // \pos 归一化 (x/playResX, y/playResY) 0..1；null=无
}

/// 单条 cue 原文 → 结构化。一趟扫描同时构建 plainText 与 span 边界。
/// playResX/Y 仅用于把 \pos 归一化；srt/vtt 无 \pos，传 null 即可。
SubtitleMarkup parseSubtitleMarkup(String raw, {double? playResX, double? playResY});
```

要点：
- span 偏移用 **grapheme 单位**，与 overlay 的 `text.characters` 列表一一对齐，映射零成本。
- 一趟扫描：遇 `{...}` 解析其中 `\i/\b/\u/\s/\c/\1c/\fs/\an/\pos`（多标签如 `{\an8\i1}` 顺序处理），忽略未知标签；块外 `\N`/`\n`/`\h` → 空格累入 plainText。
- 样式是「开关栈」语义：`\i1` 开、`\i0` 关，到文本结束闭合所有开区间。
- `posFraction` 用纯 Dart `SubtitlePos`（见上），不引 `dart:ui`，保持 `hibiki_audio` 零 Flutter 依赖。

### 3.2 数据流（单一代码路径，无 DB 迁移）

1. `AudioCue` 加**瞬态可空字段** `SubtitleMarkup? markup`（不持久化，`toCompanion`/`fromRow` 不碰它）。`SubtitleMarkup` 是同包纯 Dart 类型，不跨层。
2. 三个 parser 把现有 `_stripHtml/_stripTags/_cleanText` 统一改为：
   ```dart
   final SubtitleMarkup m = parseSubtitleMarkup(raw, playResX: ..., playResY: ...);
   cue.text = m.plainText;
   cue.markup = m;
   ```
   - srt/vtt 传 `playResX/Y = null`。ass 传从 `[Script Info]` 读到的 PlayRes。
   - **副作用红利**：srt/vtt 现在也剥 `{...}` → BUG-105 的 leak 顺带根治（audiobook 的 srt 含 ass 残留也受益）。
   - `cue.text` 永远纯文本 → 查词/制卡/同步/debug 全部安全，零回归。
3. audiobook 忽略 `markup`（WebView 渲染不变，纯文本不变）；视频 overlay 读 `markup`。

### 3.3 AssParser 读 PlayResX/PlayResY

现 `ass_parser.dart` 直接跳到 `[Events]`。补一段：扫描 `[Script Info]` 段的 `PlayResX:`/`PlayResY:` 行（大小写不敏感），缺省按 ASS 规范 384×288。把 PlayRes 传入每条 cue 的 `parseSubtitleMarkup`。

### 3.4 视频几何坐标映射纯函数（video 层）

`hibiki/lib/src/media/video/subtitle_pos_mapping.dart`：
```dart
/// 把归一化 \pos 分数映射到 overlay 容器内的屏幕坐标，含 BoxFit.contain letterbox。
/// videoW/H=视频原始分辨率；containerSize=overlay 容器尺寸。
/// 返回容器局部坐标系下的 Offset。videoW/H<=0（未解码）时返回 null，调用方回退。
Offset? mapPosFractionToContainer(
  SubtitlePos posFraction,
  int videoW, int videoH,
  Size containerSize,
);
```
内容矩形 = `BoxFit.contain` 把 `videoW×videoH` 放入 `containerSize` 的居中矩形；`screen = 内容矩形原点 + (xFraction, yFraction) × 内容矩形尺寸`。纯函数可单测。

### 3.5 渲染（`video_subtitle_overlay.dart`）

- controller 暴露视频原始宽高：`int? get videoWidth => _player?.state.width; int? get videoHeight => _player?.state.height;`，并在 `load` 时监听 `player.stream.width/height` → `notifyListeners`，让分辨率到位后 overlay 重定位。
- overlay 用 `LayoutBuilder` 拿容器尺寸。
- 取 `markup = controller.currentCue?.markup`：
  - **定位**：
    - `markup.posFraction != null` 且 `mapPosFractionToContainer(...)` 非 null → `Stack` + `Positioned(left,top)` + `FractionalTranslation(translation: Offset(-hAnchorFrac, -vAnchorFrac))`（left0/center0.5/right1，top0/mid0.5/bottom1）让锚点精确落到 screenPos。anchor 缺省时 `\pos` 按 ASS 默认 an2（底居中）。
    - 否则按 `markup.anchor`：top→顶部（padding 从顶部）、bottom→底部（现有 `bottomPadding`）、middle→垂直居中；horizontal 同理。anchor 为 null → 现状底居中（完全向后兼容）。
  - **行内样式**：逐 grapheme 渲染时，按覆盖该 grapheme 的 span 合并 `TextStyle`（italic/bold/underline/strike/color/fontSize 覆盖外观默认）。无 span → 完全沿用现有外观。
  - **逐字查词 + 模糊沉浸不动**：`onCharTap` 仍传 `cue.text`(纯文本) + 正确 grapheme 索引；`blurEnabled` 逻辑原样。

### 3.6 BUG-106 鼠标自动隐藏

`_desktopControlsTheme` 的 `MaterialDesktopVideoControlsThemeData` 加 `hideMouseOnControlsRemoval: true`。一行。

## 4. 测试（最强可落地层）

- `packages/hibiki_audio/test/.../subtitle_markup_test.dart`（纯函数）：
  - `{\an8}（カンナ）ふわぁ~` → plainText 无标签 + anchor=top,center。
  - `{\i1}x{\i0}y` → span [0,1) italic。
  - `{\b1\u1}ab` 多标签、嵌套开关；`\c&H0000FF&` → colorArgb=0xFFFF0000（BGR→RGB）；`\fs30`；`\N`/`\h`→空格。
  - `\pos(960,540)` + playRes 1920×1080 → posFraction (0.5,0.5)；`\k`/`\t`/`\p`/`\move` 标签被删、不产出样式。
  - `\an` 缺省 → anchor=null（向后兼容路径）。
- `hibiki/test/media/audiobook/{srt,vtt}_parser_test.dart`：补例断言 `cue.text` 不再含 `{...}`（BUG-105 守卫）。
- `hibiki/test/media/video/subtitle_pos_mapping_test.dart`（纯函数）：宽容器 letterbox（pillarbox）、高容器、等比、未解码返回 null。
- `hibiki/test/media/video/ass_parser_playres_test.dart`：读 PlayResX/Y、缺省 384×288。
- overlay widget 测试（media_kit headless 不可跑真 Video，但 overlay 是独立 widget 吃 controller stub）：anchor=top→对齐顶部、span→样式生效、onCharTap 仍传纯文本且 grapheme 索引正确、blur 态不变。
- `hibiki/test/pages/video_mouse_autohide_guard_test.dart`（源码守卫）：`_desktopControlsTheme` 源码含 `hideMouseOnControlsRemoval: true`。

## 5. 影响范围与向后兼容

- audiobook：`AudioCue.markup` 新字段它不读；srt/vtt 现在多剥 `{...}`——audiobook 的字幕本就不该含 ASS 块，剥掉只会更干净，纯文本高亮匹配不变。
- 无 ASS 标签的字幕：`parseSubtitleMarkup` 产出 anchor=null、spans=[]、plainText=去 HTML 文本，overlay 走现状底居中路径，**像素级与现状一致**。
- 无 DB schema 改动（`markup` 瞬态、不入 companion/row）。

## 6. 验证

- `dart format .` + `flutter test`（全量）。
- 真机/桌面肉眼复测（待用户）：① 播含 `\an8`/斜体/定位字幕的视频，标签语义正确渲染、不再显示控制码；逐字查词命中正确字；② 桌面播放静止 3s 后鼠标隐藏，移动即现。
