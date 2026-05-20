# 2026-05-20 书籍↔字幕匹配管线审查

## 审查范围

| 层级 | 文件 | 职责 |
|------|------|------|
| 归一化 | `packages/hibiki_audio/lib/src/matching/audio_text_normalizer.dart` | 日文白名单归一化 |
| 核心匹配 | `packages/hibiki_audio/lib/src/matching/epub_srt_matcher.dart` | Dice 系数模糊匹配 |
| 格式包装 | `packages/hibiki_audio/lib/src/matching/epub_cue_matcher.dart` | 格式无关封装 |
| 编解码 | `packages/hibiki_audio/lib/src/matching/sasayaki_match_codec.dart` | sasayaki:// 编解码 |
| 运行时查找 | `packages/hibiki_audio/lib/src/matching/collection_audio_matcher.dart` | 播放区间查找 |
| 导入 UI | `hibiki/lib/src/media/audiobook/book_import_dialog.dart` | 统一导入对话框 |
| 重匹配 UI | `hibiki/lib/src/media/audiobook/sasayaki_rematch.dart` | 重匹配入口 |
| JS 镜像 | `hibiki/lib/src/media/audiobook/audiobook_bridge.dart` (L92-117) | `__hoshiIsSkippable` |

测试覆盖：`epub_srt_matcher_test.dart` (20 cases) + `audio_text_normalizer_test.dart` (20 cases) + `collection_audio_matcher_test.dart` (12 cases) = 52 tests, all green.

---

## Round 1 发现

### HBK-AUDIT-M01: normalizer 全角字母/数字转换错误 (已修复，待提交)

- **severity**: HIGH — 匹配准确率直接受损
- **status**: 已修复 (uncommitted diff)
- **文件**: `audio_text_normalizer.dart` L24
- **根因**: 旧代码 `cp + 0x20` 把全角 `Ａ` (0xFF21) 映射到全角 `ａ` (0xFF41)，而非 ASCII `a` (0x61)。EPUB 用 ASCII 字母，SRT 用全角字母时，归一化结果不等，精确 indexOf 必败。
- **影响**: 任何含全角英文字母/数字的 SRT↔EPUB 匹配成功率下降。
- **修复**: `cp - 0xFEC0` 映射全角 A-Z → ASCII a-z；新增全角 a-z、全角 0-9、半角片假名转换分支。
- **验证**: 20 个 normalizer 测试 + 20 个 matcher 测试全绿；`全角/ASCII 交叉` 测试覆盖此路径。
- **JS 镜像同步**: `__hoshiIsSkippable` 只做偏移计数（哪些字符 keep），不做值转换。字符范围 24 行与 Dart `_isKeepable` 24 个 range 完全对齐 ✓。

### HBK-AUDIT-M02: `match()` / `_matchEntrypoint` 路径重复归一化 cue 文本

- **severity**: MEDIUM — 性能浪费，导入大书时可感
- **status**: 已修复
- **文件**: `epub_srt_matcher.dart` L150, L543
- **根因**: `_matchCore` 接受 `preNormCueTexts` 参数以跳过归一化，但 `match()` 和 isolate 入口 `_matchEntrypoint` 没有传入，导致：
  - `_findStart` 对前 15 条 cue 做 `normalize()`
  - 主循环对所有 cue 再做一遍 `normalize()`
  - 对比：`_probeEntrypoint` 已正确预归一化
- **影响**: 每次匹配多浪费 ~15 次 normalize 调用（对 10000 cue 的书约 0.1% 额外耗时，但对原则不对：没理由重复做）。
- **修复**: `match()` 和 `_matchEntrypoint` 均预计算 `normCueTexts` 后传给 `_matchCore`。`_matchEntrypoint` 同时跳过 `match()` 的空检查，直接调 `_matchCore`。
- **验证**: 52 个测试全绿，行为不变。

