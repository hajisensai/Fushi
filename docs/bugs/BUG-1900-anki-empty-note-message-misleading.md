## BUG-1900 · AnkiConnect 制卡把字段映射不匹配报成 cannot create note because it is empty
- **报告**：2026-08-28（用户附日志；原话：「在没选择正确卡组，或者没卡组的时候也会显示这个，需要改一下显示文案。还有报错信息也要修改」）
- **真实性**：✅ 真 bug，**且不只是文案问题**。

```
[2026-08-27 23:25:06] Anki.mineEntry
AnkiConnectException: cannot create note because it is empty
#0 AnkiConnectService._request (ankiconnect_service.dart:153)
#1 AnkiConnectService.addNote (ankiconnect_service.dart:442)
#2 AnkiConnectRepository._mineEntryInner (ankiconnect_repository.dart:732)
#3 AnkiConnectRepository.mineEntry (ankiconnect_repository.dart:621)
#4 ImmersionMiningEngine._mineNow (immersion_mining_engine.dart:469)
```

### 根因

`cannot create note because it is empty` 是 **Anki 服务端**的原文：`fields_check()` 只看
笔记类型的**第一个字段**，空就拒收整张卡。Fushi 之所以会送出一张首字段为空的卡：

1. **AnkiConnect 按字段「名」匹配**，不认识的名字被服务端静默丢弃
   （`ankiconnect_repository.dart` 把 `rendered.fields` 这个 map 原样交给 `addNote`）；
2. 而 `base_anki_repository.dart` 的 `fieldMappingsAfterFetch` 对**非 Lapis** 笔记类型
   直接 `return current.fieldMappings` —— 换了笔记类型，字段映射**不跟着换**；
3. 于是映射里的键可能一个都不属于新类型 → 服务端收到一张全空的卡 → 拒收；
4. 既有的 `fields.isEmpty` 守卫拦不住：map 非空，只是名字全错。

**对照组自证**：AnkiDroid 后端一直是按 `noteType.fields` 的**位置**取值
（`ankidroid/anki_repository.dart` 的 `fieldArray`），名字不属于该类型自然被丢弃，
所以它从来不会撞上这个错误。同一个仓库里两条后端一条对一条错。

用户说的「没选择正确卡组、或者没卡组的时候也显示这个」也对得上：
`selectDeckAfterFetch` 只要点过一次「刷新」就会**自动选中某个 deck**，
于是 `MineOutcome.notConfigured` 那条「Anki 尚未配置」文案几乎永不触发，
用户必然落到透传的英文原文上。而错误码链路
（`AnkiErrorCode` → `localizeAnkiMineError`）当时只覆盖**连接层**六种，
没有任何一条对应服务端业务错误 → `errorCode` 恒 null → 走
`card_export_failed_detail(reason: 'AnkiConnect: cannot create note because it is empty')`。

### 修复与测试

- **[x] ① 已修复**（根因 + 文案两层）：
  - `base_anki_repository.dart` 新增两个共享 helper：
    - `fieldsForNoteType(noteType, rendered)` —— 只保留属于当前笔记类型的字段
      （字段清单为空时原样返回：没有可信真相时不猜）；
    - `preflightNoteFields(noteType, rendered, outgoing)` —— 本地预检首字段，
      并区分「名字全对不上」与「首字段确实没内容」，两者给的建议不一样。
  - `ankiconnect_repository.dart` 送出前先求交再预检，**明知必失败的卡一个请求都不发**。
  - `ankidroid/anki_repository.dart` 也接上同一条预检：它原有的 every-empty 守卫拦不住
    「首字段空、别的字段有内容」，那种卡送出去照样被 Anki 拒。两个后端现在行为一致。
  - 新增分类码 `AnkiErrorCode.fieldMappingMismatch` / `firstFieldEmpty`，
    `localizeAnkiMineError` 映射到新 i18n
    `anki_error_field_mapping_mismatch` / `anki_error_first_field_empty`（17 语言）。
    诊断串里列出「配了哪些字段 / 该类型有哪些字段」，用户照着就能改。
- **[x] ② 已加自动化测试** —
  `packages/fushi_anki/test/ankiconnect_field_mapping_preflight_test.dart` 三个用例：
  名字全对不上 → `fieldMappingMismatch` 且**没有发出任何 addNote 请求**；
  首字段空 → `firstFieldEmpty`；正常情形 → 陌生键被剥掉、只送该类型的字段。
  **变异实测**（2026-08-28）：把 `preflightNoteFields` 改成恒返回 null → 2 项转红；
  把 `fieldsForNoteType` 改成原样返回 → 另 2 项转红。还原后 `fushi_anki` 全量 433 项
  + 主 app `test/anki/` `test/i18n/` 共 307 项全绿。

### 备注

- 「没卡组」这一种情形本身仍走 `MineOutcome.notConfigured`（文案
  `card_export_not_configured`）。本次没有改 `selectDeckAfterFetch` 的自动选中行为——
  它对绝大多数用户是便利而非缺陷；真正的问题是选中之后字段映射没跟着走，已在上面修掉。
- 相邻未做（另计）：galgame 浮窗里制卡失败**完全看不到提示**——失败文案画在主 app 窗口的
  Flutter Overlay 上，而 gal 浮窗是独立的 native WebView2，游戏全屏时主窗在后台。
  见同批调查记录（浮窗内已有 `showInlineHint` 通道，制卡链路没接上；回程
  `toPopupReply()` 只能传 `{ankiConnect, noteId}` 两个布尔/整数，带不了消息串）。
- 未做真机复测（需要真实 Anki + AnkiConnect 环境构造「换笔记类型」现场）。
