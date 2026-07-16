## BUG-858 · Anki 覆盖卡片只覆盖图片和语音，原文句子未覆盖
- **报告**：2026-07-16（用户：）
- **真实性**：✅ 真 bug。根因 `packages/hibiki_anki/lib/src/base_anki_repository.dart:340`（空值守卫被覆盖路径误用）。
- **[x] ① 已修复** — commit 见下方；`base_anki_repository.dart` `buildMinedFields` 加 `keepEmpty`，两后端 `updateMinedNote` 走 `keepEmpty:true` + 守卫改「所有字段皆空白才拒绝」。
- **[x] ② 已加自动化测试** — `packages/hibiki_anki/test/note_id_and_update_test.dart`（BUG-858 group，AnkiConnect）+ `packages/hibiki_anki/test/ankidroid_overwrite_test.dart`（AnkiDroid 空句清空）。
- **备注**：

### 根因（三方独立确认：主代理 + 2 个探索子代理）
覆盖「已有卡片」走 `updateMinedNote` → `_renderMinedFields` → `buildMinedFields`。
`base_anki_repository.dart:340` 的守卫 `if (value.trim().isNotEmpty) fields[entry.key] = value;`
被**新建**与**覆盖**两条路径共用：
- 新建：渲染为空的字段跳过 = 空字段，无害。
- 覆盖：渲染为空的字段被跳过 → 字段名不进 map → 两后端 native `updateNoteFields`
  「只覆盖给出的字段，未给出的保留旧值」→ 旧值**被静默保留**。

`{sentence}`（`anki_models.dart:502-519`）只取自 `context.sentence`，而句子**从不随 popup
制卡 payload 传递**（`hibiki/assets/popup/popup.js:1294-1310` 的 `buildMinePayload` 无
`sentence` 键），只靠宿主**瞬时选区状态**（reader `currentMediaSource.currentSentence`、
video `_lastLookupSentence`、overlay `sentenceContext`）。覆盖经「✓→异步查卡→操作面板→
点击」或音量键导航后选区可能已清空 → 句子渲染空 → 被上面守卫丢弃 → 卡片旧句保留；
而图片(`{card-image}`←书封/GIF)、句子音频(`{sentence-audio}`←cue 时间窗)来自与选区无关的
独立存活状态，渲染非空 → 正常覆盖。故「只覆盖图片和语音、原文句子不覆盖」。

各 surface 的 mine/update 在 Dart 层**对称**取/传句子，无漏传参数——这是同一份代码在
两个时刻的不同运行态 + 覆盖误用新建的空值守卫。

### 修复（用户选定语义：覆盖=整体替换，句子为空则随之清空）
- `packages/hibiki_anki/lib/src/base_anki_repository.dart`：`buildMinedFields` 加
  `bool keepEmpty=false`；`true` 时保留所有映射字段（含渲染为空的）。
- `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart` +
  `.../ankidroid/anki_repository.dart`：`_renderMinedFields` 透传 `keepEmpty`；
  `updateMinedNote` 传 `keepEmpty:true`，并把「拒绝清空」守卫从 `fields.isEmpty` 改成
  `fields.values.every((v)=>v.trim().isEmpty)`（**所有**字段皆空白才拒绝清整卡；空映射
  仍拒绝）。
- 新建路径 `mineEntry` 不传 `keepEmpty`（默认 false），行为零变化（Never break userspace）。

### 测试
- `note_id_and_update_test.dart`「BUG-858」group（AnkiConnect）：覆盖写空 Sentence 字段
  （清空陈旧句）/ 覆盖写新句 / 新建仍丢弃空 Sentence / 全空仍拒绝。
- `ankidroid_overwrite_test.dart`：AnkiDroid 覆盖发送空 Sentence 字段以真正清空。
- 消费侧 `hibiki/test/mining/immersion_mining_engine_test.dart` 14 项（含 updateMinedNote
  路由）通过。
- `flutter test`（hibiki_anki 全 170 项）通过；`flutter analyze` 仅 1 个**预先存在**、
  与本次无关的 warning（`ankiconnect_commit_unknown_test.dart:8`）。

### 真机复测清单（待用户验证）
1. 视频页查词/字幕多选制卡 → 换句/选区清空后点绿 ✓↩ 或操作面板覆盖 → 卡片句子应更新
   （句子非空覆盖为新句；句子为空则清空，不再残留旧句），图片/音频照常覆盖。
2. 有声书/阅读器同上。
3. 剪贴板/悬浮窗覆盖同上。