### HBK-AUDIT-M03: `CollectionAudioMatcher.findPlaybackRange` O(n) 线性扫描 (不修 — sasayaki 重构范围)

- **severity**: LOW (导入时无影响，运行时可感)
- **status**: 记录，留给 sasayaki 重构
- **文件**: `collection_audio_matcher.dart` L49-87
- **问题**: 每次调用遍历所有 cue 并逐条 `SasayakiMatchCodec.tryDecode()`。10000 cue 的书在快速翻页时可能造成帧延迟。
- **建议**: sasayaki 重构时，构建 `Map<int, List<(SasayakiFragment, AudioCue)>>` 按 sectionIndex 索引，section 内 normCharStart 排序，二分查找。

### HBK-AUDIT-M04: `_normalizedAdjacentMatch` 每次重建所有 cue 归一化拼接 (不修 — sasayaki 重构范围)

- **severity**: LOW
- **status**: 记录，留给 sasayaki 重构
- **文件**: `collection_audio_matcher.dart` L136-204
- **问题**: 文本兜底路径每次调用归一化并拼接所有 cue 文本。若频繁调用可浪费内存/CPU。
- **建议**: 重构时预建拼接索引缓存在匹配器实例中。

### HBK-AUDIT-M05: `SasayakiRematch._loadSections` 与 `_run` 各自独立加载 EPUB sections

- **severity**: LOW
- **status**: 记录，留给 sasayaki 重构
- **文件**: `sasayaki_rematch.dart` L238-257, L259-311
- **问题**: auto-probe 和 run 各自从磁盘重新读取 EPUB、解析 sections。对同一本书连续执行（先 probe 再 run）会读两次。
- **建议**: `_loadSections` 结果通过 `_MatchParams` 或 session 级缓存传递。

---

## 品味评分

🟢 **好品味** — 匹配管线架构清晰、职责分离到位

**亮点:**
- 白名单归一化 + Dice 系数滑窗的组合对日文文本匹配很有效
- 增量 gram-map 更新避免了 O(window × cue_len) 退化
- probe 机制自动调优 searchWindow 是好设计
- 测试覆盖了精确匹配、模糊兜底、跨章节、起点检测等关键路径
- `SasayakiMatchCodec` 把匹配结果编码进 `textFragmentId`，不改 schema，向后兼容

**注意事项:**
- `_isKeepable` 与 `__hoshiIsSkippable` 必须严格镜像——任何新增 range 必须双侧同步更新
- `_matchEntrypoint` 需要复制 `match()` 的空检查逻辑（已在本轮修复中处理）

---

## 结论

| 分类 | 数量 |
|------|------|
| 已修复的 bug | 1 (M01: normalizer 全角转换，已在工作区) |
| 已修复的优化 | 1 (M02: 预归一化 cue 文本) |
| 记录待重构 | 3 (M03-M05: sasayaki 重构范围) |
| 测试验证 | 52/52 green |

## Next Scope (Round 1)

本轮完成匹配管线代码审查。下一轮建议审查：字幕解析器层 (`parsers/`) 的编码检测和边界处理。

---

## Round 2：修复验证 + 深度正确性审查

### Scope

- 验证 cf990a44 提交（M01/M02 修复）后代码正确性
- 深度审查：算法边界、JS 镜像对齐、CuesToEpub、surrogate pair 行为
- 测试验证：所有 sasayaki 相关测试

### 修复验证

**M01 (normalizer 全角转换)**: ✅ 已验证
- `audio_text_normalizer.dart:21-39` 转换逻辑正确
- `0xFF21 - 0xFEC0 = 0x0061` ('a') ✓
- `0xFF41 - 0xFEE0 = 0x0061` ('a') ✓
- `0xFF10 - 0xFEE0 = 0x0030` ('0') ✓

**M02 (预归一化 cue 文本)**: ✅ 已验证
- `match()` L150-161 预计算 `normCueTexts` 并传入 `_matchCore` ✓
- `_matchEntrypoint` L563-574 同样预计算 ✓
- `_probeEntrypoint` L626-629 共享 `normCueTexts` 跨多窗口探测 ✓

