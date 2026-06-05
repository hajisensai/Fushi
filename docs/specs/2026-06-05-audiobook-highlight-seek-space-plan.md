# 有声书三连修：高亮偏移 / 从本句播放三段跳 / 空格暂停 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans。Steps 用 `- [ ]` 勾选框追踪。

**Goal:** 根治三个有声书 bug：(A) 阅读器音频高亮随阅读累积偏移（~1 万字处偏 2 字）；(B)「从本句播放」先跳音频开头→章节开头→才到正确位置（三段跳）；(C) 阅读器焦点下按空格翻页，有声书场景应为暂停。

**Architecture（核心取舍）:**
- **A**：当前高亮坐标由 Dart `package:html`（`chapterPlainText`）数出的归一化字符偏移定义，却在**浏览器实时 DOM** 上消费；两套抽取靠手工镜像规则对齐（白名单已验证三份一致，但 `package:html` 与真 DOM 的字符序列仍会差几个字）。更糟的是 `collectSasayakiCueRanges` 用**单一单调 cursor** 从 body 头累加，任意一处差 2 字就把**其后所有 cue** 整体推移 → 表现为「越往后偏越多」。根治：**让实时 DOM 成为唯一坐标权威**——存的偏移降级为「提示位置」，JS 用 cue 自带文本在 DOM 归一化文本里**单调向前、窗口内就近**定位（复用 `scrollToSearchMatch` 的 segment→node 映射）。漂移在结构上被打断（每条 cue 独立锚定），且窗口受限 + 单调 → **不会来回跳动**；找不到则回落到提示偏移（不劣于现状）。**无需数据迁移**：cue.text 本就存在库里，旧书立即生效。
- **B**：`skipToCue`（所有 seek 的收口）在 `preload:false` 跨文件 `seek(index:)` 期间不抑制 `positionStream` 瞬态 tick，且主动清 `_chapterTransition` 守卫；加载期瞬态位置（0→章首 cue）各驱动一次 `_updateCurrentCue`→跨章导航/reveal。根治：在 `skipToCue` 内立一个「显式 seek 抑制窗」，seek 落定且权威目标 cue 写入前，瞬态 tick 不得推进 cue / 跨章 / reveal。
- **C**：reader scope 先于 audiobook scope 解析，Space 永远命中 `readerPageForward`。根治：`_handleKeyEvent` 里当有声书已激活时，让 Space（无修饰）优先解析为 `audiobookPlayPause`（媒体播放器惯例）；翻页仍可用方向键/PageDown。

**Tech Stack:** Flutter 3.44 / Dart；WebView JS（`reader_pagination_scripts.dart`）；just_audio（`audiobook_controller.dart`）；测试 `flutter test`（焦点驱动集成测试见 docs/agent）。

**BUG 编号（提交时按 docs/BUGS.md 最新值实占，下方为暂定）:** A=BUG-060，B=BUG-061，C=BUG-062。

---

## Task C：空格在有声书场景下暂停而非翻页（BUG-062，最小最安全，先做）

**Files:**
- Modify: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（`_handleKeyEvent` 约 3519-3592 的键盘解析段）
- Test: `hibiki/test/reader/reader_space_pause_test.dart`（新建，纯解析逻辑/或 widget 行为）
- Doc: `docs/BUGS.md` 追加条目

**根因锚点:** `reader_hibiki_page.dart:3566-3575` 先 `resolveKeyboard(scope: reader)` 再 `audiobook`；`shortcut_defaults.dart:54` Space=`readerPageForward`，`:122-123` `audiobookPlayPause`=Ctrl+Space。有声书激活时 Space 被 reader scope 抢成翻页。

- [ ] **Step 1: 写失败测试** —— 断言「有声书激活 + 无修饰 Space」解析出的 action 是 `audiobookPlayPause`；「无有声书」时仍是 `readerPageForward`；「Shift+Space」始终是 `readerPageBackward`。

