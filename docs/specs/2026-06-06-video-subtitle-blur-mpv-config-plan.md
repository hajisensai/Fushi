# 视频字幕模糊 + mpv 配置项 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 asbplayer 的「字幕模糊（听力沉浸用）」抄进 Hibiki 视频播放器（默认关闭，开启后默认遮罩、悬停/点击变清晰），并暴露一组 mpv 画质/解码配置（硬件解码/高画质/抖动开关 + 原始 mpv.conf 编辑框），顺带补字幕外观设置和 Jimaku 字幕二次筛选。

**Architecture:**
- 字幕走 Flutter overlay（`VideoSubtitleOverlay`，为逐字查词，libmpv 自身字幕已关），所以「模糊/外观」纯在 Flutter 层做，不碰 mpv。
- mpv 画质/解码项经 media_kit 底层 libmpv 的 `setProperty`（与现有着色器 `glsl-shaders` 同一边界）在 `load` 时及设置变更时 best-effort 应用；非 libmpv 后端/不可运行时设置的属性静默 no-op。
- 所有新设置走全局偏好（`PreferencesRepository.getPref/setPref`），与现有 `videoShadersEnabled` / `jimakuApiKey` 一致；音画延迟仍是 per-book（已有，不动）。

**Tech Stack:** Flutter / media_kit (libmpv) / Riverpod / Drift preferences / Slang i18n（17 语言，经 `tool/i18n_sync.dart`）。

**测试边界（关键约束）:** media_kit `Player()` 在测试宿主无 libmpv 会抛，**禁止单测 load/setProperty**。可测层：
- `VideoSubtitleOverlay` widget 测试——`VideoPlayerController` 的 `setCues` + `debugUpdateCueForPosition` 不实例化 Player，可在测试里喂 cue 让 `currentCue` 非空，再 pump overlay 断言。
- mpv 配置：纯函数（解析 mpv.conf 文本、构建属性表、encode/decode）单测；`applyMpvConfigToPlayer` 靠 `flutter analyze` + 源码守卫验证（同 `applyShadersToPlayer` 范式）。
- Jimaku 筛选：纯函数单测。

**验证命令（每个 commit 前）:** 在 `hibiki/` 下 `dart format .` + `flutter analyze`（0 issue）+ 相关 `flutter test`。i18n 改动后 `dart run slang` 重新生成 `strings.g.dart` 再 `dart format`。

---

## 文件结构

| 文件 | 责任 | 动作 |
|---|---|---|
| `hibiki/lib/src/media/video/video_mpv_config.dart` | mpv 配置模型 + 纯函数（解析/构建属性/编解码）+ `applyMpvConfigToPlayer` | 新建 |
| `hibiki/lib/src/media/video/video_subtitle_style.dart` | 字幕外观模型（字号/颜色/背景透明度/底距）+ 编解码纯函数 | 新建 |
| `hibiki/lib/src/media/video/video_subtitle_overlay.dart` | 字幕 overlay：加模糊（ImageFiltered）+ 悬停/点击显形 + 外观参数 | 改 |
| `hibiki/lib/src/media/video/video_player_controller.dart` | `load` 后应用 mpv 配置；新增 `applyMpvConfig` 运行时切换 | 改 |
| `hibiki/lib/src/models/preferences_repository.dart` | 新增偏好：字幕模糊开关 / 字幕外观 / mpv 配置 | 改 |
| `hibiki/lib/src/models/app_model.dart` | 透出上述偏好 getter/setter（镜像 `videoShadersEnabled`） | 改 |
| `hibiki/lib/src/pages/implementations/video_hibiki_page.dart` | 设置面板加「字幕模糊/字幕外观/mpv 配置」入口；overlay 传参；模糊切换热键 | 改 |
| `hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart` | 候选列表加二次关键词筛选框 | 改 |
| `hibiki/lib/i18n/*.i18n.json` | 新增 i18n key（经 `tool/i18n_sync.dart`） | 改 |
| `hibiki/test/media/video/video_mpv_config_test.dart` | mpv 配置纯函数测试 | 新建 |
| `hibiki/test/media/video/video_subtitle_style_test.dart` | 字幕外观编解码测试 | 新建 |
| `hibiki/test/media/video/video_subtitle_overlay_test.dart` | overlay 模糊/显形/外观 widget 测试 | 新建 |
| `hibiki/test/pages/jimaku_filter_test.dart` | Jimaku 二次筛选纯函数测试 | 新建 |

---

## Feature A：字幕模糊（opt-in，默认关闭）

asbplayer 行为：开启「Subtitle blur」后字幕默认打码看不清；鼠标**悬停**字幕→瞬间清晰，移开→恢复模糊；快捷键切换开关。Hibiki 默认关闭，开启后默认遮罩。移动端无悬停，用**点击/长按**显形（点击单字符仍走查词，故显形用「双击字幕区空白」或单独的显形手势——本计划用：模糊态下整条字幕先变清晰一段时间，再恢复；触发用 overlay 上的透明 GestureDetector 包层，桌面用 MouseRegion）。

### Task A1：偏好——字幕模糊开关

**Files:**
- Modify: `hibiki/lib/src/models/preferences_repository.dart:237`（紧跟 `setVideoShadersEnabled` 之后）
- Modify: `hibiki/lib/src/models/app_model.dart:1602`（紧跟 `setVideoShadersEnabled` 之后）

- [ ] **Step 1: 在 preferences_repository.dart 加偏好**

在 `setVideoShadersEnabled` 方法后插入：

```dart
  /// 视频字幕模糊（听力沉浸）开关：默认关闭。开启后字幕默认打码，悬停/点击显形。
  bool get videoSubtitleBlur =>
      getPref('video_subtitle_blur', defaultValue: false) as bool;

  Future<void> setVideoSubtitleBlur(bool value) async {
    await setPref('video_subtitle_blur', value);
    notifyListeners();
  }
```

- [ ] **Step 2: 在 app_model.dart 透出**

在 `setVideoShadersEnabled` 委托后插入：

```dart
  bool get videoSubtitleBlur => prefsRepo.videoSubtitleBlur;

  Future<void> setVideoSubtitleBlur(bool value) =>
      prefsRepo.setVideoSubtitleBlur(value);
```

- [ ] **Step 3: 验证编译**

Run: `cd hibiki && flutter analyze lib/src/models/`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/models/preferences_repository.dart hibiki/lib/src/models/app_model.dart
git commit -m "feat(video): add subtitle-blur preference (off by default)"
```

### Task A2：overlay 加模糊 + 显形（含外观参数预留）

**Files:**
- Modify: `hibiki/lib/src/media/video/video_subtitle_overlay.dart`
- Test: `hibiki/test/media/video/video_subtitle_overlay_test.dart`

- [ ] **Step 1: 写失败的 widget 测试**

新建 `hibiki/test/media/video/video_subtitle_overlay_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/media/video/video_subtitle_overlay.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

VideoPlayerController _controllerWithCue(String text) {
  final VideoPlayerController c = VideoPlayerController();
  c.setCues(<AudioCue>[
    AudioCue(bookKey: 'b', sectionIndex: 0, startMs: 0, endMs: 5000, text: text),
  ]);
  c.debugUpdateCueForPosition(100); // 让 currentCue=该句
  return c;
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump();
}

