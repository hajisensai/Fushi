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

## Next Scope

本轮完成匹配管线代码审查。下一轮建议审查：字幕解析器层 (`parsers/`) 的编码检测和边界处理。