抽出一个纯函数便于测试（见 Step 3）：
```dart
// 测试文件
test('space pauses when audiobook active, pages when not', () {
  expect(
    resolveReaderSpaceOverride(
      key: LogicalKeyboardKey.space, modifiers: const <ModifierKey>{},
      hasActiveAudiobook: true,
    ),
    ShortcutAction.audiobookPlayPause,
  );
  expect(
    resolveReaderSpaceOverride(
      key: LogicalKeyboardKey.space, modifiers: const <ModifierKey>{},
      hasActiveAudiobook: false,
    ),
    isNull, // 不覆写 → 走默认翻页
  );
  expect(
    resolveReaderSpaceOverride(
      key: LogicalKeyboardKey.space, modifiers: const <ModifierKey>{ModifierKey.shift},
      hasActiveAudiobook: true,
    ),
    isNull, // Shift+Space 不抢，仍翻页后退
  );
});
```

- [ ] **Step 2: 跑测试看红** —— `flutter test test/reader/reader_space_pause_test.dart`，预期 `resolveReaderSpaceOverride` 未定义而失败。

- [ ] **Step 3: 实现纯函数 + 接入** —— 在 `reader_hibiki_page.dart` 顶层（类外，便于测试）加：
```dart
/// 有声书激活时，无修饰 Space 改作播放/暂停（媒体播放器惯例）；
/// 其它情况返回 null 表示不覆写，交回默认翻页解析。
ShortcutAction? resolveReaderSpaceOverride({
  required LogicalKeyboardKey key,
  required Set<ModifierKey> modifiers,
  required bool hasActiveAudiobook,
}) {
  if (key != LogicalKeyboardKey.space) return null;
  if (modifiers.isNotEmpty) return null; // Shift/Ctrl+Space 保留原义
  if (!hasActiveAudiobook) return null;
  return ShortcutAction.audiobookPlayPause;
}
```
在 `_handleKeyEvent` 解析 `action` 之前插入覆写（`hasActiveAudiobook` 用本类已有的「有声书是否激活」判据，如 `_audiobookController != null && _audiobookController!.hasAudio`，按实际字段对齐）：
```dart
final ShortcutAction? spaceOverride = resolveReaderSpaceOverride(
  key: event.logicalKey,
  modifiers: modifiers,
  hasActiveAudiobook: _audiobookController != null &&
      _audiobookController!.hasAudio,
);
ShortcutAction? action = spaceOverride ??
    appModel.shortcutRegistry.resolveKeyboard(
      event.logicalKey, modifiers: modifiers, scope: ShortcutScope.reader,
    ) ??
    appModel.shortcutRegistry.resolveKeyboard(
      event.logicalKey, modifiers: modifiers, scope: ShortcutScope.audiobook,
    );
```
> 实现前确认 `_executeShortcutAction` 已处理 `ShortcutAction.audiobookPlayPause`（若 reader 的 execute 不含该 case，需补一个 case 调 `_audiobookController?.togglePlayPause()`）。

- [ ] **Step 4: 跑测试看绿 + analyze** —— `flutter test test/reader/reader_space_pause_test.dart` 通过；`flutter analyze` 0 issue。

- [ ] **Step 5: 提交** —— `docs/BUGS.md` 勾两框（①根因修复 ②源码/行为测试），提交：
```bash
git add hibiki/lib/src/pages/implementations/reader_hibiki_page.dart \
        hibiki/test/reader/reader_space_pause_test.dart docs/BUGS.md
git commit -m "fix(reader): space pauses audiobook instead of paging (BUG-062)"
```

---

## Task B：从本句播放消除三段跳（BUG-061）

**Files:**
- Modify: `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart`（`skipToCue` 579-605；`_updateCurrentCue` 约 771-821 的瞬态守卫；如需新增 `_explicitSeekInFlight` 字段）
- Test: `packages/hibiki_audio/test/audiobook/skip_to_cue_transient_test.dart` 或 `hibiki/test/media/audiobook/skip_to_cue_seek_test.dart`（按现有有声书测试位置对齐）
- Doc: `docs/BUGS.md`

**根因锚点:** `audiobook_controller.dart:595` `skipToCue` 主动 `_chapterTransition=false`；`preload:false`（`:347/365`）跨文件 `seek(index:)` 加载期 `positionStream`（125ms tick `:756`）吐 0→章首，逐 tick 经 `_updateCurrentCue`(`:771`)→`_maybeEmitCrossChapter`(`:820`)→reader `_onCueChanged` reveal。被破坏的不变量：**一次显式 seek 期间瞬态 tick 不得驱动 cue 推进/跨章/reveal**。