### JS 镜像对齐

**`__hoshiIsSkippable` vs `_isKeepable`**: ✅ 完全一致
- 26 个字符范围逐条比对，无差异
- 逻辑正确取反：`isSkippable = !isKeepable`

### 深度审查发现

#### HBK-AUDIT-M06: `_slidingDice` 使用 codeUnitAt 对 CJK Extension B+ 字符不精确

- **severity**: TRIVIAL — 理论问题，实际不影响
- **status**: 不修 — 已评估影响
- **文件**: `epub_srt_matcher.dart` L340-421
- **问题**: `_slidingDice` 用 `codeUnitAt` 构建 bigram key。BMP 以外字符（CJK Extension B-H, U+20000+）在 Dart String 中以 surrogate pair 存储（两个 code unit），bigram 会跨越或拆散 surrogate。
- **实际影响**: (1) 精确 `indexOf` 路径不受影响。(2) 模糊路径中 needle 和 haystack 都用同样的 codeUnit 粒度，bigram 自我一致。(3) CJK Extension B+ 在现代日文有声书中极其罕见。
- **结论**: 不修复。如果未来需要支持古典/学术文本中大量 Extension B+ 字符的模糊匹配，可以改用 runes-based bigram。

#### HBK-AUDIT-M07: CuesToEpub 硬编码 `xml:lang="ja"`

- **severity**: TRIVIAL
- **status**: 不修 — 当前只服务日文内容
- **文件**: `cues_to_epub.dart` L181
- **问题**: OPF 中 `xml:lang` 硬编码为 `"ja"`。若未来支持其他语种的有声书，需参数化。
- **结论**: 当前 Hibiki 只处理日文内容，无需修改。

#### CuesToEpub 其他审查项：全部通过

- XML 转义顺序（`&` 先于 `<`）✓
- 五种 HTML 实体（`&amp; &lt; &gt; &quot; &apos;`）✓
- ZIP 结构（mimetype 无压缩在首位）✓
- 章节分割逻辑（500 cue / 10min 双阈值）✓
- `data-cue-id` 用 sentenceIndex 不用 textFragmentId ✓
- 空 cues 边界 ✓

### 测试验证

```
57/57 tests passed ✅
- epub_srt_matcher_test.dart: 20 tests
- collection_audio_matcher_test.dart: 12 tests  
- sasayaki_match_codec_test.dart: 10 tests
- sasayaki_rematch_test.dart: 15 tests
```

### Round 2 结论

| 分类 | 数量 |
|------|------|
| 已修复 bug 验证通过 | 2 (M01, M02) |
| 新发现 — 不修 | 2 (M06: surrogate pair 理论问题, M07: 硬编码 lang) |
| 待重构 (M03-M05) | 仍为 3，已记录到项目内存 |
| JS 镜像 | 完全一致 ✓ |
| 测试验证 | 57/57 green |
| 代码正确性 | 无新 bug |

### 匹配率方案总结

Sasayaki 已有完整的匹配率方案：

| 层级 | 机制 | 位置 |
|------|------|------|
| 单 cue 精度 | `CueMatch.score` (0.0~1.0) | `epub_srt_matcher.dart:48` |
| 全局匹配率 | `MatchResult.matchRate` = matchedCues/totalCues | `epub_srt_matcher.dart:65` |
| 存储反算 | `SasayakiMatchCodec.computeMatchRate()` | `sasayaki_match_codec.dart:105` |
| UI 展示 | Toast + AudiobookHealth reason 字串 | `sasayaki_rematch.dart:297-304` |
| 自动探测 | `probeInIsolate()` 多窗口取最优 | `epub_srt_matcher.dart:620-651` |

## 终审判定

🟢 **Sasayaki 匹配子系统代码健康，无未修复的 bug，测试全绿，可以停止审查循环。**