void main() {
  testWidgets('blur off: no ImageFiltered around subtitle', (tester) async {
    final c = _controllerWithCue('テスト');
    await _pump(tester, VideoSubtitleOverlay(controller: c, blurEnabled: false));
    expect(find.text('テ'), findsOneWidget);
    expect(find.byType(ImageFiltered), findsNothing);
  });

  testWidgets('blur on: ImageFiltered wraps subtitle, revealed=false',
      (tester) async {
    final c = _controllerWithCue('テスト');
    await _pump(tester, VideoSubtitleOverlay(controller: c, blurEnabled: true));
    expect(find.byType(ImageFiltered), findsOneWidget);
  });

  testWidgets('blur on + tap reveal: ImageFiltered gone after reveal',
      (tester) async {
    final c = _controllerWithCue('テスト');
    await _pump(tester, VideoSubtitleOverlay(controller: c, blurEnabled: true));
    expect(find.byType(ImageFiltered), findsOneWidget);
    // 点字幕区域的「显形」热区（用 key 定位）。
    await tester.tap(find.byKey(const Key('video-subtitle-reveal')));
    await tester.pump();
    expect(find.byType(ImageFiltered), findsNothing);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/media/video/video_subtitle_overlay_test.dart`
Expected: FAIL —— `VideoSubtitleOverlay` 没有 `blurEnabled` 命名参数（编译错）。

- [ ] **Step 3: 改 VideoSubtitleOverlay 为 StatefulWidget，加模糊与显形**

把 `video_subtitle_overlay.dart` 整体替换为：

```dart
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:hibiki/src/media/video/video_player_controller.dart';

/// 视频底部当前句字幕 overlay；监听 [VideoPlayerController.currentCue]。
///
/// 字幕逐字符可点击：点击第 [int] 个 grapheme 时回调
/// `(sentence, graphemeIndex, charRect)`，调用方据此从该位置起取词查词（最长匹配
/// 交给 HoshiDicts），并用 [charRect]（被点字符的全局屏幕矩形）把查词浮层定位到
/// 字符附近。非字符区域不拦截指针，让底层 media_kit 控制（点击显隐控制条）正常工作。
///
/// [blurEnabled] 为听力沉浸模式：字幕默认打码（[ImageFiltered] 高斯模糊），桌面悬停
/// （[MouseRegion]）或移动端点击右上角「显形」热区后变清晰，再次移开/点击恢复。
/// 默认关闭，关闭时与历史外观完全一致。
class VideoSubtitleOverlay extends StatefulWidget {
  const VideoSubtitleOverlay({
    required this.controller,
    this.onCharTap,
    this.blurEnabled = false,
    this.fontSize = 22,
    this.textColor = Colors.white,
    this.backgroundOpacity = 0.54,
    this.bottomPadding = 72,
    super.key,
  });

  final VideoPlayerController controller;

  final void Function(String sentence, int graphemeIndex, Rect charRect)?
      onCharTap;

  /// 听力沉浸：字幕默认模糊，悬停/点击显形。
  final bool blurEnabled;

  /// 字幕字号（外观设置）。
  final double fontSize;

  /// 字幕文字颜色（外观设置）。
  final Color textColor;

  /// 字幕背景不透明度 0..1（外观设置；历史值 0.54 = Colors.black54）。
  final double backgroundOpacity;

  /// 字幕距底部抬升量（避开 media_kit 控制条；外观设置）。
  final double bottomPadding;

  @override
  State<VideoSubtitleOverlay> createState() => _VideoSubtitleOverlayState();
}

class _VideoSubtitleOverlayState extends State<VideoSubtitleOverlay> {
  bool _revealed = false;

  @override
  void didUpdateWidget(VideoSubtitleOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 关闭模糊时重置显形态，避免下次开启残留。
    if (!widget.blurEnabled && _revealed) _revealed = false;
  }

  void _setRevealed(bool v) {
    if (_revealed == v) return;
    setState(() => _revealed = v);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (BuildContext context, _) {
        final String text = widget.controller.currentCue?.text ?? '';
        if (text.isEmpty) return const SizedBox.shrink();
        // cue 变化时新句子重新打码（仅模糊模式）。
        final List<String> chars = text.characters.toList(growable: false);
        final bool blurred = widget.blurEnabled && !_revealed;

        Widget box = DecoratedBox(
          decoration: BoxDecoration(
            color: widget.textColor == Colors.transparent
                ? Colors.transparent
                : Colors.black.withValues(alpha: widget.backgroundOpacity),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              alignment: WrapAlignment.center,
              children: <Widget>[
                for (int i = 0; i < chars.length; i++)
                  Builder(
                    builder: (BuildContext charContext) => GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onCharTap == null
                          ? null
                          : () => widget.onCharTap!(
                                text,
                                i,
                                _globalRectOf(charContext),
                              ),
                      child: Text(
                        chars[i],
                        style: TextStyle(
                          color: widget.textColor,
                          fontSize: widget.fontSize,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );

        if (blurred) {
          // 模糊态：盖一层高斯模糊 + 拦截字符点击（避免误触查词），并提供显形热区。
          box = Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: box,
              ),
              // 透明覆盖：拦截字符点击 + 移动端点它显形。
              Positioned.fill(
                child: GestureDetector(
                  key: const Key('video-subtitle-reveal'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _setRevealed(true),
                ),
              ),
            ],
          );
        }

        // 桌面悬停显形/移开复原（移动端无 hover，靠上面的点击热区）。
        final Widget hoverable = widget.blurEnabled
            ? MouseRegion(
                onEnter: (_) => _setRevealed(true),
                onExit: (_) => _setRevealed(false),
                child: box,
              )
            : box;

        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.only(bottom: widget.bottomPadding),
            child: hoverable,
          ),
        );
      },
    );
  }

  static Rect _globalRectOf(BuildContext charContext) {
    final RenderObject? ro = charContext.findRenderObject();
    if (ro is! RenderBox || !ro.hasSize) return Rect.zero;
    final Offset topLeft = ro.localToGlobal(Offset.zero);
    return topLeft & ro.size;
  }
}
```

> 注：`Colors.black54` == `Colors.black.withValues(alpha:0.54)`，历史背景保持不变。`withValues` 是 Flutter 3.27+ API，仓库已在用（若 analyze 报不存在则改 `Colors.black.withOpacity(...)`）。

- [ ] **Step 4: 运行测试通过**

Run: `cd hibiki && flutter test test/media/video/video_subtitle_overlay_test.dart`
Expected: PASS（3 个用例）。

- [ ] **Step 5: 全量视频测试不回归**

Run: `cd hibiki && flutter test test/media/video/`
Expected: All pass（既有 cue-gap 等用例不受影响——默认 blurEnabled=false 时结构等价于历史，唯一差异是 `Colors.black54` 改 `withValues`，视觉等价）。

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/media/video/video_subtitle_overlay.dart hibiki/test/media/video/video_subtitle_overlay_test.dart
git commit -m "feat(video): subtitle blur overlay with hover/tap reveal (opt-in)"
```

### Task A3：i18n key（字幕模糊）

**Files:**
- Modify: `hibiki/lib/i18n/*.i18n.json`（经脚本）
- Regenerate: `hibiki/lib/i18n/strings.g.dart`

- [ ] **Step 1: 用 i18n_sync 加 key（禁止手改 17 文件）**

Run（在 `hibiki/` 下）:

```bash
dart run tool/i18n_sync.dart --add video_setting_subtitle_blur "Blur subtitles (immersion)" "字幕模糊（沉浸）"
dart run tool/i18n_sync.dart --add video_setting_subtitle_blur_hint "Hide subtitles by default; hover or tap to reveal for listening practice." "默认遮挡字幕，悬停或点击显形，用于听力沉浸。"
```

- [ ] **Step 2: 重新生成 strings.g.dart 并格式化**

Run: `cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart`
Expected: 生成成功，无 key 缺失报错。

- [ ] **Step 3: i18n 完整性测试**

Run: `cd hibiki && flutter test test/i18n/`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/i18n/
git commit -m "i18n(video): add subtitle-blur strings"
```

### Task A4：设置面板加模糊开关 + overlay 传参 + 切换热键

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`

- [ ] **Step 1: overlay 调用处传入模糊/外观参数**

把 `_buildVideoControls`（`video_hibiki_page.dart:1499`）里的 `VideoSubtitleOverlay` 改为：

```dart
            child: VideoSubtitleOverlay(
              controller: controller,
              onCharTap: _lookupAt,
              blurEnabled: appModel.videoSubtitleBlur,
              fontSize: _subtitleStyle.fontSize,
              textColor: _subtitleStyle.textColor,
              backgroundOpacity: _subtitleStyle.backgroundOpacity,
              bottomPadding: _subtitleStyle.bottomPadding,
            ),
```

> `_subtitleStyle` 在 Feature B 引入；本步先只传 `blurEnabled`，其余四参在 Feature B 完成前用默认值（即先写 `blurEnabled: appModel.videoSubtitleBlur,` 不传外观四参，等 B 完成再补）。**为避免编译断裂，本步只加 `blurEnabled` 一行。**

实际本步只插入一行：

```dart
              blurEnabled: appModel.videoSubtitleBlur,
```

- [ ] **Step 2: 设置面板加模糊开关**

在 `_showPlayerSettings` 的着色器按钮（`video_hibiki_page.dart:1096` 那个 `Align` 之后、`Column` 闭合前）插入分隔线 + SwitchListTile：

```dart
                    const Divider(color: Colors.white24, height: 24),
                    // ── 字幕模糊（听力沉浸；默认关）──
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      activeColor: cs.primary,
                      title: Text(t.video_setting_subtitle_blur,
                          style: const TextStyle(color: Colors.white)),
                      subtitle: Text(t.video_setting_subtitle_blur_hint,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12)),
                      value: appModel.videoSubtitleBlur,
                      onChanged: (bool v) async {
                        await appModel.setVideoSubtitleBlur(v);
                        setSheet(() {});
                        if (mounted) setState(() {});
                      },
                    ),
```

- [ ] **Step 3: 加模糊切换热键（media_kit keyboardShortcuts）**

在 `_desktopControlsTheme` 与 `_mobileControlsTheme` 构建的 theme data 上注册一个 `keyboardShortcuts` 项把 `LogicalKeyboardKey.keyB` 映射成切换 blur。若两 theme 已有 `keyboardShortcuts` 字段则合并，否则新增。处理函数：

```dart
  /// 切换字幕模糊（'B' 热键 + 设置面板共用）。
  Future<void> _toggleSubtitleBlur() async {
    await appModel.setVideoSubtitleBlur(!appModel.videoSubtitleBlur);
    if (mounted) setState(() {});
  }
```

在两个 controls theme 的 `keyboardShortcuts` map 加：

```dart
        const SingleActivator(LogicalKeyboardKey.keyB): _toggleSubtitleBlur,
```

> 若 `MaterialVideoControlsThemeData` / `MaterialDesktopVideoControlsThemeData` 不支持自定义 `keyboardShortcuts`（按 media_kit 版本核对其字段名，可能为 `keyboardShortcuts` 或需用外层 `CallbackShortcuts`），则改为：在 `_buildVideoBody` 的 `Video` 外包一层 `CallbackShortcuts`（`bindings: {SingleActivator(keyB): _toggleSubtitleBlur}`）+ `Focus(autofocus:false)`，不抢 `_videoFocusNode`。实现者据当前 media_kit API 二选一，确保不破坏既有空格快捷键。需 `import 'package:flutter/services.dart';`（若未导入）。

- [ ] **Step 4: 验证编译 + 视频页测试**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/video_hibiki_page.dart && flutter test test/pages/`
Expected: 0 issue；page 测试 pass（若有 page 级 widget 测试覆盖视频页则一并绿）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/pages/implementations/video_hibiki_page.dart
git commit -m "feat(video): subtitle blur toggle in settings + B hotkey"
```

---

## Feature B：字幕外观设置（字号/颜色/背景/底距，默认 = 现状）

### Task B1：字幕外观模型 + 编解码纯函数

**Files:**
- Create: `hibiki/lib/src/media/video/video_subtitle_style.dart`
- Test: `hibiki/test/media/video/video_subtitle_style_test.dart`

- [ ] **Step 1: 写失败测试**

新建 `hibiki/test/media/video/video_subtitle_style_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';

void main() {
  test('default matches historical hardcoded look', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle.defaults;
    expect(s.fontSize, 22);
    expect(s.textColor, const Color(0xFFFFFFFF));
    expect(s.backgroundOpacity, closeTo(0.54, 1e-9));
    expect(s.bottomPadding, 72);
  });

  test('encode/decode round-trips', () {
    const VideoSubtitleStyle s = VideoSubtitleStyle(
      fontSize: 30,
      textColor: Color(0xFFFF0000),
      backgroundOpacity: 0.2,
      bottomPadding: 40,
    );
    final VideoSubtitleStyle back =
        VideoSubtitleStyle.decode(VideoSubtitleStyle.encode(s));
    expect(back.fontSize, 30);
    expect(back.textColor, const Color(0xFFFF0000));
    expect(back.backgroundOpacity, closeTo(0.2, 1e-9));
    expect(back.bottomPadding, 40);
  });

  test('decode tolerates empty/garbage -> defaults', () {
    expect(VideoSubtitleStyle.decode('').fontSize, 22);
    expect(VideoSubtitleStyle.decode('not json').textColor,
        const Color(0xFFFFFFFF));
  });

  test('decode clamps out-of-range', () {
    final VideoSubtitleStyle s = VideoSubtitleStyle.decode(
        '{"fontSize":999,"backgroundOpacity":5,"bottomPadding":-10}');
    expect(s.fontSize, lessThanOrEqualTo(72));
    expect(s.backgroundOpacity, lessThanOrEqualTo(1.0));
    expect(s.bottomPadding, greaterThanOrEqualTo(0));
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/media/video/video_subtitle_style_test.dart`
Expected: FAIL —— `video_subtitle_style.dart` 不存在。

- [ ] **Step 3: 写模型**

新建 `hibiki/lib/src/media/video/video_subtitle_style.dart`：

```dart
import 'dart:convert';

import 'package:flutter/material.dart';

/// 视频字幕外观（全局偏好）。默认值刻意等于历史硬编码外观，未设置时观感不变。
@immutable
class VideoSubtitleStyle {
  const VideoSubtitleStyle({
    required this.fontSize,
    required this.textColor,
    required this.backgroundOpacity,
    required this.bottomPadding,
  });

  /// 历史硬编码外观：fontSize 22 / 白字 / 背景 black54 / 底距 72。
  static const VideoSubtitleStyle defaults = VideoSubtitleStyle(
    fontSize: 22,
    textColor: Color(0xFFFFFFFF),
    backgroundOpacity: 0.54,
    bottomPadding: 72,
  );

  final double fontSize;
  final Color textColor;
  final double backgroundOpacity;
  final double bottomPadding;

  VideoSubtitleStyle copyWith({
    double? fontSize,
    Color? textColor,
    double? backgroundOpacity,
    double? bottomPadding,
  }) {
    return VideoSubtitleStyle(
      fontSize: fontSize ?? this.fontSize,
      textColor: textColor ?? this.textColor,
      backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
      bottomPadding: bottomPadding ?? this.bottomPadding,
    );
  }

  /// 编码为持久化 JSON 字符串。纯函数。
  static String encode(VideoSubtitleStyle s) => jsonEncode(<String, dynamic>{
        'fontSize': s.fontSize,
        'textColor': s.textColor.toARGB32(),
        'backgroundOpacity': s.backgroundOpacity,
        'bottomPadding': s.bottomPadding,
      });

  /// 解码（容错：null/空/非法 → [defaults]；越界 clamp）。纯函数。
  static VideoSubtitleStyle decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      double num2d(Object? v, double fb) =>
          v is num ? v.toDouble() : fb;
      final int argb = d['textColor'] is num
          ? (d['textColor'] as num).toInt()
          : 0xFFFFFFFF;
      return VideoSubtitleStyle(
        fontSize: num2d(d['fontSize'], 22).clamp(10, 72),
        textColor: Color(argb),
        backgroundOpacity: num2d(d['backgroundOpacity'], 0.54).clamp(0.0, 1.0),
        bottomPadding: num2d(d['bottomPadding'], 72).clamp(0, 400),
      );
    } catch (_) {
      return defaults;
    }
  }
}
```

> `Color.toARGB32()` / `Color(int)` 是 Flutter 3.27+ 推荐 API（替代弃用的 `.value`）。若 analyze 报缺失则用 `s.textColor.value` / `Color(argb)`。

- [ ] **Step 4: 运行测试通过**

Run: `cd hibiki && flutter test test/media/video/video_subtitle_style_test.dart`
Expected: PASS（4 用例）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/media/video/video_subtitle_style.dart hibiki/test/media/video/video_subtitle_style_test.dart
git commit -m "feat(video): subtitle appearance model with safe encode/decode"
```

### Task B2：偏好 + app_model 透出字幕外观

**Files:**
- Modify: `hibiki/lib/src/models/preferences_repository.dart`
- Modify: `hibiki/lib/src/models/app_model.dart`

- [ ] **Step 1: 偏好（紧跟 `setVideoSubtitleBlur` 后）**

```dart
  /// 视频字幕外观（JSON；解析见 VideoSubtitleStyle.encode/decode）。空串=默认外观。
  String get videoSubtitleStyle =>
      getPref('video_subtitle_style', defaultValue: '') as String;

  Future<void> setVideoSubtitleStyle(String json) async {
    await setPref('video_subtitle_style', json);
    notifyListeners();
  }
```

- [ ] **Step 2: app_model 透出（紧跟 `setVideoSubtitleBlur` 委托后）**

```dart
  String get videoSubtitleStyle => prefsRepo.videoSubtitleStyle;

  Future<void> setVideoSubtitleStyle(String json) =>
      prefsRepo.setVideoSubtitleStyle(json);
```

- [ ] **Step 3: 验证编译**

Run: `cd hibiki && flutter analyze lib/src/models/`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/models/preferences_repository.dart hibiki/lib/src/models/app_model.dart
git commit -m "feat(video): persist subtitle appearance preference"
```

### Task B3：i18n（字幕外观）

- [ ] **Step 1: 加 key**

Run（`hibiki/` 下）:

```bash
dart run tool/i18n_sync.dart --add video_setting_subtitle_appearance "Subtitle appearance" "字幕外观"
dart run tool/i18n_sync.dart --add video_setting_subtitle_font_size "Font size" "字号"
dart run tool/i18n_sync.dart --add video_setting_subtitle_bg_opacity "Background opacity" "背景不透明度"
dart run tool/i18n_sync.dart --add video_setting_subtitle_position "Vertical position" "垂直位置"
dart run tool/i18n_sync.dart --add video_setting_subtitle_reset "Reset to default" "恢复默认"
```

- [ ] **Step 2: 重新生成 + 格式化 + i18n 测试**

Run: `cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart && flutter test test/i18n/`
Expected: 生成无缺 key 报错；i18n 测试 pass。

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/i18n/
git commit -m "i18n(video): add subtitle appearance strings"
```

### Task B4：设置面板字幕外观区 + overlay 接外观参数

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`

- [ ] **Step 1: 页面 state 持有 `_subtitleStyle`**

在 `_VideoHibikiPageState`（约 `video_hibiki_page.dart:101` 之后的字段区）加字段并在 `initState` 加载：

```dart
  /// 当前字幕外观（全局偏好快照；设置面板改动后刷新）。
  VideoSubtitleStyle _subtitleStyle = VideoSubtitleStyle.defaults;
```

在 `initState`（或既有偏好加载处）加：

```dart
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);
```

并在文件顶部 import：

```dart
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
```

- [ ] **Step 2: overlay 调用补齐外观四参**

把 Task A4-Step1 里只传 `blurEnabled` 的 `VideoSubtitleOverlay` 补全为：

```dart
            child: VideoSubtitleOverlay(
              controller: controller,
              onCharTap: _lookupAt,
              blurEnabled: appModel.videoSubtitleBlur,
              fontSize: _subtitleStyle.fontSize,
              textColor: _subtitleStyle.textColor,
              backgroundOpacity: _subtitleStyle.backgroundOpacity,
              bottomPadding: _subtitleStyle.bottomPadding,
            ),
```

- [ ] **Step 3: 设置面板加外观区（字号/背景/位置 滑条 + 恢复默认）**

在 `_showPlayerSettings`（模糊开关之后）加一段。用 Slider 即时改并持久化：

```dart
                    const Divider(color: Colors.white24, height: 24),
                    Text(t.video_setting_subtitle_appearance,
                        style: const TextStyle(color: Colors.white70)),
                    // 字号
                    Row(children: <Widget>[
                      Text(t.video_setting_subtitle_font_size,
                          style: const TextStyle(color: Colors.white54)),
                      Expanded(
                        child: Slider(
                          min: 12,
                          max: 48,
                          value: _subtitleStyle.fontSize.clamp(12, 48),
                          onChanged: (double v) => setSheet(() {
                            _subtitleStyle =
                                _subtitleStyle.copyWith(fontSize: v);
                          }),
                          onChangeEnd: (double v) => _persistSubtitleStyle(
                              _subtitleStyle.copyWith(fontSize: v)),
                        ),
                      ),
                    ]),
                    // 背景不透明度
                    Row(children: <Widget>[
                      Text(t.video_setting_subtitle_bg_opacity,
                          style: const TextStyle(color: Colors.white54)),
                      Expanded(
                        child: Slider(
                          min: 0,
                          max: 1,
                          value: _subtitleStyle.backgroundOpacity,
                          onChanged: (double v) => setSheet(() {
                            _subtitleStyle =
                                _subtitleStyle.copyWith(backgroundOpacity: v);
                          }),
                          onChangeEnd: (double v) => _persistSubtitleStyle(
                              _subtitleStyle.copyWith(backgroundOpacity: v)),
                        ),
                      ),
                    ]),
                    // 垂直位置（底距）
                    Row(children: <Widget>[
                      Text(t.video_setting_subtitle_position,
                          style: const TextStyle(color: Colors.white54)),
                      Expanded(
                        child: Slider(
                          min: 0,
                          max: 240,
                          value: _subtitleStyle.bottomPadding.clamp(0, 240),
                          onChanged: (double v) => setSheet(() {
                            _subtitleStyle =
                                _subtitleStyle.copyWith(bottomPadding: v);
                          }),
                          onChangeEnd: (double v) => _persistSubtitleStyle(
                              _subtitleStyle.copyWith(bottomPadding: v)),
                        ),
                      ),
                    ]),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () {
                          _persistSubtitleStyle(VideoSubtitleStyle.defaults);
                          setSheet(() {});
                        },
                        child: Text(t.video_setting_subtitle_reset,
                            style: TextStyle(color: cs.primary)),
                      ),
                    ),
```

加持久化方法（与 `_setSpeed` 同区）：

```dart
  /// 持久化字幕外观并刷新 overlay。
  Future<void> _persistSubtitleStyle(VideoSubtitleStyle style) async {
    _subtitleStyle = style;
    await appModel.setVideoSubtitleStyle(VideoSubtitleStyle.encode(style));
    if (mounted) setState(() {});
  }
```

> 颜色选择本计划不做（YAGNI：白字够用，背景透明度+字号+位置已覆盖主要诉求）；如后续要，再加 ColorPicker。

- [ ] **Step 4: 验证编译 + 测试**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/video_hibiki_page.dart && flutter test test/media/video/`
Expected: 0 issue；video 测试全绿。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/pages/implementations/video_hibiki_page.dart
git commit -m "feat(video): subtitle appearance controls (font/bg/position)"
```

---

## Feature C：mpv 配置（成体系的多分类配置 + 原始 mpv.conf 编辑框）

参照真正的 mpv 播放器菜单（解码/画质/画面几何/色彩均衡/播放），把所有**运行时可经 libmpv `setProperty` 生效**的常用项都暴露出来，外加原始 mpv.conf 框作高级逃生口。

**作用域划分（避免与已有功能重复）：**
- 已有、不重复进 mpv 配置：字幕轨切换/隐藏字幕（字幕源菜单）、字幕大小/上下移/重置（Feature B 外观）、字幕延迟（A/V 延迟）、Anime4k（着色器对话框）。
- mpv 配置覆盖：**解码**（hwdec）/**画质**（高画质 scale 预设、去色带 deband、抖动 dither、运动插帧 interpolation、去隔行 deinterlace）/**画面几何**（旋转 video-rotate、缩放 video-zoom、画面比例 video-aspect-override）/**色彩均衡**（亮度/对比度/饱和度/gamma/色相）/**播放**（单文件循环 loop-file）/**原始 mpv.conf 框**。
- **out-of-scope（标注，不做）**：SVP / RIFE 帧插值——需外部 vapoursynth/SVP/RIFE 工具链与滤镜，非纯 libmpv 属性，超出 media_kit 内置 libmpv 能力；弹幕（需弹幕源/渲染器，与本仓库无关）。

**默认值约束**：`VideoMpvConfig.defaults` 的每个字段都取 mpv 自身默认（hwdec=no、各色彩=0、scale=bilinear、deband=no…），故默认配置下即使全量 setProperty 也与历史行为视觉等价（设了等于没设）。同时全量 emit 保证设置面板里**关掉某项时能在运行时复位回默认**（不需重开视频）。

### Task C1：mpv 配置模型 + 纯函数（解析/构建/编解码）

**Files:**
- Create: `hibiki/lib/src/media/video/video_mpv_config.dart`
- Test: `hibiki/test/media/video/video_mpv_config_test.dart`

- [ ] **Step 1: 写失败测试**

新建 `hibiki/test/media/video/video_mpv_config_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';

void main() {
  group('parseMpvConf', () {
    test('parses key=value, ignores comments/blank', () {
      final Map<String, String> m = parseMpvConf('''
# comment
hwdec=auto-safe

scale=ewa_lanczossharp
keep-open=yes
''');
      expect(m['hwdec'], 'auto-safe');
      expect(m['scale'], 'ewa_lanczossharp');
      expect(m['keep-open'], 'yes');
      expect(m.containsKey('# comment'), isFalse);
    });

    test('bare flag -> yes', () {
      final Map<String, String> m = parseMpvConf('save-position-on-quit');
      expect(m['save-position-on-quit'], 'yes');
    });

    test('strips wrapping quotes', () {
      final Map<String, String> m = parseMpvConf('screenshot-dir="~/Pictures"');
      expect(m['screenshot-dir'], '~/Pictures');
    });
  });

  group('buildMpvProperties', () {
    test('defaults -> neutral values equal to mpv defaults (visually no-op)',
        () {
      final Map<String, String> m =
          buildMpvProperties(VideoMpvConfig.defaults);
      expect(m['hwdec'], 'no');
      expect(m['scale'], 'bilinear');
      expect(m['deband'], 'no');
      expect(m['dither-depth'], 'no');
      expect(m['brightness'], '0');
      expect(m['contrast'], '0');
      expect(m['saturation'], '0');
      expect(m['gamma'], '0');
      expect(m['hue'], '0');
      expect(m['video-rotate'], '0');
      expect(m['loop-file'], 'no');
      // 新增结构化项的中性默认（= mpv 默认，视觉等价）。
      expect(m['sigmoid-upscaling'], 'yes'); // mpv 默认 yes
      expect(m['correct-downscaling'], 'no');
      expect(m['panscan'], '0.0');
      expect(m['audio-delay'], '0.0');
      expect(m['audio-pitch-correction'], 'yes'); // mpv 默认 yes
      expect(m['audio-channels'], 'auto-safe');
      expect(m['audio-normalize-downmix'], 'no');
    });

    test('audio group passes through', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(
        audioDelayMs: 250,
        audioPitchCorrection: false,
        audioChannels: 'stereo',
        normalizeDownmix: true,
      ));
      expect(m['audio-delay'], '0.25'); // 250ms = 0.25s
      expect(m['audio-pitch-correction'], 'no');
      expect(m['audio-channels'], 'stereo');
      expect(m['audio-normalize-downmix'], 'yes');
    });

    test('hwdec value passes through', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(hwdec: 'auto-safe'));
      expect(m['hwdec'], 'auto-safe');
    });

    test('highQuality on -> high-quality scale chain', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(highQuality: true));
      expect(m['scale'], 'ewa_lanczossharp');
      expect(m['cscale'], 'ewa_lanczossharp');
      expect(m['dscale'], 'mitchell');
    });

    test('toggles off -> explicit mpv defaults (so runtime switch-off resets)',
        () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(highQuality: false, deband: false));
      expect(m['scale'], 'bilinear');
      expect(m['deband'], 'no');
    });

    test('interpolation on -> interpolation+video-sync+tscale', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(interpolation: true));
      expect(m['interpolation'], 'yes');
      expect(m['video-sync'], 'display-resample');
      expect(m['tscale'], 'oversample');
    });

    test('color equalizer + geometry pass through', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(
        brightness: 10,
        contrast: -5,
        saturation: 20,
        videoRotate: 90,
        videoZoom: 0.5,
        aspectOverride: '16:9',
      ));
      expect(m['brightness'], '10');
      expect(m['contrast'], '-5');
      expect(m['saturation'], '20');
      expect(m['video-rotate'], '90');
      expect(m['video-zoom'], '0.5');
      expect(m['video-aspect-override'], '16:9');
    });

    test('raw overrides toggle-derived', () {
      final Map<String, String> m = buildMpvProperties(
          VideoMpvConfig.defaults.copyWith(hwdec: 'auto-safe', rawConf: 'hwdec=no'));
      expect(m['hwdec'], 'no'); // raw 优先
    });
  });

  group('encode/decode', () {
    test('round-trips all fields', () {
      final VideoMpvConfig c = VideoMpvConfig.defaults.copyWith(
        hwdec: 'auto-copy',
        highQuality: true,
        deband: true,
        dither: true,
        interpolation: true,
        deinterlace: true,
        videoRotate: 180,
        videoZoom: -0.5,
        aspectOverride: '4:3',
        brightness: 5,
        contrast: 6,
        saturation: 7,
        gamma: 8,
        hue: 9,
        sigmoidUpscaling: false,
        correctDownscaling: true,
        panscan: 0.3,
        audioDelayMs: -150,
        audioPitchCorrection: false,
        audioChannels: 'mono',
        normalizeDownmix: true,
        loopFile: true,
        rawConf: 'vo=gpu-next',
      );
      final VideoMpvConfig back =
          VideoMpvConfig.decode(VideoMpvConfig.encode(c));
      expect(back.hwdec, 'auto-copy');
      expect(back.highQuality, isTrue);
      expect(back.deinterlace, isTrue);
      expect(back.videoRotate, 180);
      expect(back.videoZoom, -0.5);
      expect(back.aspectOverride, '4:3');
      expect(back.brightness, 5);
      expect(back.hue, 9);
      expect(back.sigmoidUpscaling, isFalse);
      expect(back.correctDownscaling, isTrue);
      expect(back.panscan, 0.3);
      expect(back.audioDelayMs, -150);
      expect(back.audioPitchCorrection, isFalse);
      expect(back.audioChannels, 'mono');
      expect(back.normalizeDownmix, isTrue);
      expect(back.loopFile, isTrue);
      expect(back.rawConf, 'vo=gpu-next');
    });

    test('decode empty/garbage -> defaults', () {
      expect(VideoMpvConfig.decode('').hwdec, 'no');
      expect(VideoMpvConfig.decode('garbage').rawConf, '');
      expect(VideoMpvConfig.decode('garbage').brightness, 0);
    });

    test('decode clamps out-of-range color/rotate', () {
      final VideoMpvConfig c = VideoMpvConfig.decode(
          '{"brightness":999,"contrast":-999,"videoRotate":45,"videoZoom":99}');
      expect(c.brightness, lessThanOrEqualTo(100));
      expect(c.contrast, greaterThanOrEqualTo(-100));
      expect(<int>[0, 90, 180, 270].contains(c.videoRotate), isTrue);
      expect(c.videoZoom, lessThanOrEqualTo(2.0));
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/media/video/video_mpv_config_test.dart`
Expected: FAIL —— `video_mpv_config.dart` 不存在。

- [ ] **Step 3: 写模型 + 纯函数 + apply**

新建 `hibiki/lib/src/media/video/video_mpv_config.dart`：

```dart
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// 视频播放的 mpv 配置（全局偏好），成体系覆盖解码/画质/画面几何/色彩均衡/播放，
/// 外加原始 mpv.conf 逃生口。
///
/// 经 media_kit 底层 libmpv 的 `setProperty` 应用——与着色器同一边界
/// （见 [applyShadersToPlayer]）。**仅桌面 libmpv 实测可用**；非 libmpv 后端 / 不可
/// 运行时设置的属性（如 `vo`、`profile`）静默 no-op，[rawConf] 是高级逃生口
/// （写得进就生效，写不进就忽略，不报错不黑屏）。
///
/// **不含**：字幕轨/字幕大小/字幕延迟（已由字幕源菜单 + 字幕外观 + A/V 延迟覆盖）、
/// Anime4k（着色器对话框）、SVP/RIFE 帧插值（需外部工具链，非纯 libmpv 属性）。
@immutable
class VideoMpvConfig {
  const VideoMpvConfig({
    required this.hwdec,
    required this.highQuality,
    required this.deband,
    required this.dither,
    required this.interpolation,
    required this.deinterlace,
    required this.videoRotate,
    required this.videoZoom,
    required this.aspectOverride,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.gamma,
    required this.hue,
    required this.sigmoidUpscaling,
    required this.correctDownscaling,
    required this.panscan,
    required this.audioDelayMs,
    required this.audioPitchCorrection,
    required this.audioChannels,
    required this.normalizeDownmix,
    required this.loopFile,
    required this.rawConf,
  });

  /// 每字段取 mpv 自身默认：默认配置下全量 setProperty 与历史行为视觉等价。
  static const VideoMpvConfig defaults = VideoMpvConfig(
    hwdec: 'no',
    highQuality: false,
    deband: false,
    dither: false,
    interpolation: false,
    deinterlace: false,
    videoRotate: 0,
    videoZoom: 0,
    aspectOverride: '-1',
    brightness: 0,
    contrast: 0,
    saturation: 0,
    gamma: 0,
    hue: 0,
    sigmoidUpscaling: true,
    correctDownscaling: false,
    panscan: 0,
    audioDelayMs: 0,
    audioPitchCorrection: true,
    audioChannels: 'auto-safe',
    normalizeDownmix: false,
    loopFile: false,
    rawConf: '',
  );

  /// 硬件解码：`no` | `auto-safe` | `auto-copy`。
  final String hwdec;

  /// 高画质渲染：on → 高质量 scale 链（ewa_lanczossharp 等）；off → bilinear（mpv 默认）。
  final bool highQuality;

  /// 去色带 deband。
  final bool deband;

  /// 抖动：on → `dither-depth=auto`。
  final bool dither;

  /// 运动插帧（平滑流畅度）：on → interpolation + video-sync=display-resample + tscale。
  final bool interpolation;

  /// 去隔行 deinterlace（隔行片源用）。
  final bool deinterlace;

  /// 画面旋转（度）：0/90/180/270。
  final int videoRotate;

  /// 画面缩放（log2，-2..2，0=原始）。
  final double videoZoom;

  /// 画面比例覆盖：`-1`(原始) | `16:9` | `4:3` | `2.35:1` | `1:1`。
  final String aspectOverride;

  /// 色彩均衡（-100..100，0=默认）。
  final int brightness;
  final int contrast;
  final int saturation;
  final int gamma;
  final int hue;

  /// S 形曲线上采样（减少振铃；mpv 默认 yes）。
  final bool sigmoidUpscaling;

  /// 线性光降采样（更准的缩小；mpv 默认 no）。
  final bool correctDownscaling;

  /// 平移裁切 panscan（0..1，0=完整画面，1=填满裁切黑边）。
  final double panscan;

  /// 音频延迟（毫秒，正=音频滞后）→ `audio-delay` 秒。与字幕 A/V 延迟（_delayMs，
  /// 调字幕 cue 时序）正交：本项移真实音频轨。
  final int audioDelayMs;

  /// 音频变速保持音高（mpv 默认 yes）。
  final bool audioPitchCorrection;

  /// 声道布局：`auto-safe` | `stereo`（5.1 下混双声道）| `mono`。
  final String audioChannels;

  /// 下混时做响度归一化（mpv 默认 no）。
  final bool normalizeDownmix;

  /// 单文件循环。
  final bool loopFile;

  /// 原始 mpv.conf 文本（每行 `key=value` 或裸 flag）；优先级高于上面结构化项。
  final String rawConf;

  VideoMpvConfig copyWith({
    String? hwdec,
    bool? highQuality,
    bool? deband,
    bool? dither,
    bool? interpolation,
    bool? deinterlace,
    int? videoRotate,
    double? videoZoom,
    String? aspectOverride,
    int? brightness,
    int? contrast,
    int? saturation,
    int? gamma,
    int? hue,
    bool? sigmoidUpscaling,
    bool? correctDownscaling,
    double? panscan,
    int? audioDelayMs,
    bool? audioPitchCorrection,
    String? audioChannels,
    bool? normalizeDownmix,
    bool? loopFile,
    String? rawConf,
  }) =>
      VideoMpvConfig(
        hwdec: hwdec ?? this.hwdec,
        highQuality: highQuality ?? this.highQuality,
        deband: deband ?? this.deband,
        dither: dither ?? this.dither,
        interpolation: interpolation ?? this.interpolation,
        deinterlace: deinterlace ?? this.deinterlace,
        videoRotate: videoRotate ?? this.videoRotate,
        videoZoom: videoZoom ?? this.videoZoom,
        aspectOverride: aspectOverride ?? this.aspectOverride,
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        gamma: gamma ?? this.gamma,
        hue: hue ?? this.hue,
        sigmoidUpscaling: sigmoidUpscaling ?? this.sigmoidUpscaling,
        correctDownscaling: correctDownscaling ?? this.correctDownscaling,
        panscan: panscan ?? this.panscan,
        audioDelayMs: audioDelayMs ?? this.audioDelayMs,
        audioPitchCorrection:
            audioPitchCorrection ?? this.audioPitchCorrection,
        audioChannels: audioChannels ?? this.audioChannels,
        normalizeDownmix: normalizeDownmix ?? this.normalizeDownmix,
        loopFile: loopFile ?? this.loopFile,
        rawConf: rawConf ?? this.rawConf,
      );

  static String encode(VideoMpvConfig c) => jsonEncode(<String, dynamic>{
        'hwdec': c.hwdec,
        'highQuality': c.highQuality,
        'deband': c.deband,
        'dither': c.dither,
        'interpolation': c.interpolation,
        'deinterlace': c.deinterlace,
        'videoRotate': c.videoRotate,
        'videoZoom': c.videoZoom,
        'aspectOverride': c.aspectOverride,
        'brightness': c.brightness,
        'contrast': c.contrast,
        'saturation': c.saturation,
        'gamma': c.gamma,
        'hue': c.hue,
        'sigmoidUpscaling': c.sigmoidUpscaling,
        'correctDownscaling': c.correctDownscaling,
        'panscan': c.panscan,
        'audioDelayMs': c.audioDelayMs,
        'audioPitchCorrection': c.audioPitchCorrection,
        'audioChannels': c.audioChannels,
        'normalizeDownmix': c.normalizeDownmix,
        'loopFile': c.loopFile,
        'rawConf': c.rawConf,
      });

  static VideoMpvConfig decode(String? json) {
    if (json == null || json.isEmpty) return defaults;
    try {
      final dynamic d = jsonDecode(json);
      if (d is! Map) return defaults;
      int clampInt(Object? v, int fb, int lo, int hi) =>
          (v is num ? v.toInt() : fb).clamp(lo, hi);
      const Set<int> rotates = <int>{0, 90, 180, 270};
      const Set<String> hwdecs = <String>{'no', 'auto-safe', 'auto-copy'};
      final int rot = d['videoRotate'] is num
          ? (d['videoRotate'] as num).toInt()
          : 0;
      final String hw =
          d['hwdec'] is String ? d['hwdec'] as String : 'no';
      const Set<String> channels = <String>{'auto-safe', 'stereo', 'mono'};
      final String ch =
          d['audioChannels'] is String ? d['audioChannels'] as String : 'auto-safe';
      return VideoMpvConfig(
        hwdec: hwdecs.contains(hw) ? hw : 'no',
        highQuality: d['highQuality'] == true,
        deband: d['deband'] == true,
        dither: d['dither'] == true,
        interpolation: d['interpolation'] == true,
        deinterlace: d['deinterlace'] == true,
        videoRotate: rotates.contains(rot) ? rot : 0,
        videoZoom: (d['videoZoom'] is num
                ? (d['videoZoom'] as num).toDouble()
                : 0.0)
            .clamp(-2.0, 2.0),
        aspectOverride:
            d['aspectOverride'] is String ? d['aspectOverride'] as String : '-1',
        brightness: clampInt(d['brightness'], 0, -100, 100),
        contrast: clampInt(d['contrast'], 0, -100, 100),
        saturation: clampInt(d['saturation'], 0, -100, 100),
        gamma: clampInt(d['gamma'], 0, -100, 100),
        hue: clampInt(d['hue'], 0, -100, 100),
        sigmoidUpscaling: d['sigmoidUpscaling'] != false, // 默认 true
        correctDownscaling: d['correctDownscaling'] == true,
        panscan: (d['panscan'] is num ? (d['panscan'] as num).toDouble() : 0.0)
            .clamp(0.0, 1.0),
        audioDelayMs: clampInt(d['audioDelayMs'], 0, -60000, 60000),
        audioPitchCorrection: d['audioPitchCorrection'] != false, // 默认 true
        audioChannels: channels.contains(ch) ? ch : 'auto-safe',
        normalizeDownmix: d['normalizeDownmix'] == true,
        loopFile: d['loopFile'] == true,
        rawConf: d['rawConf'] is String ? d['rawConf'] as String : '',
      );
    } catch (_) {
      return defaults;
    }
  }
}

/// 解析 mpv.conf 风格文本为 `属性名→值` map。纯函数。
///
/// 规则：忽略空行与 `#` 注释行；`key=value` 去首尾空白并剥外层引号；裸 `key`（无 `=`）
/// 当作 `key=yes`（mpv flag 语义）。重复 key 后者覆盖。
Map<String, String> parseMpvConf(String text) {
  final Map<String, String> out = <String, String>{};
  for (final String rawLine in text.split('\n')) {
    final String line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final int eq = line.indexOf('=');
    if (eq < 0) {
      out[line] = 'yes';
      continue;
    }
    final String key = line.substring(0, eq).trim();
    if (key.isEmpty) continue;
    String value = line.substring(eq + 1).trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    out[key] = value;
  }
  return out;
}

/// 把 [config] 构建成要 setProperty 的 `属性名→值` map。纯函数。
///
/// **全量 emit**（含中性默认值）：保证设置面板关掉某项时能在运行时复位回 mpv 默认，
/// 而非残留。默认配置下所有值等于 mpv 默认 → 视觉等价于「什么都没设」。raw 最后合并、
/// 同 key 覆盖结构化项。
Map<String, String> buildMpvProperties(VideoMpvConfig config) {
  final Map<String, String> out = <String, String>{};
  // 解码
  out['hwdec'] = config.hwdec;
  // 画质：scale 链（on=高质量 / off=mpv 默认 bilinear，便于运行时复位）
  if (config.highQuality) {
    out['scale'] = 'ewa_lanczossharp';
    out['cscale'] = 'ewa_lanczossharp';
    out['dscale'] = 'mitchell';
    out['scale-antiring'] = '0.7';
    out['cscale-antiring'] = '0.7';
  } else {
    out['scale'] = 'bilinear';
    out['cscale'] = 'bilinear';
    out['dscale'] = 'bilinear';
    out['scale-antiring'] = '0';
    out['cscale-antiring'] = '0';
  }
  out['deband'] = config.deband ? 'yes' : 'no';
  out['dither-depth'] = config.dither ? 'auto' : 'no';
  if (config.interpolation) {
    out['interpolation'] = 'yes';
    out['video-sync'] = 'display-resample';
    out['tscale'] = 'oversample';
  } else {
    out['interpolation'] = 'no';
    out['video-sync'] = 'audio';
  }
  out['deinterlace'] = config.deinterlace ? 'yes' : 'no';
  out['sigmoid-upscaling'] = config.sigmoidUpscaling ? 'yes' : 'no';
  out['correct-downscaling'] = config.correctDownscaling ? 'yes' : 'no';
  // 画面几何
  out['video-rotate'] = config.videoRotate.toString();
  out['video-zoom'] = config.videoZoom.toString();
  out['video-aspect-override'] = config.aspectOverride;
  out['panscan'] = config.panscan.toString();
  // 色彩均衡
  out['brightness'] = config.brightness.toString();
  out['contrast'] = config.contrast.toString();
  out['saturation'] = config.saturation.toString();
  out['gamma'] = config.gamma.toString();
  out['hue'] = config.hue.toString();
  // 音频
  out['audio-delay'] = (config.audioDelayMs / 1000).toString(); // 秒
  out['audio-pitch-correction'] = config.audioPitchCorrection ? 'yes' : 'no';
  out['audio-channels'] = config.audioChannels;
  out['audio-normalize-downmix'] = config.normalizeDownmix ? 'yes' : 'no';
  // 播放
  out['loop-file'] = config.loopFile ? 'inf' : 'no';
  // 原始 mpv.conf：最后合并，同 key 覆盖结构化项
  out.addAll(parseMpvConf(config.rawConf));
  return out;
}

/// 把 [config] 应用到 media_kit [player]（仅 libmpv 后端/桌面生效）。
///
/// best-effort：`player.platform` 非 libmpv（无 setProperty）或某属性不被接受时
/// 单条静默吞掉，不影响其余属性与播放。与 [applyShadersToPlayer] 同范式。
Future<void> applyMpvConfigToPlayer(
    Player player, VideoMpvConfig config) async {
  final dynamic native = player.platform;
  if (native == null) return;
  final Map<String, String> props = buildMpvProperties(config);
  for (final MapEntry<String, String> e in props.entries) {
    try {
      await native.setProperty(e.key, e.value);
    } catch (_) {
      // 非 libmpv / 该属性不支持运行时设置：跳过这条，继续下一条。
    }
  }
}
```

- [ ] **Step 4: 运行测试通过**

Run: `cd hibiki && flutter test test/media/video/video_mpv_config_test.dart`
Expected: PASS（全部用例）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/media/video/video_mpv_config.dart hibiki/test/media/video/video_mpv_config_test.dart
git commit -m "feat(video): structured mpv config model + conf parser (pure)"
```

### Task C2：偏好 + app_model + load 时应用

**Files:**
- Modify: `hibiki/lib/src/models/preferences_repository.dart`
- Modify: `hibiki/lib/src/models/app_model.dart`
- Modify: `hibiki/lib/src/media/video/video_player_controller.dart`
- Modify: `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`

- [ ] **Step 1: 偏好（紧跟 `setVideoSubtitleStyle` 后）**

```dart
  /// 视频 mpv 画质/解码配置（JSON；解析见 VideoMpvConfig.encode/decode）。空串=默认全关。
  String get videoMpvConfig =>
      getPref('video_mpv_config', defaultValue: '') as String;

  Future<void> setVideoMpvConfig(String json) async {
    await setPref('video_mpv_config', json);
    notifyListeners();
  }
```

- [ ] **Step 2: app_model 透出**

```dart
  String get videoMpvConfig => prefsRepo.videoMpvConfig;

  Future<void> setVideoMpvConfig(String json) =>
      prefsRepo.setVideoMpvConfig(json);
```

- [ ] **Step 3: controller 加运行时应用 + load 入参**

在 `video_player_controller.dart` 顶部 import：

```dart
import 'package:hibiki/src/media/video/video_mpv_config.dart';
```

加字段（紧跟 `_shaderPaths` 字段后）：

```dart
  /// 当前 mpv 配置（[load] 复用 / [applyMpvConfig] 实时切换）。
  VideoMpvConfig _mpvConfig = VideoMpvConfig.defaults;
```

加运行时切换方法（紧跟 `applyShaders` 后）：

```dart
  /// 运行时应用 mpv 配置（设置面板改动即时生效）。未 [load] 时只记下，下次 [load] 应用。
  /// 仅桌面 libmpv 真正生效；移动端/不支持的属性静默 no-op。
  Future<void> applyMpvConfig(VideoMpvConfig config) async {
    _mpvConfig = config;
    final Player? player = _player;
    if (player == null) return;
    await applyMpvConfigToPlayer(player, config);
  }
```

在 `load` 签名加可选参数（紧跟 `shaderPaths` 参数后）：

```dart
    VideoMpvConfig mpvConfig = VideoMpvConfig.defaults,
```

在 `load` 体内、`applyShadersToPlayer(player, _shaderPaths);`（约 `:219`）之后插入：

```dart
    // 应用 mpv 画质/解码配置（桌面 libmpv 生效；移动端/不支持属性静默 no-op）。
    _mpvConfig = mpvConfig;
    await applyMpvConfigToPlayer(player, _mpvConfig);
```

- [ ] **Step 4: 页面 _applyLoad 传入 mpv 配置**

在 `video_hibiki_page.dart` 顶部 import：

```dart
import 'package:hibiki/src/media/video/video_mpv_config.dart';
```

在 `_applyLoad`（`video_hibiki_page.dart:431` 解析 shaderPaths 之后）加：

```dart
    final VideoMpvConfig mpvConfig =
        VideoMpvConfig.decode(appModel.videoMpvConfig);
```

并把 `controller.load(...)` 调用加一行入参：

```dart
        mpvConfig: mpvConfig,
```

- [ ] **Step 5: 验证编译 + controller/video 测试**

Run: `cd hibiki && flutter analyze lib/src/media/video/ lib/src/models/ lib/src/pages/implementations/video_hibiki_page.dart && flutter test test/media/video/`
Expected: 0 issue；测试全绿（load 不被单测触发，纯函数已覆盖）。

- [ ] **Step 6: Commit**

```bash
git add hibiki/lib/src/models/ hibiki/lib/src/media/video/video_player_controller.dart hibiki/lib/src/pages/implementations/video_hibiki_page.dart
git commit -m "feat(video): apply mpv config on load + runtime switch"
```

### Task C3：i18n（mpv 配置）

- [ ] **Step 1: 加 key**

Run（`hibiki/` 下）:

```bash
dart run tool/i18n_sync.dart --add video_setting_mpv "Video settings (mpv)" "视频设置 (mpv)"
dart run tool/i18n_sync.dart --add video_setting_mpv_open "Video settings (mpv)" "视频设置 (mpv)"
# 分组标题
dart run tool/i18n_sync.dart --add video_setting_mpv_group_decode "Decoding" "解码"
dart run tool/i18n_sync.dart --add video_setting_mpv_group_quality "Image quality" "画质"
dart run tool/i18n_sync.dart --add video_setting_mpv_group_geometry "Geometry" "画面"
dart run tool/i18n_sync.dart --add video_setting_mpv_group_color "Color" "色彩"
dart run tool/i18n_sync.dart --add video_setting_mpv_group_playback "Playback" "播放"
dart run tool/i18n_sync.dart --add video_setting_mpv_group_advanced "Advanced" "高级"
# 解码
dart run tool/i18n_sync.dart --add video_setting_mpv_hwdec "Hardware decoding" "硬件解码"
dart run tool/i18n_sync.dart --add video_setting_mpv_hwdec_off "Off" "关闭"
dart run tool/i18n_sync.dart --add video_setting_mpv_hwdec_auto "Auto (safe)" "自动（安全）"
dart run tool/i18n_sync.dart --add video_setting_mpv_hwdec_copy "Auto (copy)" "自动（复制）"
# 画质
dart run tool/i18n_sync.dart --add video_setting_mpv_high_quality "High-quality scaling" "高画质缩放"
dart run tool/i18n_sync.dart --add video_setting_mpv_deband "Debanding" "去色带"
dart run tool/i18n_sync.dart --add video_setting_mpv_dither "Dithering" "抖动"
dart run tool/i18n_sync.dart --add video_setting_mpv_interpolation "Motion interpolation" "运动插帧"
dart run tool/i18n_sync.dart --add video_setting_mpv_deinterlace "Deinterlace" "去隔行"
dart run tool/i18n_sync.dart --add video_setting_mpv_sigmoid "Sigmoid upscaling" "S形上采样"
dart run tool/i18n_sync.dart --add video_setting_mpv_correct_downscale "Linear downscaling" "线性降采样"
# 画面几何
dart run tool/i18n_sync.dart --add video_setting_mpv_rotate "Rotation" "旋转"
dart run tool/i18n_sync.dart --add video_setting_mpv_zoom "Zoom" "缩放"
dart run tool/i18n_sync.dart --add video_setting_mpv_panscan "Pan & scan (crop borders)" "平移裁切（去黑边）"
dart run tool/i18n_sync.dart --add video_setting_mpv_aspect "Aspect ratio" "画面比例"
dart run tool/i18n_sync.dart --add video_setting_mpv_aspect_auto "Original" "原始"
# 音频
dart run tool/i18n_sync.dart --add video_setting_mpv_group_audio "Audio" "音频"
dart run tool/i18n_sync.dart --add video_setting_mpv_audio_delay "Audio delay (ms)" "音频延迟 (ms)"
dart run tool/i18n_sync.dart --add video_setting_mpv_pitch "Preserve pitch when speeding" "变速保持音高"
dart run tool/i18n_sync.dart --add video_setting_mpv_channels "Channels" "声道"
dart run tool/i18n_sync.dart --add video_setting_mpv_channels_auto "Auto" "自动"
dart run tool/i18n_sync.dart --add video_setting_mpv_channels_stereo "Stereo (downmix)" "立体声（下混）"
dart run tool/i18n_sync.dart --add video_setting_mpv_channels_mono "Mono" "单声道"
dart run tool/i18n_sync.dart --add video_setting_mpv_normalize "Normalize downmix loudness" "下混响度归一化"
# 色彩
dart run tool/i18n_sync.dart --add video_setting_mpv_brightness "Brightness" "亮度"
dart run tool/i18n_sync.dart --add video_setting_mpv_contrast "Contrast" "对比度"
dart run tool/i18n_sync.dart --add video_setting_mpv_saturation "Saturation" "饱和度"
dart run tool/i18n_sync.dart --add video_setting_mpv_gamma "Gamma" "Gamma"
dart run tool/i18n_sync.dart --add video_setting_mpv_hue "Hue" "色相"
# 播放
dart run tool/i18n_sync.dart --add video_setting_mpv_loop "Loop file" "单文件循环"
# 高级 + 复位
dart run tool/i18n_sync.dart --add video_setting_mpv_raw "Extra mpv options (one per line, key=value)" "额外 mpv 选项（每行 key=value）"
dart run tool/i18n_sync.dart --add video_setting_mpv_raw_hint "Desktop only; options that cannot apply at runtime (e.g. vo, profile) are ignored. SVP/RIFE need external tools and are not supported." "仅桌面生效；运行时无法应用的项（如 vo、profile）会被忽略。SVP/RIFE 需外部工具，不支持。"
dart run tool/i18n_sync.dart --add video_setting_mpv_reset "Reset all" "全部恢复默认"
```

- [ ] **Step 2: 重新生成 + 格式化 + i18n 测试**

Run: `cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart && flutter test test/i18n/`
Expected: 无缺 key 报错；i18n 测试 pass。

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/i18n/
git commit -m "i18n(video): add mpv config strings"
```

### Task C4：mpv 配置对话框 + 设置面板入口

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`

- [ ] **Step 1: 设置面板加「画质与解码」入口按钮**

在 `_showPlayerSettings` 着色器按钮旁/下方加一个 OutlinedButton（同款样式）：

```dart
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                        ),
                        icon: const Icon(Icons.tune),
                        label: Text(t.video_setting_mpv_open),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openMpvConfigDialog();
                        },
                      ),
                    ),
```

- [ ] **Step 2: 加 `_openMpvConfigDialog`（分类表单，仿 `_openShaderDialog`）**

在 `_openShaderDialog` 之后加。对话框内容用 `SingleChildScrollView`（项多），按 解码/画质/画面/色彩/播放/高级 分组，每组一个小标题。helper 抽两个内联构建器减少重复：

```dart
  /// 打开 mpv 视频配置对话框：成体系的解码/画质/画面/色彩/播放分组 + 原始 mpv.conf
  /// 框 → 保存时持久化 + 实时应用到当前播放器（桌面 libmpv 生效，移动端/不支持属性静默）。
  Future<void> _openMpvConfigDialog() async {
    VideoMpvConfig cfg = VideoMpvConfig.decode(appModel.videoMpvConfig);
    final TextEditingController rawCtrl =
        TextEditingController(text: cfg.rawConf);
    await showDialog<void>(
      context: context,
      builder: (BuildContext dctx) => StatefulBuilder(
        builder: (BuildContext dctx, StateSetter setD) {
          Widget header(String text) => Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 2),
                child: Text(text,
                    style: Theme.of(dctx)
                        .textTheme
                        .labelLarge
                        ?.copyWith(color: Theme.of(dctx).colorScheme.primary)),
              );
          Widget toggle(String label, bool value, ValueChanged<bool> onCh) =>
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(label),
                value: value,
                onChanged: (bool v) => setD(() => onCh(v)),
              );
          Widget slider(String label, int value, ValueChanged<int> onCh) => Row(
                children: <Widget>[
                  SizedBox(width: 84, child: Text(label)),
                  Expanded(
                    child: Slider(
                      min: -100,
                      max: 100,
                      divisions: 200,
                      label: '$value',
                      value: value.toDouble(),
                      onChanged: (double v) => setD(() => onCh(v.round())),
                    ),
                  ),
                  SizedBox(width: 36, child: Text('$value')),
                ],
              );

          return AlertDialog(
            title: Text(t.video_setting_mpv),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    // ── 解码 ──
                    header(t.video_setting_mpv_group_decode),
                    DropdownButtonFormField<String>(
                      initialValue: cfg.hwdec,
                      decoration: InputDecoration(
                          labelText: t.video_setting_mpv_hwdec, isDense: true),
                      items: <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                            value: 'no',
                            child: Text(t.video_setting_mpv_hwdec_off)),
                        DropdownMenuItem<String>(
                            value: 'auto-safe',
                            child: Text(t.video_setting_mpv_hwdec_auto)),
                        DropdownMenuItem<String>(
                            value: 'auto-copy',
                            child: Text(t.video_setting_mpv_hwdec_copy)),
                      ],
                      onChanged: (String? v) =>
                          setD(() => cfg = cfg.copyWith(hwdec: v ?? 'no')),
                    ),
                    // ── 画质 ──
                    header(t.video_setting_mpv_group_quality),
                    toggle(t.video_setting_mpv_high_quality, cfg.highQuality,
                        (bool v) => cfg = cfg.copyWith(highQuality: v)),
                    toggle(t.video_setting_mpv_deband, cfg.deband,
                        (bool v) => cfg = cfg.copyWith(deband: v)),
                    toggle(t.video_setting_mpv_dither, cfg.dither,
                        (bool v) => cfg = cfg.copyWith(dither: v)),
                    toggle(t.video_setting_mpv_interpolation, cfg.interpolation,
                        (bool v) => cfg = cfg.copyWith(interpolation: v)),
                    toggle(t.video_setting_mpv_deinterlace, cfg.deinterlace,
                        (bool v) => cfg = cfg.copyWith(deinterlace: v)),
                    toggle(t.video_setting_mpv_sigmoid, cfg.sigmoidUpscaling,
                        (bool v) => cfg = cfg.copyWith(sigmoidUpscaling: v)),
                    toggle(
                        t.video_setting_mpv_correct_downscale,
                        cfg.correctDownscaling,
                        (bool v) => cfg = cfg.copyWith(correctDownscaling: v)),
                    // ── 画面几何 ──
                    header(t.video_setting_mpv_group_geometry),
                    DropdownButtonFormField<int>(
                      initialValue: cfg.videoRotate,
                      decoration: InputDecoration(
                          labelText: t.video_setting_mpv_rotate, isDense: true),
                      items: const <int>[0, 90, 180, 270]
                          .map((int d) => DropdownMenuItem<int>(
                              value: d, child: Text('$d°')))
                          .toList(),
                      onChanged: (int? v) =>
                          setD(() => cfg = cfg.copyWith(videoRotate: v ?? 0)),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: cfg.aspectOverride,
                      decoration: InputDecoration(
                          labelText: t.video_setting_mpv_aspect, isDense: true),
                      items: <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                            value: '-1',
                            child: Text(t.video_setting_mpv_aspect_auto)),
                        const DropdownMenuItem<String>(
                            value: '16:9', child: Text('16:9')),
                        const DropdownMenuItem<String>(
                            value: '4:3', child: Text('4:3')),
                        const DropdownMenuItem<String>(
                            value: '2.35:1', child: Text('2.35:1')),
                        const DropdownMenuItem<String>(
                            value: '1:1', child: Text('1:1')),
                      ],
                      onChanged: (String? v) => setD(
                          () => cfg = cfg.copyWith(aspectOverride: v ?? '-1')),
                    ),
                    Row(children: <Widget>[
                      SizedBox(
                          width: 84, child: Text(t.video_setting_mpv_zoom)),
                      Expanded(
                        child: Slider(
                          min: -2,
                          max: 2,
                          divisions: 40,
                          label: cfg.videoZoom.toStringAsFixed(2),
                          value: cfg.videoZoom,
                          onChanged: (double v) =>
                              setD(() => cfg = cfg.copyWith(videoZoom: v)),
                        ),
                      ),
                    ]),
                    Row(children: <Widget>[
                      SizedBox(
                          width: 84,
                          child: Text(t.video_setting_mpv_panscan)),
                      Expanded(
                        child: Slider(
                          min: 0,
                          max: 1,
                          divisions: 20,
                          label: cfg.panscan.toStringAsFixed(2),
                          value: cfg.panscan,
                          onChanged: (double v) =>
                              setD(() => cfg = cfg.copyWith(panscan: v)),
                        ),
                      ),
                    ]),
                    // ── 色彩均衡 ──
                    header(t.video_setting_mpv_group_color),
                    slider(t.video_setting_mpv_brightness, cfg.brightness,
                        (int v) => cfg = cfg.copyWith(brightness: v)),
                    slider(t.video_setting_mpv_contrast, cfg.contrast,
                        (int v) => cfg = cfg.copyWith(contrast: v)),
                    slider(t.video_setting_mpv_saturation, cfg.saturation,
                        (int v) => cfg = cfg.copyWith(saturation: v)),
                    slider(t.video_setting_mpv_gamma, cfg.gamma,
                        (int v) => cfg = cfg.copyWith(gamma: v)),
                    slider(t.video_setting_mpv_hue, cfg.hue,
                        (int v) => cfg = cfg.copyWith(hue: v)),
                    // ── 音频 ──
                    header(t.video_setting_mpv_group_audio),
                    Row(children: <Widget>[
                      SizedBox(
                          width: 84,
                          child: Text(t.video_setting_mpv_audio_delay)),
                      Expanded(
                        child: Slider(
                          min: -2000,
                          max: 2000,
                          divisions: 80,
                          label: '${cfg.audioDelayMs}',
                          value: cfg.audioDelayMs.toDouble().clamp(-2000, 2000),
                          onChanged: (double v) => setD(
                              () => cfg = cfg.copyWith(audioDelayMs: v.round())),
                        ),
                      ),
                      SizedBox(width: 44, child: Text('${cfg.audioDelayMs}')),
                    ]),
                    toggle(t.video_setting_mpv_pitch, cfg.audioPitchCorrection,
                        (bool v) =>
                            cfg = cfg.copyWith(audioPitchCorrection: v)),
                    DropdownButtonFormField<String>(
                      initialValue: cfg.audioChannels,
                      decoration: InputDecoration(
                          labelText: t.video_setting_mpv_channels,
                          isDense: true),
                      items: <DropdownMenuItem<String>>[
                        DropdownMenuItem<String>(
                            value: 'auto-safe',
                            child: Text(t.video_setting_mpv_channels_auto)),
                        DropdownMenuItem<String>(
                            value: 'stereo',
                            child: Text(t.video_setting_mpv_channels_stereo)),
                        DropdownMenuItem<String>(
                            value: 'mono',
                            child: Text(t.video_setting_mpv_channels_mono)),
                      ],
                      onChanged: (String? v) => setD(() =>
                          cfg = cfg.copyWith(audioChannels: v ?? 'auto-safe')),
                    ),
                    toggle(t.video_setting_mpv_normalize, cfg.normalizeDownmix,
                        (bool v) => cfg = cfg.copyWith(normalizeDownmix: v)),
                    // ── 播放 ──
                    header(t.video_setting_mpv_group_playback),
                    toggle(t.video_setting_mpv_loop, cfg.loopFile,
                        (bool v) => cfg = cfg.copyWith(loopFile: v)),
                    // ── 高级：原始 mpv.conf ──
                    header(t.video_setting_mpv_group_advanced),
                    TextField(
                      controller: rawCtrl,
                      minLines: 3,
                      maxLines: 8,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 13),
                      decoration: InputDecoration(
                        labelText: t.video_setting_mpv_raw,
                        helperText: t.video_setting_mpv_raw_hint,
                        helperMaxLines: 4,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () =>
                    setD(() => cfg = VideoMpvConfig.defaults),
                child: Text(t.video_setting_mpv_reset),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: Text(t.dialog_cancel),
              ),
              FilledButton(
                onPressed: () async {
                  final VideoMpvConfig finalCfg =
                      cfg.copyWith(rawConf: rawCtrl.text);
                  await appModel
                      .setVideoMpvConfig(VideoMpvConfig.encode(finalCfg));
                  await _controller?.applyMpvConfig(finalCfg);
                  if (dctx.mounted) Navigator.pop(dctx);
                },
                child: Text(t.dialog_save),
              ),
            ],
          );
        },
      ),
    );
    rawCtrl.dispose();
    _refocusVideo();
  }
```

> 注意：「全部恢复默认」按钮只 `setD` 把 `cfg` 重置为 `defaults` 但**不重置 rawCtrl 文本**——若也要清空 raw 框，在该按钮里加 `rawCtrl.clear()`。`DropdownButtonFormField.initialValue` 是 Flutter 3.x API（旧版叫 `value`，实现时按 analyze 报错二选一）。复用既有 i18n key `t.dialog_cancel` / `t.dialog_save`（若 `dialog_save` 不存在，grep 现有 key，用 `t.dialog_ok` 或新增）。

- [ ] **Step 3: 验证编译 + 测试**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/video_hibiki_page.dart && flutter test test/media/video/`
Expected: 0 issue；video 测试全绿。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/pages/implementations/video_hibiki_page.dart
git commit -m "feat(video): mpv config dialog (toggles + raw conf editor)"
```

---

## Feature D：Jimaku 字幕二次关键词筛选

asbplayer：搜到作品后字幕文件多时，用 Netflix/WEBRip/BD 等关键词二次筛选列表。Hibiki 的 `JimakuSubtitleDialog` 已有 API key 记忆 + 番名预填，缺的只是候选列表的二次过滤。

### Task D1：纯函数筛选 + 测试

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`
- Test: `hibiki/test/pages/jimaku_filter_test.dart`

- [ ] **Step 1: 写失败测试**

新建 `hibiki/test/pages/jimaku_filter_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/jimaku_subtitle_dialog.dart';

void main() {
  test('empty keyword keeps all', () {
    final List<String> names = <String>['a.WEBRip.srt', 'b.BD.ass'];
    expect(filterByKeyword(names, '', (String s) => s), names);
  });

  test('case-insensitive substring match', () {
    final List<String> names = <String>['a.WEBRip.srt', 'b.BD.ass', 'c.srt'];
    final List<String> out = filterByKeyword(names, 'webrip', (String s) => s);
    expect(out, <String>['a.WEBRip.srt']);
  });

  test('whitespace-only keyword keeps all', () {
    final List<String> names = <String>['x', 'y'];
    expect(filterByKeyword(names, '   ', (String s) => s), names);
  });
}
```

- [ ] **Step 2: 运行确认失败**

Run: `cd hibiki && flutter test test/pages/jimaku_filter_test.dart`
Expected: FAIL —— `filterByKeyword` 未定义。

- [ ] **Step 3: 在 jimaku_subtitle_dialog.dart 顶部加纯函数（类外，可 import）**

在文件 import 之后、`_Candidate` 类之前插入：

```dart
/// 按关键词（大小写不敏感子串）筛选列表；空/纯空白关键词原样返回。纯函数，便于单测。
List<T> filterByKeyword<T>(
    List<T> items, String keyword, String Function(T) text) {
  final String kw = keyword.trim().toLowerCase();
  if (kw.isEmpty) return items;
  return items
      .where((T it) => text(it).toLowerCase().contains(kw))
      .toList(growable: false);
}
```

- [ ] **Step 4: 运行测试通过**

Run: `cd hibiki && flutter test test/pages/jimaku_filter_test.dart`
Expected: PASS（3 用例）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart hibiki/test/pages/jimaku_filter_test.dart
git commit -m "feat(video): jimaku candidate keyword filter (pure fn)"
```

### Task D2：对话框接入筛选框

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart`
- Modify: `hibiki/lib/i18n/*.i18n.json`

- [ ] **Step 1: i18n key**

Run（`hibiki/` 下）:

```bash
dart run tool/i18n_sync.dart --add video_jimaku_filter "Filter results (e.g. WEBRip, BD)" "筛选结果（如 WEBRip、BD）"
dart run tool/i18n_sync.dart && dart run slang && dart format lib/i18n/strings.g.dart
```

- [ ] **Step 2: 对话框加筛选框 state + UI**

在 `_JimakuSubtitleDialogState` 加字段：

```dart
  String _filter = '';
```

在 `build` 的候选 `ListView.builder` 之前（`_candidates.isNotEmpty` 分支内、`Flexible` 之前）插入筛选输入框，并把列表数据源改为筛选后：

```dart
            else if (_candidates.isNotEmpty) ...<Widget>[
              TextField(
                decoration: InputDecoration(
                  labelText: t.video_jimaku_filter,
                  isDense: true,
                  prefixIcon: const Icon(Icons.filter_list, size: 18),
                ),
                onChanged: (String v) => setState(() => _filter = v),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Builder(builder: (BuildContext context) {
                  final List<_Candidate> shown = filterByKeyword(
                      _candidates, _filter, (_Candidate c) => c.file.name);
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: shown.length,
                    itemBuilder: (BuildContext context, int i) {
                      final _Candidate c = shown[i];
                      final bool busy = _busyName == c.file.name;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        leading: const Icon(Icons.subtitles_outlined),
                        title:
                            Text(c.file.name, overflow: TextOverflow.ellipsis),
                        subtitle:
                            Text(c.entryName, overflow: TextOverflow.ellipsis),
                        trailing: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.download),
                        onTap: _busyName == null ? () => _download(c) : null,
                      );
                    },
                  );
                }),
              ),
            ],
```

（即把原 `else if (_candidates.isNotEmpty) Flexible(...)` 整段替换为上面的 `...<Widget>[ ... ]` spread。）

- [ ] **Step 3: 验证编译 + i18n + dialog 测试**

Run: `cd hibiki && flutter analyze lib/src/pages/implementations/jimaku_subtitle_dialog.dart && flutter test test/i18n/ test/pages/jimaku_filter_test.dart`
Expected: 0 issue；测试全绿。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/pages/implementations/jimaku_subtitle_dialog.dart hibiki/lib/i18n/
git commit -m "feat(video): jimaku result filter field + i18n"
```

---

## 收尾：全量验证 + 审查

- [ ] **Step 1: 全量 analyze + test**

Run: `cd hibiki && dart format . && flutter analyze && flutter test`
Expected: analyze 0 issue；全量测试全绿（重点确认 `test/media/video/` 既有 cue/gap 用例不回归）。

- [ ] **Step 2: 真机/桌面验证清单（声明「修好了」前必做，见 CLAUDE.md「验证」）**

需在真实桌面（Windows，libmpv 可用）验证：
- 开启字幕模糊 → 字幕默认打码；鼠标悬停变清晰、移开复原；移动端点字幕区显形；按 `B` 切换开关。
- 关闭字幕模糊（默认）→ 字幕与历史完全一致（白字、黑底、底距 72）。
- 字幕外观：调字号/背景透明度/位置 → overlay 即时生效并跨重开保留。
- mpv 配置：逐项验证——hwdec 切自动/复制、高画质/去色带/抖动/运动插帧/去隔行、旋转/缩放/比例、亮度/对比度/饱和度/gamma/色相、单文件循环；raw 框写 `vo=gpu-next` 等 → 不黑屏、不报错；运行时可设的肉眼/日志可见生效，设不进的（vo/profile）静默忽略；关掉某项后画面复位回默认（验证全量 emit 的复位语义）。
- Jimaku：搜出多文件后用关键词二次筛选列表正常。

- [ ] **Step 3: 代码审查**

按 CLAUDE.md 步骤 3 调 `superpowers:requesting-code-review` 启动 code-reviewer agent 审查本轮全部改动（实现是否符合计划、边界、向后兼容；重点：默认关闭/默认外观等价、setProperty best-effort 降级、i18n 17 文件完整、测试在最强可落地层）。Critical/High 修复后重新审查。

---

## Self-Review（计划自检）

- **Spec 覆盖**：①字幕模糊（A）②mpv 配置开关+raw（C）③字幕外观（B）④Jimaku 搜索增强（D）——四块均有任务；用户「默认不开启、默认字幕跟现状一样」由 A1 默认 false + B1 `defaults` 等于历史硬编码值保证。
- **Placeholder 扫描**：每个 code step 均给出完整代码；无 TODO/TBD。
- **类型一致性**：`VideoSubtitleStyle`（fontSize/textColor/backgroundOpacity/bottomPadding，含 `defaults`/`copyWith`/`encode`/`decode`）、`VideoMpvConfig`（23 字段：hwdec(String)/highQuality/deband/dither/interpolation/deinterlace/sigmoidUpscaling/correctDownscaling/videoRotate/videoZoom/aspectOverride/panscan/brightness/contrast/saturation/gamma/hue/audioDelayMs/audioPitchCorrection/audioChannels/normalizeDownmix/loopFile/rawConf，含 `defaults`/`copyWith`/`encode`/`decode`）、`parseMpvConf`/`buildMpvProperties`/`applyMpvConfigToPlayer`、`filterByKeyword<T>`——跨任务命名一致；C1 测试、C4 对话框、C2 controller.load 均按此 23 字段签名。overlay 新签名（blurEnabled/fontSize/textColor/backgroundOpacity/bottomPadding）在 A2 定义、A4/B4 调用一致。
- **已知实现期需现场核对项（非阻塞）**：
  1. media_kit controls theme 是否支持自定义 `keyboardShortcuts`（A4-Step3 给了 `CallbackShortcuts` 回退）。
  2. `Color.toARGB32()`/`withValues` 是否当前 Flutter 版本可用（给了 `.value`/`.withOpacity` 回退）。
  3. `t.dialog_save` 是否存在（C4-Step2 注明 grep 确认，否则用 `dialog_ok` 或新增）。