- [ ] **Step 1: 写失败测试** —— 用 fake/记录器驱动：构造多音频文件 cue 列表，模拟 `skipToCue(targetCueInLaterFile)` 后 `positionStream` 先发瞬态(0、其它文件章首位置)再发真实 `cue.startMs`。断言：抑制窗内瞬态 tick **不**改变 `currentCue`（不出现「章首 cue」中间态），最终只落在 target cue 上一次。验证 `onCrossChapter` 回调在本次 skip 中至多触发与 target 一致的一次（不被瞬态触发）。

```dart
test('skipToCue suppresses transient ticks during cross-file seek', () async {
  // 安排：target 在 file#1；seek 前位置在 file#0 起点。
  // 模拟 seek 后瞬态 position=0、随后=章首cue.startMs、最后=target.startMs。
  final List<int?> cueIndexHistory = <int?>[];
  controller.addListener(() => cueIndexHistory.add(controller.currentCue?.sentenceIndex));
  await controller.skipToCue(target);
  // 关键断言：历史里不得出现 file#1 章首 cue 这种中间态。
  expect(cueIndexHistory.where((i) => i == chapterHeadCue.sentenceIndex), isEmpty);
  expect(controller.currentCue, target);
});
```
> 具体 fake 方式对齐现有 `audiobook_controller_seek_test`/`audiobook_health_test` 的测试夹具（同目录已有 just_audio 的可控替身用法，沿用之）。

- [ ] **Step 2: 跑测试看红** —— `flutter test <该测试文件>`，预期出现章首中间态而失败。

- [ ] **Step 3: 实现抑制窗** —— 在 `audiobook_controller.dart` 加字段：
```dart
/// 显式 seek（skipToCue/playCue*）进行中：抑制换文件加载期 positionStream
/// 的瞬态 tick 驱动 cue 推进 / 跨章 / reveal。seek 落定且目标 cue 已权威写入后清除。
bool _explicitSeekInFlight = false;
```
改 `skipToCue`：
```dart
Future<void> skipToCue(AudioCue cue) async {
  _stopAtPositionMs = null;
  _returnToPosition = null;
  await _loadReady.future;
  final ({int audioFileIndex, int positionMs})? mappedPosition = _positionForCue(cue);
  if (mappedPosition == null) return; // fail-closed，保持现状
  final int positionMs = _clampToKnownDuration(mappedPosition.positionMs);
  _explicitSeekInFlight = true; // ← 立守卫，先于 seek
  try {
    await _player.seek(
      Duration(milliseconds: positionMs),
      index: mappedPosition.audioFileIndex,
    );
    // 权威写入目标 cue（不依赖瞬态 position）
    _chapterTransition = false;
    final int idx = _chapterCues.indexOf(cue);
    if (idx >= 0) {
      _currentCueIndex = idx;
      _currentCue = cue;
      _maybeEmitCrossChapter(cue); // 仅按目标 cue 判定一次跨章
      notifyListeners();
    } else {
      _updateCurrentCue(_player.position.inMilliseconds);
    }
  } finally {
    _explicitSeekInFlight = false; // ← seek 落定、权威 cue 已写入后放行
  }
}
```
在 `_updateCurrentCue`（`:771` 入口处，`_maybeSavePosition` 之后、实际推进之前）加守卫：
```dart
void _updateCurrentCue(int positionMs) {
  if (_explicitSeekInFlight) return; // 显式 seek 期间瞬态 tick 不推进
  // ...原有逻辑不动...
}
```
> 注意：`await _player.seek` 在 `preload:false` 下可能在文件加载完成前返回，瞬态 tick 仍会在 `finally` 之后到来。若测试证明 `seek` 返回过早，则把放行点改为「首个落在 `[cue.startMs-ε, cue.endMs]` 区间的 tick 到达后」再清 `_explicitSeekInFlight`（在 `_updateCurrentCue` 守卫里检测到目标区间命中时清旗并正常处理该 tick）。以测试观察到的真实 tick 序列为准选其一，不要两个都加。

- [ ] **Step 4: 跑测试看绿 + 回归** —— 该测试通过；再跑 `flutter test test/media/audiobook/`（含 `audiobook_controller_seek_test` 等）确认 skip/prev/next/playCueOnce 未回归；`flutter analyze` 0。

- [ ] **Step 5: 提交**
```bash
git add packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart \
        <测试文件> docs/BUGS.md
git commit -m "fix(audiobook): suppress transient ticks during explicit seek (BUG-061)"
```

---

## Task A：高亮坐标改由实时 DOM 权威定位（BUG-060）

**Files:**
- Modify: `hibiki/lib/src/media/audiobook/audiobook_bridge.dart`（`applySasayakiCues` 362-391：payload 增加 `text`）
- Modify: `hibiki/lib/src/reader/reader_pagination_scripts.dart`（`collectSasayakiCueRanges` 236-293 改为「文本就近 + 单调」定位；复用 `normalizeText`/`scrollToSearchMatch` 的 segment 映射）
- Test:
  - `hibiki/test/reader/sasayaki_cue_mapping_drift_test.dart`（新建，Dart 侧对生成的 JS 逻辑做规则守卫 / 或抽出可测纯函数）
  - `hibiki/test/media/audiobook/audiobook_bridge_payload_test.dart`（断言 payload 含 text）
  - 真机/集成：JS 运行时在真 reader 验证（设备验证待用户）
- Doc: `docs/BUGS.md`

**根因锚点:** `reader_pagination_scripts.dart:243` 单一 `cursor` 从 body 头累加 → 任一处 package:html↔DOM 字符差累积推移其后所有 cue。`audiobook_bridge.dart:377-381` payload 只送 `start`(=normCharStart)/`length`，不送文本，JS 无法在 DOM 自校正。

**设计要点（防跳动）:** JS 维护单调 `cursor`（DOM 归一化字符索引）。对每条 cue（按 start 升序）：`needle = normalizeText(cue.text)`；在 `[cursor, cursor + W]` 窗口（`W = max(needle.length + 64, 200)`，对齐 matcher searchWindow 量级）内对 DOM 归一化文本做 `indexOf(needle)`；命中则用 segment→node 映射建 range，`cursor = matchEnd`；窗口内未命中 → 用提示 `start`（裁剪到 `>= cursor`）重定位 cursor 再试一次（recovery，对齐 matcher）；仍失败 → 回落到「按提示偏移 `start`/`length` 走老 cursor 计数」建 range（不劣于现状）。**单调 + 窗口受限 ⇒ 不会跳到远处重复句**；**逐 cue 独立锚定 ⇒ 单处 2 字差不再传播**。

- [ ] **Step 1: 写失败测试（payload 含 text）** —— `audiobook_bridge_payload_test.dart`：构造若干 sasayaki cue，调用一个抽出的纯函数 `buildSasayakiPayload(cues, sectionIndex)`（从 `applySasayakiCues` 内联逻辑抽出），断言每个 entry 含 `id/start/length/text` 且 `text == cue.text`。
```dart
test('sasayaki payload carries raw cue text for DOM-side self-alignment', () {
  final payload = buildSasayakiPayload(cues, 0);
  expect(payload.first.containsKey('text'), isTrue);
  expect(payload.first['text'], cues.first.text);
});
```

- [ ] **Step 2: 跑红** —— `flutter test test/media/audiobook/audiobook_bridge_payload_test.dart`，预期 `buildSasayakiPayload` 未定义/无 text。

- [ ] **Step 3: 实现 payload** —— 把 `applySasayakiCues` 内构造 payload 的逻辑抽成顶层/静态纯函数 `buildSasayakiPayload`，并加 `'text': cue.text`：
```dart
@visibleForTesting
List<Map<String, dynamic>> buildSasayakiPayload(List<AudioCue> cues, int sectionIndex) {
  final List<Map<String, dynamic>> payload = <Map<String, dynamic>>[];
  for (final AudioCue cue in cues) {
    final SasayakiFragment? frag = SasayakiMatchCodec.tryDecode(cue.textFragmentId);
    if (frag == null || frag.sectionIndex != sectionIndex) continue;
    payload.add(<String, dynamic>{
      'id': cue.textFragmentId,
      'start': frag.normCharStart,
      'length': frag.normCharEnd - frag.normCharStart,
      'text': cue.text, // ← DOM 侧用它自校正
    });
  }
  return payload;
}
```
`applySasayakiCues` 改为调用它。

- [ ] **Step 4: 跑绿** —— payload 测试通过。

- [ ] **Step 5: 写 JS 定位逻辑测试（红）** —— 抽出 JS 算法的可测影子：在 `reader_pagination_scripts.dart` 里新增 JS 函数 `resolveCueRangeByText`，并在 Dart 测试里用一个等价 Dart 纯函数 `resolveCueRangesByText(domNormText, segments, cues)`（同算法）做守卫测试，覆盖：
  - 正常：cue 文本在 DOM 命中，range 落对；
  - **漂移**：DOM 在前部比提示多/少 2 字，后续 cue 仍各自命中（断言不被推移）；
  - **重复短语**：同文本在远处重复，窗口内单调命中近的那个（断言不跳）；
  - **未命中**：回落到提示偏移。
```dart
test('per-cue text anchoring absorbs 2-char upstream drift without shifting later cues', () {
  // domNormText 比 matcher 坐标在第 5 字处多 2 字；
  // 断言第 50 字附近的 cue 仍命中其自身文本，range 不偏。
});
test('bounded monotonic search does not jump to a far duplicate phrase', () { /* ... */ });
```

- [ ] **Step 6: 跑红** —— 预期 `resolveCueRangesByText` 未定义失败。

- [ ] **Step 7: 实现 JS `collectSasayakiCueRanges` 新算法 + Dart 影子函数** —— JS 侧（写进 `reader_pagination_scripts.dart` 的脚本字符串）：先一次性构建 `segments`（`{node, text}`，复用 `createWalker`，与 `scrollToSearchMatch` 同源）与拼接的 `fullNorm`（对每段 `normalizeText`，并记录每段归一化起点用于 char→node 反查）；然后按上文「单调 + 窗口 + recovery + 回落」对每条 cue 定位，产出与现结构相同的 `cueRanges`（`{id, ranges:[{node,start,end}]}`），后续 `applySasayakiCues` 建 `cueRangesMap`/wrappers 的代码不变。Dart 影子 `resolveCueRangesByText` 实现同一算法，仅供测试。
> 关键不变量（写进代码注释）：1) cursor 单调不回退；2) 搜索窗口有界（不全局搜）；3) needle 用整句（长，抗窗口内重复）；4) 未命中回落提示偏移，绝不空高亮整章。

- [ ] **Step 8: 跑绿 + 全量** —— 新测试全绿；`flutter test test/reader/ test/media/audiobook/`；`flutter analyze` 0；`dart format .`。

- [ ] **Step 9: 提交**
```bash
git add hibiki/lib/src/media/audiobook/audiobook_bridge.dart \
        hibiki/lib/src/reader/reader_pagination_scripts.dart \
        hibiki/test/reader/sasayaki_cue_mapping_drift_test.dart \
        hibiki/test/media/audiobook/audiobook_bridge_payload_test.dart docs/BUGS.md
git commit -m "fix(reader): anchor audiobook highlight against live DOM text to kill cumulative drift (BUG-060)"
```

- [ ] **Step 10: 设备验证（待用户）** —— 真 reader 打开有声书，播放到 ~1 万字、~10 万字处核对高亮贴合；快速跳转不抖动；记入 docs/BUGS.md 证据。

---

## Self-Review

1. **Spec 覆盖**：A=高亮偏移✓ B=三段跳✓ C=空格暂停✓，各含根因锚点 file:line + TDD。
2. **Placeholder**：B Step3 给了两种放行点并要求「以真实 tick 序列择一」，非占位（明确决策依据）；A Step7 的 JS 写进脚本字符串、Dart 影子函数测试，避免「JS 不可测」空话。
3. **类型一致**：`resolveReaderSpaceOverride` / `buildSasayakiPayload` / `resolveCueRangesByText` / `_explicitSeekInFlight` 命名贯穿定义与调用一致。
4. **Never break userspace**：A 无 schema 迁移（cue.text 已存在，旧书直接生效）、未命中回落旧行为；C 仅在有声书激活 + 无修饰 Space 时覆写；B 仅收口 `skipToCue` 抑制瞬态，不改 seek 目标语义。
