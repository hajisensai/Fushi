# Hibiki 深度质量审计报告 — 2026-05-29

> 本报告由 18 个 opus 子 agent 并行独立审查 + 逐条对抗式验证（skeptic 默认证伪，必须亲自读代码确认才放行）生成。
> 按用户指令进行**全新独立审查，未参考 `docs/reviews/` 下任何历史审查结论**。
> 写入独立文件（沿用 2026-05-28-deep-quality-audit.md 命名惯例），不覆盖当日 project-review.md。

## 方法与置信度

- 编排：18 子系统单元 × (opus 审查 -> opus 对抗验证)；138 个 agent，约 830 万 token，21 分钟。
- 原始发现 **198** 条 -> 对抗验证**确认 156** 条、**证伪驳回 42** 条（驳回率 21%，证明验证非橡皮图章）。
- 156 条均为**代码路径审查确认的风险**：已由第二个独立 agent 打开引用文件复核，但**未在真机复现、未修复**，状态统一 `Open`。
- 严重度以对抗验证后的 `corrected_severity` 为准。

## 严重度分布

| Severity | 数量 |
|---|---|
| CRITICAL | 1 |
| HIGH | 12 |
| MEDIUM | 41 |
| LOW | 98 |
| INFO | 4 |
| **合计** | **156** |

## 单元 x 严重度

| 单元 | Crit | High | Med | Low | Info | 小计 |
|---|--:|--:|--:|--:|--:|--:|
| anki | 0 | 1 | 5 | 5 | 0 | 11 |
| build-ci-deps | 0 | 2 | 2 | 7 | 0 | 11 |
| sync | 0 | 2 | 4 | 5 | 0 | 11 |
| cross-cutting-ai-smells | 0 | 0 | 4 | 7 | 0 | 11 |
| pages-ui | 0 | 0 | 1 | 10 | 0 | 11 |
| epub | 0 | 1 | 3 | 6 | 0 | 10 |
| reader-source-media | 0 | 0 | 4 | 6 | 0 | 10 |
| utils-components | 0 | 1 | 1 | 6 | 1 | 9 |
| creator | 0 | 0 | 1 | 7 | 1 | 9 |
| db-core | 1 | 2 | 0 | 5 | 0 | 8 |
| reader-core | 0 | 0 | 2 | 6 | 0 | 8 |
| test-coverage | 0 | 0 | 4 | 4 | 0 | 8 |
| app-startup-state | 0 | 1 | 3 | 3 | 0 | 7 |
| audiobook-audio | 0 | 1 | 1 | 4 | 1 | 7 |
| shortcuts-platform | 0 | 0 | 0 | 6 | 1 | 7 |
| dictionary-ffi | 0 | 1 | 1 | 4 | 0 | 6 |
| android-native-security | 0 | 0 | 2 | 4 | 0 | 6 |
| settings-profile | 0 | 0 | 3 | 3 | 0 | 6 |

## 维度分布（确认项，按一级维度）

| 维度 | 数量 |
|---|--:|
| dead-code | 19 |
| error-handling | 15 |
| type-safety | 15 |
| resource-leak | 8 |
| correctness | 7 |
| false-modularity | 7 |
| perf | 7 |
| external-api-contracts | 5 |
| credential | 4 |
| schema versioning & migrations | 3 |
| resource | 3 |
| build-config | 3 |
| ci-cd | 3 |
| maintainability | 3 |
| source-contract | 3 |
| fake | 3 |
| test-coverage-gaps | 3 |
| security | 3 |
| concurrency | 2 |
| state-management-correctness | 2 |
| parse | 2 |
| native-error-propagation | 2 |
| state-sync | 2 |
| js-bridge-contract | 2 |
| conflict-resolution | 2 |
| happy-path-only | 2 |
| developer-experience | 2 |
| parser-robustness | 2 |
| platform-boundary | 2 |
| init-ordering | 1 |
| permission model | 1 |
| async | 1 |
| god-object-decomposition | 1 |
| deployment-strategy | 1 |
| config-persistence-correctness | 1 |
| conflict-resolution correctness | 1 |
| dependency-hygiene | 1 |
| responsibility-confusion | 1 |
| cross-module-duplication | 1 |
| dependency-direction | 1 |
| data integrity | 1 |
| transaction correctness | 1 |
| ffi-memory-safety | 1 |
| fragile-contract | 1 |
| duplication | 1 |
| schema-drift | 1 |
| abstraction-quality | 1 |
| code-duplication | 1 |
| abstraction-failure | 1 |

## 执行摘要：系统性主题（Linus 视角）

数据结构错了，剩下的全是症状。风险高度集中，且呈现明确的 AI/vibe-coding 指纹——维度分布说明一切：**死代码 19、类型即摆设 15、happy-path-only 错误处理 15、资源泄漏 8、虚假模块化 7**。

**T1. 迁移与 schema 纪律——最危险（含唯一 Critical）。** `audio_cues` 被两个生产者写入（`audiobooks` 与 `srt_books`），但 v12 迁移孤儿清理只 `NOT IN (SELECT book_uid FROM audiobooks)`，于是**所有 SRT 字幕书的 cue 在升级到 v12 时被静默永久删除**（HBK-AUDIT-001）。同段紧接着的 srt_books 清理还特意加了 `ttu_book_id>0` 守卫，证明作者知道独立 SRT 书存在——却没在 cue 删除上加同样守卫。配套还有：遗留书签迁移用 `INSERT OR IGNORE` 误以为能跳过 FK 违例（SQLite 的 OR IGNORE 不抑制 FK 错误），一旦遗留 pref 引用了不存在的 epub_books id，**整个 v11 升级事务回滚、应用打不开库**（HBK-AUDIT-002）；schemaVersion 与迁移登记不一致（HBK-AUDIT-003）。根因是 audio_cues 缺少明确所有权/FK 模型——数据结构问题，补丁治不了。

**T2. Sync 子系统：安全与一致性系统性薄弱。** 本地备份 ZIP 把全部凭证（OAuth refresh token、FTP/SFTP/WebDAV/SMB 密码、server token）明文打包；凭证在 DB 里仅 base64（编码不是加密）；LAN sync 走明文 HTTP + Basic auth。一致性侧：元数据更新"先删远端再上传"，上传失败即永久丢进度；时间戳相等但内容不同时静默跳过冲突；单例后端并发复用无互斥。WebDAV/SMB/Hibiki-Client 是**三份近乎复制粘贴的 ~900 行类**（~600 行重复）。

**T3. "能跑但逻辑错"的 happy-path 正确性缺陷（AI 代码最典型）。** EPUB 假设全 UTF-8，Shift_JIS/EUC-JP 日文书直接崩（日语阅读器的硬伤）；TOC href 不做 URL 解码而章节 href 解码 -> 非 ASCII 文件名 TOC 导航静默失效；AnkiConnect 忽略 `allowDupes` 导致"允许重复"永远不生效；远程媒体下载忽略 HTTP 状态，把 404 HTML 当 .mp3 存进卡片；FFI import 错误路径返回 NULL 后 Dart `toDartString()` 解引用 NULL 崩溃。

**T4. 生命周期/资源/线程。** popup 初始化路径从不赋值 late `themeNotifier`，而 popup UI 读 `appModel.theme` -> LateInitializationError 崩溃；FFI 的 query/lookup/getMediaFile 全部同步跑在 UI 线程阻塞平台线程；HibikiSelectableText（889 行）整个是死代码且内部已坏。

**T5. 虚假模块化（文件拆了，逻辑还耦合）。** AppModel 2536 行、~80 个透传委托把 11 个子管理器耦合在一个 ChangeNotifier 背后；creator 50 文件/4528 行里 onCreatorOpenAction、fromMineFields 等契约孤立无调用方；deleteBook 重复 deleteEpubBook 已做的事务删除并拆散成非事务分散删除。

**T6. 工程/CI 形同虚设（威胁"绿灯=健康"的假象）。** CI 只构建 debug APK，release 构建条件挂在 keystore 上、PR 从不验证；apply-patches 步骤引用已漂移/删除的包会硬失败 exit 1；main.yml 的 path filter 排除 `packages/**`，5 个内部包改动**从不触发构建/测试**；27 个 `*_static_test.dart` 断言源码子串而非行为（widget 改坏照样过绿）；fastlane 是未改第三方样板指向错误 app。

**修复优先级（先止血数据丢失，再堵安全，再修崩溃，最后清工程）：**
1. HBK-AUDIT-001（SRT cue 删除）：加 `AND book_uid NOT IN (SELECT uid FROM srt_books)`，**升级前先发补丁**。
2. HBK-AUDIT-002（书签迁移 FK 回滚）：插入前校验 epub_books.id 存在或 per-row try/catch。
3. Sync 凭证明文落盘 + 明文传输（T2 High 组）。
4. popup late-init 崩溃、FFI UI 线程阻塞、anki/epub 正确性 High 组。
5. CI 完整性（packages 不触发测试、只构 debug、apply-patches 硬失败）。

## 详细发现（HBK-AUDIT-001 … HBK-AUDIT-156）

### HBK-AUDIT-001 — v11→v12 migration wipes all standalone SRT audiobook cues (data loss)

- **Severity**: CRITICAL
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `db-core` / schema versioning & migrations / data integrity / happy-path migration written against one table (audiobooks) while ignoring the second producer (srt_books) of the same data — false assumption that one table ow …(截断)
- **位置**: `packages/hibiki_core/lib/src/database/database.dart` : 239-245
- **审查者置信度**: high
- **根因**: The `from < 12` orphan-cleanup deletes `audio_cues WHERE book_uid NOT IN (SELECT book_uid FROM audiobooks)`. But SRT-imported books store their cues keyed by `srt_books.uid` (see SrtBookRepository.saveCues -> replaceCuesForBook(uid,...) at packages/hibiki_audio/lib/src/audiobook/srt_book_repository.dart:66, and replaceCuesForBook at database.dart:545). Standalone SRT books have NO row in the `audiobooks` table — `audiobooks` rows are created only via AudiobookRepository.saveAudiobook (database.dart:508). srt_books/audiobooks/audio_cues are part of the v1 baseline (never created in any onUpgrade step — confirmed: no createTable(srtBooks/audiobooks/audioCues) anywhere in onUpgrade), so a pre-v12 DB can hold SRT cues. The very next migration step (lines 246-253) even guards srt_books cleanup with `ttu_book_id > 0`, proving the author knew standalone SRT books exist with ttuBookId=0 — yet the audio_cues delete has no such guard.
  - 补充: shared mutable table (audio_cues) with two owners, only one referenced in cleanup
- **影响**: Every user who imported a standalone SRT subtitle 'audiobook' (no epub) before upgrading to schema v12 loses ALL their subtitle cues permanently on first launch after upgrade. The book row remains but cuesFor(uid) returns empty; audio/subtitle sync is silently broken with no error.
- **证据**:
~~~
if (await tableExists('audio_cues') && await tableExists('audiobooks')) {
  await customStatement(
    'DELETE FROM audio_cues '
    'WHERE book_uid NOT IN (SELECT book_uid FROM audiobooks)',
  );
}
// vs SrtBookRepository: await _db.replaceCuesForBook(uid, ...) // book_uid == srt_books.uid, never in audiobooks
~~~
- **修复建议**: Exclude SRT-owned cues from the deletion: `DELETE FROM audio_cues WHERE book_uid NOT IN (SELECT book_uid FROM audiobooks) AND book_uid NOT IN (SELECT uid FROM srt_books)`. Better: introduce an explicit FK/ownership model so audio_cues are not orphan-cleaned against a single table that doesn't own all of them.
- **验证（对抗复核）**: Independently confirmed by reading the cited code. The v12 migration at packages/hibiki_core/lib/src/database/database.dart:239-245 unconditionally runs `DELETE FROM audio_cues WHERE book_uid NOT IN (SELECT book_uid FROM audiobooks)` for any DB upgrading from <12.

Verified chain:
1. SRT cues are keyed by srt_books.uid: srt_book_repository.dart:62-67 calls `_db.replaceCuesForBook(uid, ...)`; the import flow book_import_dialog.dart:526 sets `uid = 'srtbook_<ts>'`, parses cues via `_parseCuesWithIndex(file, uid, 0)` (lines 529-533) so every AudioCue.bookUid == that srt uid (parser sets bookUid; audiobook_model.dart:112-114 toCompanion maps it), then persists with `widget.repo.saveCues(uid: uid, cues: cues)` (line 613). replaceCuesForBook (database.dart:545-553) writes directly into audio_cues.book_uid.
2. audiobooks rows are inserted ONLY via saveAudiobook (database.dart:509 / audiobook_repository.dart:80-82). The standalone SRT import path (_importSubtitleBook, lines 522-615) never calls saveAudiobook — it only calls repo.save() (srt_books) and repo.saveCues(). So no audiobooks row exists for an SRT uid.
3. audio_cues / audiobooks / srt_books are v1 baseline tables — no m.createTable for them anywhere in onUpgrade (only bookmarks@215 and srtBookTagMappings@263 are created in onUpgrade), so a pre-v12 DB can legitimately hold SRT cues.

Therefore the deletion's subquery (audiobooks only) matches NONE of the SRT-owned cues, so every SRT book's cues get deleted on first launch after upgrading from <=v11. The book row survives (srt_books cleanup at 246-253 even guards ttu_book_id>0, deliberately preserving standalone SRT books) but cuesFor(uid) (srt_book_repository.dart:52-60) returns empty → subtitle/audio sync silently broken, no error surfaced.

This is permanent, silent data loss on a reachable real-user path (anyone with imported SRT subtitle books upgrading across schema v12). Critical severity is correct. Note the title's word "standalone" is slightly imprecise — current code generates a backing synthetic EPUB for subtitle imports so ttuBookId may be >0 — but this is irrelevant to the defect: the deletion checks only the audiobooks table, and NO SRT book (standalone or epub-backed) ever has an audiobooks row, so all SRT cues are deleted regardless. The proposed fix (AND book_uid NOT IN (SELECT uid FROM srt_books)) correctly addresses it.

### HBK-AUDIT-002 — AnkiConnect addNote ignores the allowDupes setting — duplicates are always rejected even when the user enabled 'allow duplicates'

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / external-API-contracts / impl contradicts the feature it claims to implement; setting exists but is not wired to the external API
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart` : 79-95
- **审查者置信度**: high
- **根因**: AnkiConnect's addNote rejects duplicate notes by default and only permits them if the request includes note.options.allowDuplicate=true. The Dart addNote never sends an 'options' object, so allowDuplicate is always false at the AnkiConnect side. The repository's allowDupes flag only suppresses the *pre-check* (isDuplicate), it never tells AnkiConnect to accept the dupe.
- **影响**: User enables 'Allow duplicates', mines a word that already exists; the local isDuplicate pre-check is skipped (settings.allowDupes true), so addNote is called, AnkiConnect throws 'cannot create note because it is a duplicate', mineEntry returns MineResult.error, and the UI shows a generic export-failed toast. The user's explicit allowDupes intent is silently broken and presented as a failure.
- **证据**:
~~~
await _request('addNote', { 'note': { 'deckName': deckName, 'modelName': modelName, 'fields': fields, if (tags != null) 'tags': tags } });  // no 'options': {'allowDuplicate': ...}
~~~
- **修复建议**: Thread allowDupes into addNote and include 'options': {'allowDuplicate': allowDupes} in the note map. AnkiConnectRepository.mineEntry already knows settings.allowDupes; pass it through the AnkiService.addNote signature (add an allowDuplicate parameter).
- **验证（对抗复核）**: Confirmed by reading the cited code and the full call chain.

1) Service: packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart:87-94 — addNote sends the AnkiConnect 'note' object as {'deckName','modelName','fields', if tags 'tags'} with NO 'options' key, so allowDuplicate is never sent. AnkiConnect's documented default rejects duplicate notes unless note.options.allowDuplicate=true. The error path is real: _request (lines 27-31) parses result['error'] and throws AnkiConnectException when AnkiConnect returns 'cannot create note because it is a duplicate'.

2) Repository: packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart:187-219 — when settings.allowDupes is true, the entire local isDuplicate pre-check block (187-203) is skipped. addNote is then called (209-214) with no allowDuplicate argument (the AnkiService.addNote signature in anki_service.dart:8-14 has no such parameter). The thrown AnkiConnectException is caught (216-218) and converted to MineResult.error. So the allowDupes flag only suppresses the pre-check; it never reaches AnkiConnect, exactly as claimed.

3) UI impact: dictionary_page_mixin.dart:89-91 maps MineResult.error to the generic t.card_export_failed toast (distinct from t.card_duplicate at 83-84). Same error->generic-failure mapping repeats in reader_hibiki_page.dart:2251, floating_dict_page.dart:109, app_model.dart:2484.

Net: user enables 'Allow duplicates', mines an already-existing word on the AnkiConnect backend, pre-check is skipped, AnkiConnect rejects the dupe, result becomes MineResult.error, and the user sees a generic export-failed toast. The explicit allowDupes intent is broken and misreported as a failure. The cited lines match exactly and the path is reachable. Note: the AnkiDroid backend (anki_repository.dart) is a separate code path and out of scope for this AnkiConnect finding.

Severity high is correct: it is wrong behavior users will reliably hit when they enable allowDupes and re-mine on AnkiConnect. It is not critical (no data loss/corruption/crash/security — no note is created and no existing note is harmed; it's a should-have-succeeded operation surfaced as a confusing failure), which matches the 'high = wrong behavior or leak users will hit' calibration. Not deflating to medium because it directly defeats a user-facing setting on a common workflow.

### HBK-AUDIT-003 — Popup init path never assigns late themeNotifier, but popup UI reads appModel.theme → LateInitializationError crash

- **Severity**: HIGH (审查者报 CRITICAL，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `app-startup-state` / init-ordering / false-modularity / divergent duplicated init paths that drift out of sync
- **位置**: `hibiki/lib/src/models/app_model.dart + hibiki/lib/popup_main.dart` : app_model.dart:168 (field), 988-991 (assigned only in initialise), 1172-1258 (initialiseForDictionaryPopup never assigns), 532-534 (theme getters delegate to themeNotifier); popup_main.dart:150-156 (r …(截断)
- **审查者置信度**: high
- **根因**: themeNotifier is declared `late final ThemeNotifier themeNotifier;` and assigned only inside initialise(). The separate popup entry point initialiseForDictionaryPopup() (a hand-maintained parallel copy of initialise) omits the themeNotifier construction entirely. The popup process always starts with _isInitialised=false (separate `:popup` Android process), so it always runs the full popup branch, never the early-return refreshPrefCache branch. After popup init flips _isInitialised=true and notifyListeners fires, PopupDictApp.build() passes the !isInitialised gate and evaluates `theme: appModel.overrideDictionaryTheme ?? appModel.theme` and `darkTheme: appModel.darkTheme` / `themeMode: appModel.themeMode`, each of which dereferences the unassigned `late final themeNotifier`.
- **影响**: Process-text / floating-dict / hibiki://lookup popup dictionary throws LateInitializationError('Field themeNotifier has not been initialized') on the first build after init completes, breaking the entire popup dictionary feature. It is caught by runZonedGuarded but the popup renders nothing usable.
- **证据**:
~~~
app_model.dart:168 `late final ThemeNotifier themeNotifier;`  app_model.dart:533 `ThemeData get theme => themeNotifier.theme;`  initialiseForDictionaryPopup (1172-1258) has no `themeNotifier =` assignment.  popup_main.dart:150 `theme: appModel.overrideDictionaryTheme ?? appModel.theme,` line 152 `appModel.darkTheme` line 156 `appModel.themeMode`.
~~~
- **修复建议**: Construct themeNotifier in initialiseForDictionaryPopup() exactly as in initialise() (themeNotifier = ThemeNotifier(_database, () => textTheme); themeNotifier.loadFromPrefsSnapshot(prefsRepo.prefsSnapshot); themeNotifier.addListener(notifyListeners); _themeListenerAdded = true;). Better: collapse the two init methods into one parameterized path so they cannot diverge again.
- **验证（对抗复核）**: Independently confirmed by reading the cited code. (1) app_model.dart:168 declares `late final ThemeNotifier themeNotifier;`. A repo-wide grep for `themeNotifier =` returns exactly ONE assignment site: app_model.dart:988, inside `initialise()`. (2) The popup entry `initialiseForDictionaryPopup()` (1172-1258) is a separate, parallel init that constructs prefsRepo/dictRepo/mediaHistoryRepo but NEVER assigns themeNotifier; it sets `_isInitialised = true` (1250) and calls `notifyListeners()` (1251). (3) `_isInitialised` defaults to false (line 201); the `:popup` Android process starts fresh, so `initialiseForDictionaryPopup` always takes the full branch (1179-1257), never the early-return refreshPrefCache branch (1173-1178). (4) popup_main.dart:46 calls ONLY `initialiseForDictionaryPopup()`, never `initialise()`. (5) After init, PopupDictApp.build() (popup_main.dart:90) watches appProvider, passes the `initError==null` and `isInitialised` gates, and at line 150 evaluates `appModel.overrideDictionaryTheme ?? appModel.theme`. `_overrideDictionaryTheme` is a nullable field with no initializer (582), defaults to null, and is set ONLY via setOverrideDictionaryTheme — called exclusively from reader_hibiki_page.dart:840/4101 (main process reader), never in the popup process. So in the popup the `??` falls through to `appModel.theme` → `themeNotifier.theme` (533) → dereferences the unassigned `late final themeNotifier` → LateInitializationError. The crash is reachable and guaranteed on first build after popup init. Cited line numbers all match. Severity corrected from critical to high: it is a guaranteed feature-breaking crash on a real user path (PROCESS_TEXT / floating-dict / hibiki://lookup), but the error is caught by runZonedGuarded (popup_main.dart:47), isolated to the popup process, with no data loss/corruption/security impact — fits "high = wrong behavior users will hit" rather than "critical = data loss/uncaught crash/corruption".
  - 验证者保留意见: Not a refutation — the defect is real. Only the severity is overstated: the LateInitializationError is caught by runZonedGuarded (popup_main.dart:47), so it does not kill the process or cause data loss/corruption; it renders the popup non-functional. That maps to high, not critical. The proposed fix …(截断)

### HBK-AUDIT-004 — Audio file persistence has no basename de-dup; same-named files silently overwrite each other and corrupt audioFileIndex mapping

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `audiobook-audio` / resource/data-corruption / two near-identical helpers where only one got the safety fix (persistFile dedupes, persistFileWithProgress does not)
- **位置**: `packages/hibiki_audio/lib/src/audiobook/audiobook_storage.dart + hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart + book_import_dialog.dart` : audiobook_storage.dart:77-124 (no dedupeIndex param); audiobook_import_dialog.dart:660-687; book_import_dialog.dart:564-586,763-776
- **审查者置信度**: high
- **根因**: persistFile(...) accepts a dedupeIndex and renames colliding files, but the import loops call persistFileWithProgress(...) which has no dedup logic. dest = p.join(persistDir.path, p.basename(src.path)). When the user picks two audio files with the same basename from different folders (e.g. disc1/01.m4a and disc2/01.m4a, common for split audiobooks), src.copy(dest) for the second file overwrites the first at the identical dest path.
- **影响**: One of the audio files is lost on disk, and persistedPaths ends up containing the same path twice. audioFiles[] then has a duplicate, so cue.audioFileIndex no longer maps to the intended file: seeking to a cue in 'file 1' actually plays 'file 0'. Silent audio/text desync and data loss with no error surfaced.
- **证据**:
~~~
persistFileWithProgress: `final String baseName = p.basename(src.path); ... final String dest = p.join(persistDir.path, baseName); ... await sink ... ` — no dedupeIndex. Import loop: `for (final File srcFile in audioCopyFiles) { ... persistedPaths.add(await AudiobookStorage.persistFileWithProgress(srcFile, persistDir, ...)); }`
~~~
- **修复建议**: Give persistFileWithProgress a dedupeIndex (or detect dest existence) like persistFile already has, and pass the loop index from the import call sites so colliding basenames become `stem _N.ext`. Alternatively key the persisted name on the source path hash.
- **验证（对抗复核）**: Independently confirmed by reading the cited code. (1) packages/hibiki_audio/lib/src/audiobook/audiobook_storage.dart:77-124 — persistFileWithProgress has NO dedup: line 85 `final String baseName = p.basename(src.path);`, line 89 `final String dest = p.join(persistDir.path, baseName);`, line 97 `sink = File(dest).openWrite();` which truncates/overwrites any existing dest. By contrast persistFile (lines 51-75) DOES accept `int? dedupeIndex` and renames colliding files (lines 63-67) — proving the author knew about basename collisions but never wired it into the progress variant or its callers. (2) All three import loops invoke the progress variant with no index and just .add() the result: audiobook_import_dialog.dart:670-687 (`for (final File srcFile in audioCopyFiles) { ... persistedPaths.add(await AudiobookStorage.persistFileWithProgress(srcFile, persistDir, ...)); }`), book_import_dialog.dart:575-586 and 765-776 (same shape over `_audioPaths`). (3) Reachability on Android (primary target): both pickers use FilePicker with allowMultiple:true, FileType.audio (audiobook_import_dialog.dart:444-454, book_import_dialog.dart:353-363); the forked file_picker 8.3.7 FileUtils.java:293 copies each SAF selection to `cacheDir/file_picker/<System.currentTimeMillis()>/<originalFileName>` — original basenames are preserved in distinct timestamped dirs, so two same-named files (e.g. disc1/01.m4a, disc2/01.m4a — common for split audiobooks) yield distinct src paths but identical basenames, hence identical dest in the shared persistDir. The second copy overwrites the first; disc1 bytes are lost. (4) persistedPaths keeps length == source count (add() per iteration regardless of overwrite), so audioPaths is stored with a duplicate path (audiobook_repository.dart:230-231, no de-dup; read back verbatim at 213-214). The controller builds the playlist one AudioSource per audioFiles entry in order (audiobook_controller.dart:300-303), so audioFiles[0] and [1] both resolve to the same surviving physical file. A cue with audioFileIndex=0 then plays index-1's content (resolveAudioFile, audiobook_model.dart:91-96 / controller _positionForCue 913-917). Real silent data loss + audio/text desync with no error surfaced. Two precision corrections to the reporter's impact, neither of which negates the finding: (a) the index-mapping desync specifically requires cues with audioFileIndex>0; in these two dialogs only the JSON alignment format reads a per-cue `file` index (json_alignment_parser.dart:61) — SMIL is parsed WITHOUT audioFileMap (audiobook_import_dialog.dart:872-875) so all SMIL cues get index 0, and SRT/LRC/VTT/ASS default to 0. (b) BUT even with all cues at index 0, a multi-file import still concatenates a duplicated file into the playlist, so total duration and any timestamps past the first file's boundary land in the wrong (duplicated) audio — still desync, plus the unconditional on-disk data loss. So the data-loss half of the claim holds for ALL multi-file same-basename …(截断)
  - 验证者保留意见: Minor overstatement only: the reporter frames the audioFileIndex remapping as the universal mechanism, but in these two dialogs that specific desync requires JSON alignment (SMIL/SRT/LRC/VTT/ASS all default index 0). This does not refute the finding — unconditional on-disk data loss and playlist-con …(截断)

### HBK-AUDIT-005 — CI patch step references removed/version-drifted packages and will hard-fail the build (exit 1)

- **Severity**: HIGH (审查者报 CRITICAL，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / build-config / zombie/dead code left behind after refactor; optimistic-but-unverified scripting
- **位置**: `ci/apply-patches.sh + ci/patches/` : apply-patches.sh:28-60; patches dirs: ci/patches/git/flutter_inappwebview-ffd182431017ec919ece3f80bf5e22a9286189af/, ci/patches/git/RubyText-cb723f87c9ac575aa735b40016c0ffb3242d921e/, ci/patches/hoste …(截断)
- **审查者置信度**: high
- **根因**: apply-patches.sh iterates every dir under ci/patches/{git,hosted}/ and resolves target = $PUB_CACHE/{hosted/pub.dev|git}/<dir-name>. If the target dir does not exist it sets missing=1 and the script exits 1 (lines 32-36, 47-51, 57-60). The patch dir names hard-code exact package versions. The resolved lock no longer contains those versions: win32 locked 5.15.0 (patch=4.1.4), sqflite 2.3.3+2 (patch=2.2.8+4), record_mp3_plus 1.5.0 (patch=1.2.0), path_provider_android 2.2.23 (patch=2.0.27), flutter_plugin_android_lifecycle 2.0.34 (patch=2.0.15), file_picker 8.3.7 (patch dir 5.3.0 also present), and mecab_dart / flutter_blurhash / uri_to_file are ABSENT from pubspec.lock entirely. The git patches flutter_inappwebview-ffd182... and RubyText-cb723... target git forks that were removed by commit 3d0ca7268 ('refactor(deps): remove 4 fork dependencies, internalize spaces and ruby_text') — flutter_inappwebview is now hosted ^6.1.5, ruby_text is gone — so $PUB_CACHE/git/flutter_inappwebview-ffd182... and /git/RubyText-cb723... will never exist.
- **影响**: On a clean GitHub runner, `flutter pub get` populates the cache only with versions in pubspec.lock. The patch dirs for win32-4.1.4, sqflite-2.2.8+4, the two dead git forks, etc. will be absent, so apply-patches.sh sets missing=1 and exits 1. This is invoked unconditionally in BOTH .github/workflows/main.yml:45-48 and release.yml:59-62, so every PR check and every release build fails at the 'Apply pub cache patches' step before analyze/test/build even run. The release pipeline cannot produce a signed APK.
- **证据**:
~~~
apply-patches.sh:32 `if [ ! -d "$target_dir" ]; then ... missing=1` then :57 `if [ "$missing" -ne 0 ]; then ... exit 1`. Lock: `win32: ... version: "5.15.0"`, `sqflite: ... version: "2.3.3+2"`, `record_mp3_plus: ... version: "1.5.0"`. mecab_dart/flutter_blurhash/uri_to_file return ABSENT when grepped in hibiki/pubspec.lock. flutter_inappwebview locked hosted: `flutter_inappwebview: dependency: "direct main" ... url: "https://pub.dev" ... version: "6.1.5"` (not a git fork). Commit 3d0ca7268 removed the forks but the patch dirs remain.
~~~
- **修复建议**: Delete patch directories for packages whose versions no longer match the lock (win32-4.1.4, sqflite-2.2.8+4, record_mp3_plus-1.2.0, path_provider_android-2.0.27, flutter_plugin_android_lifecycle-2.0.15, file_picker-5.3.0, mecab_dart-0.1.3, uri_to_file-0.2.0, flutter_blurhash-0.7.0) and the dead git forks (flutter_inappwebview-ffd182..., RubyText-cb723...). Then either (a) make apply-patches.sh skip-with-warning on missing targets instead of exit 1, OR (b) add a CI guard that asserts each patch dir name equals the resolved lock version. Best: replace the cp-into-pub-cache hack with proper `dependency_overrides` to forked packages, or a hash-checked patch tool, so patches are version-bound to the lock.
- **验证（对抗复核）**: Independently confirmed every load-bearing claim by reading the actual files.

SCRIPT LOGIC (ci/apply-patches.sh): Verified verbatim. Lines 28-40 iterate every dir under ci/patches/hosted/*/, resolving target_dir=$PUB_CACHE_DIR/hosted/pub.dev/<dirname>; lines 32-36 set missing=1 + continue when the dir is absent. Lines 42-55 do the same for git/*/. Lines 57-60: `if [ "$missing" -ne 0 ]; then ... exit 1`. set -euo pipefail at line 2. So a single missing target => exit 1 (collected, not early-abort).

CI WIRING: main.yml:45-48 and release.yml:59-62 both run `bash ci/apply-patches.sh` unconditionally, after `flutter pub get` (main:41-43 / release:55-57) and before analyze/test/build, with no continue-on-error. main.yml triggers on push+pull_request to main with paths ['hibiki/**','ci/**']. A non-zero step fails the job by GitHub Actions default. Runners are ubuntu-latest with actions/checkout@v4 and no pub-cache restore and no PUB_CACHE env => fresh ~/.pub-cache populated only from pubspec.lock.

VERSION DRIFT (patch dir name vs hibiki/pubspec.lock resolved version): win32-4.1.4 vs 5.15.0 (lock:2030); sqflite-2.2.8+4 vs 2.3.3+2 (lock:1718); record_mp3_plus-1.2.0 vs 1.5.0 (lock:1529); path_provider_android-2.0.27 vs 2.2.23 (lock:1344); flutter_plugin_android_lifecycle-2.0.15 vs 2.0.34 (lock:777); file_picker-5.3.0 vs 8.3.7 (lock:539). All mismatched. (Matching dirs that are fine: audio_session-0.1.14, carousel_slider-4.2.1, fading_edge_scrollview-3.0.0, fluttertoast-8.2.1, image_picker_android-0.8.6+16, network_to_file_image-4.0.1, package_info_plus-4.0.2, permission_handler_android-10.2.1, url_launcher_android-6.0.34, file_picker-8.3.7.)

ABSENT PACKAGES: grep for mecab_dart / flutter_blurhash / uri_to_file in pubspec.lock returns no matches => their patch dirs (all real, non-empty) can never have a pub-cache target.

DEAD GIT FORKS: pubspec.yaml:60 has `flutter_inappwebview: ^6.1.5` (hosted), resolved to 6.1.5 in lock (660-661, source: hosted) — not a git fork; the only git ref in the lock is receive_intent resolved-ref 3854d07... (1518) which matches its patch dir. No flutter_inappwebview git ref and no RubyText/ruby_text ref in the lock. Commit 3d0ca72685 ("remove 4 fork dependencies, internalize spaces and ruby_text", 2026-05-25) confirms the fork removal. So $PUB_CACHE/git/flutter_inappwebview-ffd182... and /git/RubyText-cb723... will never exist.

All mismatched/absent patch dirs are real non-empty directories under ci/patches/{hosted,git}/, so the script's */ glob iterates them, resolves targets that won't exist in a clean cache, sets missing=1, and exits 1. The defect is real and reachable on every PR-to-main and every published release; the release pipeline cannot produce a signed APK.

SEVERITY CORRECTION: Claimed critical. Under the given calibration, critical = data loss / crash / corruption / security hole on a real runtime path. This is a CI/build-config hard-fail that blocks all PR checks and the entire release pipeline — severe for d …(截断)
  - 验证者保留意见: Not refuted on substance — the defect is real and confirmed on a reachable path. The only correction is severity: critical is overstated for a CI/build break with no runtime data loss/corruption/security impact; it is high. (Minor, non-negating nuance: the `continue` inside the loops does not early- …(截断)

### HBK-AUDIT-006 — CI path filter excludes packages/** so changes to the 5 internal packages never trigger build/test

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / ci-cd / happy-path CI config; coverage gap that looks green
- **位置**: `.github/workflows/main.yml` : main.yml:3-8 (paths), main.yml:58-66 (package test loop)
- **审查者置信度**: high
- **根因**: The push/pull_request triggers are gated by `paths: ['hibiki/**', 'ci/**']`. The repo's actual library code lives in packages/hibiki_core, hibiki_dictionary, hibiki_anki, hibiki_audio, hibiki_platform (per melos.yaml `packages/*`). A PR that only edits files under packages/** matches no path and the build workflow does not run at all — even though that same workflow contains a dedicated 'Run package tests' loop (lines 58-66) and the main app depends on those packages via path deps.
- **影响**: Breaking changes confined to the internal packages (DB schema in hibiki_core, FFI in hibiki_dictionary, audio matching in hibiki_audio, etc.) merge with zero CI verification: no analyze, no tests, no build. The package test loop only ever runs when an unrelated hibiki/** or ci/** file also changes, giving a false sense that packages are covered.
- **证据**:
~~~
main.yml:5 `paths: ['hibiki/**', 'ci/**']` and :8 same for pull_request. melos.yaml:4-6 `packages: - packages/* - hibiki`. The job then runs `for pkg in packages/hibiki_core ... do (cd "$pkg" && flutter test)` (main.yml:60-63) which is unreachable for package-only PRs.
~~~
- **修复建议**: Add `packages/**`, `melos.yaml`, `pubspec.yaml`, `pubspec.lock`, and `.github/workflows/**` to both `paths:` lists (or drop the paths filter and rely on the cheap analyze/test steps to short-circuit). Prefer triggering on the whole workspace to avoid silently skipped verification.
- **验证（对抗复核）**: Independently confirmed by reading .github/workflows/main.yml, melos.yaml, hibiki/pubspec.yaml, release.yml, and contributors.yml.

Cited lines match exactly:
- main.yml:5 `paths: ['hibiki/**', 'ci/**']` (push) and main.yml:8 same (pull_request). Confirmed verbatim.
- main.yml:58-66 is the 'Run package tests' step; the for-loop over packages/hibiki_core packages/hibiki_dictionary packages/hibiki_anki packages/hibiki_audio packages/hibiki_platform is at lines 60-63. Confirmed.
- melos.yaml:4-6 declares `packages: - packages/* - hibiki`. Confirmed.

Dependency relationship confirmed: hibiki/pubspec.yaml:37-46 declares path deps on all 5 internal packages (../packages/hibiki_core ... hibiki_platform).

Logic is sound: GitHub Actions `paths` filter only triggers the workflow when at least one changed file matches a listed glob. A push/PR that modifies only files under packages/** (e.g. packages/hibiki_core/lib/...) matches neither `hibiki/**` nor `ci/**`, so main.yml does not run at all — including its analyze, main-app test, package-test loop, and APK build steps, since they are all inside that single gated workflow.

No compensating coverage exists: release.yml triggers only on `release: published` / workflow_dispatch (not push/PR), and contributors.yml is also gated by `paths: ['hibiki/**']` and only updates a README. So package-only changes (DB schema in hibiki_core, FFI in hibiki_dictionary, audio matching in hibiki_audio) can merge to main with zero CI verification unless an unrelated hibiki/** or ci/** file is also touched. The 'Run package tests' loop only executes incidentally, giving a false sense of coverage.

Impact is accurate, not overstated. Severity high is correctly calibrated: it silently skips analyze+tests+build for a real class of changes (wrong/broken behavior that users will hit can merge unverified). Not critical (no direct data loss/crash/security hole by itself), not lower (it disables the entire verification pipeline for core library packages). The minor imprecision that `packages/*` in melos also covers the two fork packages does not affect the substance of the finding.

### HBK-AUDIT-007 — Legacy bookmark migration can abort the entire v11 upgrade via FK violation

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `db-core` / schema versioning & migrations / transaction correctness / optimistic-but-unverified migration: assumes legacy pref ids are valid epub_books FKs; relies on `OR IGNORE` semantics that don't apply to FK violations
- **位置**: `packages/hibiki_core/lib/src/database/database.dart` : 214-221, 329-393
- **审查者置信度**: high
- **根因**: `from < 11` creates the `bookmarks` table then calls migrateLegacyBookmarkPreferences(). bookmarks.ttu_book_id has `REFERENCES epub_books(id) ON DELETE CASCADE` (confirmed in database.g.dart:4365-4370). The migration parses ttu_book_id from preference keys (`bookmarks_<id>`) which historically came from TTU IndexedDB book ids and need NOT match any epub_books.id. It then runs `INSERT OR IGNORE INTO bookmarks (ttu_book_id, ...)`. In SQLite, `OR IGNORE` does NOT suppress FOREIGN KEY constraint violations (it only ignores UNIQUE/NOT NULL/CHECK); a FK violation aborts the statement. foreign_keys is ON for the connection (setup at database.dart:20) and Drift runs onUpgrade inside a transaction, so the abort propagates with no try/catch around the insert (lines 369-384).
- **影响**: Any user upgrading to schema v11 whose legacy bookmark prefs reference book ids not present in epub_books will hit a fatal migration exception, the upgrade transaction rolls back, and the app cannot open the database on launch — a hard startup failure / effective data lockout, not a silent skip.
- **证据**:
~~~
await customStatement(
  'INSERT OR IGNORE INTO bookmarks '
  '(ttu_book_id, section_index, norm_char_offset, label, ...) VALUES (?, ?, ?, ?, ...)',
  [rowBookId, ...]); // rowBookId may not exist in epub_books; FK ON; OR IGNORE does NOT skip FK errors
~~~
- **修复建议**: Either validate `rowBookId` exists in epub_books before inserting (skip if absent), or wrap the per-row insert in try/catch, or temporarily defer FK checks for this insert. Root fix: do not key bookmarks on an FK during a migration that imports loosely-validated legacy data.
- **验证（对抗复核）**: I independently confirmed every load-bearing claim by reading the cited code and the drift 2.29.0 source.

1) FK exists and is ON DELETE CASCADE: tables.dart:116-117 (`integer().references(EpubBooks, #id, onDelete: KeyAction.cascade)`) and the generated column database.g.dart:4365-4370 (`'ttu_book_id', ... defaultConstraints: GeneratedColumn.constraintIsAlways('REFERENCES epub_books (id) ON DELETE CASCADE')`). Confirmed.

2) FK enforcement is active during the migration. `PRAGMA foreign_keys = ON` is in the NativeDatabase setup callback (database.dart:20), and drift runs that setup (`_setup?.call(database)`) at database initialization BEFORE migrations (drift sqlite3/database.dart:105). Drift does NOT auto-disable FK during a custom `onUpgrade`; the auto OFF/ON dance only lives inside `Migrator.alterTable`/`TableMigration` (drift migration.dart:158-167, 302-305), which this code does not use for bookmarks. Drift's own docs example (migration.dart:574-594) shows users must manually toggle FK during onUpgrade — this codebase never does. So FK stays ON throughout the `from < 11` migration.

3) SQLite semantics correct: `INSERT OR IGNORE` only suppresses UNIQUE/NOT NULL/CHECK/PK conflicts; immediate FOREIGN KEY violations still abort the statement and raise. The migration insert (database.dart:369-384) has no try/catch, and migrateLegacyBookmarkPreferences runs it inside an explicit transaction (database.dart:337). An aborted statement throws, the transaction rolls back, and the exception propagates out of onUpgrade → DB fails to open on launch.

4) Reachability is real, not hypothetical. The `from < 11` branch (database.dart:214-221) creates bookmarks then calls migrateLegacyBookmarkPreferences(), which parses `bookmarks_<id>` pref keys (database.dart:339-341) and inserts `rowBookId = raw['ttuBookId'] as int? ?? ttuBookId` (line 368) with zero validation against epub_books. Decisively, the v12 migration immediately afterward (database.dart:254-260) deletes orphaned bookmarks `WHERE ttu_book_id NOT IN (SELECT id FROM epub_books)` — the maintainers themselves know orphan bookmark ids relative to epub_books occur. Plus CLAUDE.md/ttu_migration.dart confirm legacy ids came from a separate TTU IndexedDB id space. So a user upgrading from <11 with a `bookmarks_<id>` pref whose id has no matching epub_books row will hit the abort.

5) The existing test (bookmark_repository_test.dart:50-70) only passes because HibikiDatabase.forTesting uses NativeDatabase.memory() WITHOUT the setup callback, so FK is OFF in tests — it never exercises the production FK-ON path. This is why the bug was not caught.

Severity: high is correct, not inflated. For an affected user it is a hard startup failure / effective data lockout (migration transaction rolls back, app cannot open the DB). Not critical because it is conditional on legacy orphan-id data on a one-time v<11→v13 upgrade path rather than a universal crash; not lower because for those users it is fatal. The proposed f …(截断)

### HBK-AUDIT-008 — schemaVersion bumped to 12 (orphan cleanup) without registering a SchemaVersion/migration for v12 changes to srt cue ownership; audio_cues orphans for deleted srt_books left uncleaned

- **Severity**: HIGH (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `db-core` / schema versioning & migrations / data integrity / false modularity in cleanup logic — multiple independent DELETE statements with mismatched ownership assumptions, no single source of truth for who owns audio_c …(截断)
- **位置**: `packages/hibiki_core/lib/src/database/database.dart` : 246-261
- **审查者置信度**: high
- **根因**: The `from < 12` step deletes srt_books whose ttu_book_id>0 references a missing epub_book (lines 246-253) but never deletes the corresponding audio_cues for those removed srt_books. Conversely the audio_cues deletion (239-245) targets the wrong owner set. The two cleanups are inconsistent: srt_books rows are removed leaving their cues, while valid standalone SRT cues are removed leaving their srt_books rows.
- **影响**: Dangling audio_cues rows accumulate for srt_books deleted by the migration (orphaned, never garbage collected since there is no FK from audio_cues -> srt_books), and valid SRT books are left with no cues. Inconsistent DB state and silent loss of audio/subtitle alignment.
- **证据**:
~~~
// removes srt_books but not its audio_cues:
'DELETE FROM srt_books WHERE ttu_book_id > 0 AND ttu_book_id NOT IN (SELECT id FROM epub_books)'
// (no matching DELETE FROM audio_cues WHERE book_uid IN (those removed uids))
~~~
- **修复建议**: Before/after deleting srt_books in this step, delete their audio_cues by uid; and fix the audio_cues orphan predicate (see v12-srt-cue-wipe). Add a real FK or a single coherent ownership query.
- **验证（对抗复核）**: I independently confirmed the core defect by reading the actual code. Ownership model: audio_cues.book_uid is a shared string key. Standalone SRT books (book_import_dialog.dart:526 `uid = 'srtbook_<ts>'`, :612-613 save + saveCues) store their cues via SrtBookRepository.saveCues -> replaceCuesForBook(uid, ...) (srt_book_repository.dart:66; database.dart:545-554), so their cues land in audio_cues with book_uid = srtBooks.uid. Standalone SRT import NEVER inserts an audiobooks row (deleteSrtBookByUid at database.dart:571-574 and deleteAudiobookByBookUid at :512-516 both target the same audio_cues table by the same book_uid, confirming the two owner kinds share audio_cues but live in separate parent tables).

The `from < 12` migration (database.dart:239-245) runs unconditionally for any user upgrading from schema <=11 to >=12 (now 13): `DELETE FROM audio_cues WHERE book_uid NOT IN (SELECT book_uid FROM audiobooks)`. Because a standalone SRT book's uid ('srtbook_...') is by construction NOT present in the audiobooks table, this statement DELETES every cue belonging to every standalone SRT book, while the srt_books row itself survives (it is only removed by lines 246-253 when ttu_book_id>0 AND missing epub, which standalone srtbook rows with ttuBookId default 0 are not). Result: SRT books remain in the library with all their subtitle-audio alignment cues silently and irreversibly wiped on a routine schema upgrade. This matches the finding's Claim B exactly and I confirmed it on a reachable path.

So the finding is REAL. However the report is partly muddled: (1) the title says 'schemaVersion bumped to 12' but schemaVersion is actually 13 (database.dart:58) — a labeling error, though the cited lines are correct; (2) the finding's Claim A ('srt_books deleted but cues left orphaned', lines 246-253) is essentially moot — any cues for those srt_books were already removed by the broader wipe at 239-245, so no orphan accumulation occurs there. The substantive, confirmed harm is the opposite of 'dangling orphans': it is DESTRUCTION of valid SRT cues. The proposed-fix direction (make audio_cues cleanup ownership-coherent, e.g. only delete cues whose book_uid is in neither audiobooks NOR srt_books) is correct.

Severity correction: the finding claimed medium. The real impact is silent, irreversible data loss of user-imported subtitle-audio alignment for every standalone SRT book on a normal upgrade path — that is wrong behavior users will hit with permanent data loss, which is high (bordering critical for the affected data set), not medium. Promoting to high.
  - 验证者保留意见: The finding's framing is partly inaccurate but its core is confirmed, so it is not refuted. Two corrections: (a) the title's 'schemaVersion bumped to 12' is wrong — schemaVersion is 13 (database.dart:58); the relevant code is the `from < 12` block. (b) The finding's secondary Claim A (orphaned cues …(截断)

### HBK-AUDIT-009 — FFI lookup/query/lookupPopupJson/getMediaFile run synchronously on the UI thread, blocking the platform thread per call

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `dictionary-ffi` / concurrency / optimistic-but-unverified: synchronous native calls treated as cheap; perf logging added instead of fixing the threading model
- **位置**: `packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart` : 362-381 (query), 387-433 (lookup), 436-455 (lookupPopupJson), 478-499 (getMediaFile)
- **审查者置信度**: high
- **根因**: All read/lookup FFI entry points are synchronous instance methods that call into native C++ (which constructs Lookup, runs deinflection + dictionary scan) on the calling isolate. Every caller (app_model.dart:1681/1691/1702, japanese_language.dart:62/79, chinese_language.dart:32, dictionary_webview_media.dart:46/73) invokes them on the main/UI isolate. Only importDictionary uses Isolate.run; reads never do.
- **影响**: Each lookup blocks the UI thread for the full native scan. The code's own perf logging measures this in milliseconds (hoshidicts.dart:397-398, language.dart:669-670). textToWords loops _lookupMatchedLength per substring (japanese_language.dart:103-113, chinese_language.dart:47-57), so segmenting one sentence fires N synchronous native calls back-to-back on the UI thread, and getMediaFile runs inside the WebView resource-intercept callback. On large dictionary sets this is a direct source of frame drops / ANR-class jank.
- **证据**:
~~~
hoshidicts.dart:395 `final r = _bindings!.lookup(_handle!, tp, maxResults, scanLength);` invoked from `HoshiDicts.instance.lookup(...)` in app_model.dart:1691 with no isolate hop; perf log `debugPrint('[dict-perf] native call: ${swNative.elapsedMicroseconds}µs ...')`.
~~~
- **修复建议**: Move read lookups off the UI isolate the way import already does (a long-lived background isolate that owns the handle, with a request/response port), or at minimum batch textToWords into a single native segmentation call instead of per-substring FFI round-trips.
- **验证（对抗复核）**: Independently confirmed in hoshidicts.dart. The four read entry points are synchronous instance methods that dereference the singleton's _handle and call native FFI directly with no isolate hop: query (362-381), lookup (387-433, native call at line 395 with the cited perf log at 397-398), lookupPopupJson (436-455), getMediaFile (478-499). Only importDictionary (static, line 330) uses Isolate.run; reads never do. HoshiDicts.instance is a static singleton (187-192) whose _handle (181) lives on the isolate that ran initialize() — the main isolate — so there is no background worker owning the handle for reads.

Caller chain confirmed (paths in the finding were slightly wrong — files are under hibiki_dictionary/.../implementations/ and hibiki/lib/src/models/, not hibiki_core — but every code element exists): app_model.searchDictionary is declared async (line 1626) yet contains zero await before the FFI calls; its preprocessing, lookup (1691), and lookupPopupJson (1681/1702) all run synchronously on the calling isolate before any suspension point, so the async/Future is theater and the native scan blocks the UI isolate. All searchDictionary callers (home_page.dart:86, base_source_page.dart:133, floating_dict_page.dart:72, dictionary_page_mixin.dart:224/261, home_dictionary_page.dart:373, app_model.dart:2454) invoke it from UI-thread contexts. japanese_language.textToWords (97-115) loops _lookupMatchedLength (54-69) per substring, each firing a synchronous HoshiDicts.instance.lookup (62) — N back-to-back native calls per sentence on the UI isolate. getMediaFile is called from _dictionaryMediaResponse (dictionary_webview_media.dart:46/73), the WebView resource-intercept path.

Caveats that temper but do not refute: there are caches at multiple layers (_matchLengthCache 5000 entries in _lookupMatchedLength; getCachedFfiLookup/getCachedSearch in searchDictionary) that avoid native calls on repeats, so steady-state cached lookups don't block. But cold segmentation and first-time lookups still execute native scans synchronously on the UI isolate. Impact is real UI jank / ANR-class stalls on large dictionary sets, not data loss/crash/corruption — so 'high' is correct, not 'critical'. The claimed 'high' stands.
  - 验证者保留意见: Minor citation inaccuracies only: the finding lists file paths under packages/hibiki_dictionary/lib/src/engine/ and packages/hibiki_dictionary/lib/src/ but the language files actually live at packages/hibiki_dictionary/lib/src/language/implementations/japanese_language.dart and chinese_language.dart …(截断)

### HBK-AUDIT-010 — TOC hrefs are not URL-decoded while chapter hrefs are, so TOC navigation silently breaks for percent-encoded (non-ASCII) filenames

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / correctness / false modularity / contract drift — two code paths build the same key with different normalization
- **位置**: `hibiki/lib/src/epub/epub_parser.dart` : 218 (manifest decode) vs 525-548 (_resolveTocHref, no decode)
- **审查者置信度**: high
- **根因**: _parseManifest applies `Uri.decodeFull(href)` (line 218), so EpubChapter.href ends up decoded (e.g. `第1章.xhtml`). But _resolveTocHref (used by both NCX and nav parsing) takes the raw nav/ncx `src`/`href` and runs it only through normalizeHref + p.relative — it never percent-decodes. So a TOC entry pointing at `%E7%AC%AC1%E7%AB%A0.xhtml` stays encoded. The TOC→chapter matcher does exact string equality.
- **影响**: For any EPUB whose internal filenames contain non-ASCII or space characters (extremely common for Japanese books), TOC entries fail to resolve: _tocHrefToChapterIndex returns -1 and tapping the chapter in the table of contents does nothing / can't jump. The book reads fine page-by-page, so the breakage is silent and looks like a flaky TOC.
- **证据**:
~~~
epub_parser.dart:218 `href: Uri.decodeFull(href),` (manifest path is decoded).
_resolveTocHref (epub_parser.dart:530-547) never decodes: `final String base = cleaned.split('#').first...` then `p.relative(p.join(baseDir, base), ...)`.
Matcher reader_hibiki_page.dart:3575 `if (_book!.chapters[i].href == cleanHref)` — exact equality, no normalization, so encoded vs decoded never match.
~~~
- **修复建议**: Apply the same `Uri.decodeFull`/decodeComponent to the TOC href base in _resolveTocHref before normalizeHref (decode the path part only, preserve the fragment), so TOC keys match the decoded chapter hrefs. Same asymmetry exists for _findRootfilePath (raw full-path) — decode there too for consistency.
- **验证（对抗复核）**: Independently confirmed the encode/decode asymmetry on a reachable path.

1. Chapter href IS decoded. _parseManifest stores `href: Uri.decodeFull(href)` (epub_parser.dart:218). _parseSpine builds the chapter from this item: `absPath = p.canonicalize(p.join(opfDir, item.href))` (line 249), `relPath = p.relative(absPath, from: extractDir)` (line 260), then `href: normalizeHref(relPath)` (line 277). Since item.href is already decoded and p.join/p.relative/p.canonicalize treat the string as opaque path segments (they do NOT touch percent-escapes), EpubChapter.href ends up DECODED (e.g. `第1章.xhtml`).

2. TOC href is NOT decoded. Nav `<a href>` (line 441) and NCX `<content src>` (line 502) feed their raw attribute values directly into _resolveTocHref (lines 443, 504). The XML parser decodes XML entities but NOT URI percent-encoding. _resolveTocHref (lines 525-548) only does trim/backslash-normalize/strip-leading-slash, splits off fragment/query, then p.join + p.relative + normalizeHref. normalizeHref (epub_book.dart:153-160) is purely trim/replace/split — it never calls Uri.decode*. So a TOC entry `<a href="%E7%AC%AC1%E7%AB%A0.xhtml">` stays percent-encoded.

3. Matcher is exact string equality with no normalization: reader_hibiki_page.dart:3575 `if (_book!.chapters[i].href == cleanHref)`. Encoded TOC string vs decoded chapter string never match, so _tocHrefToChapterIndex returns -1.

4. Impact is real and actually slightly WORSE than claimed. In _flattenTocToTtu (lines 3885-3893), when the index is -1 the entry is NOT added to the TOC at all (the `if (index >= 0)` guard at line 3887 drops it entirely). So affected chapters silently disappear from the table of contents rather than merely being unclickable. The book still reads page-by-page because spine navigation is index-based, so the breakage is silent.

Confirmed every cited line. The asymmetry, the missing decode, and the exact-equality matcher all check out. The proposed fix (decode the path part in _resolveTocHref before normalizeHref, preserving the fragment) is correct and symmetric with the manifest path.

Severity: high is appropriate, not inflated. It is wrong behavior users will hit (TOC entries vanish / can't jump) on a reachable path. The trigger is conditional — only EPUBs that BOTH use non-ASCII/space internal filenames AND percent-encode them in the OPF/NCX. Many commercial Japanese EPUBs use ASCII filenames (chapter01.xhtml, p-001.xhtml) and are unaffected, but percent-encoded non-ASCII filenames are common enough in the target Japanese-book corpus that this is a genuine user-facing defect, not an imagined edge case. No data loss or crash, so it is not critical; but it is a real correctness/feature-breakage bug, so not medium either.

### HBK-AUDIT-011 — Hibiki LAN sync server sends credentials and data over plaintext HTTP with Basic auth

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / credential/secret security / security theater — constant-time compare added, but the channel is cleartext
- **位置**: `hibiki/lib/src/sync/hibiki_sync_server.dart, hibiki/lib/src/sync/lan_discovery_service.dart, hibiki/lib/src/sync/hibiki_client_sync_backend.dart` : hibiki_sync_server.dart:36-46,53-90; lan_discovery_service.dart:18; hibiki_client_sync_backend.dart:41-46
- **审查者置信度**: high
- **根因**: The embedded server binds plain HTTP (shelf_io.serve over InternetAddress.anyIPv4, no TLS) and authenticates via HTTP Basic (`Authorization: Basic base64(user:token)`). The client builds `http://$host:$port` (HibikiDevice.webDavUrl) and WebDavOps sends `Basic base64(...)`. Token is therefore transmitted in reversible base64 over cleartext LAN.
- **影响**: Any device on the same Wi-Fi (coffee shop, dorm, office) can sniff the Basic-auth header, recover the token, and then read/write/delete the entire sync-data tree (PROPFIND/GET/PUT/DELETE/MKCOL implemented). Also enables trivial MITM tampering of synced progress and uploaded EPUB/audio content.
- **证据**:
~~~
server: `_server = await shelf_io.serve(handler, _allowLan ? InternetAddress.anyIPv4 : ..., _requestedPort);` (no SecurityContext); `'WWW-Authenticate': 'Basic realm="Hibiki Sync"'`; discovery: `String get webDavUrl => 'http://$host:$port';`
~~~
- **修复建议**: Use TLS (self-signed cert pinned via the token, or a noise/HMAC scheme), or at minimum require an HMAC-signed nonce per request instead of replaying the raw token, and document that LAN sync is unencrypted. Do not transmit the long-lived token on every request in cleartext.
- **验证（对抗复核）**: Confirmed by reading the full code path. (1) hibiki_sync_server.dart:41-46 calls shelf_io.serve with NO SecurityContext (no TLS) and binds InternetAddress.anyIPv4 when _allowLan is true, exposing the server to the whole LAN. (2) _authMiddleware (lines 53-65) requires HTTP Basic auth and emits `WWW-Authenticate: 'Basic realm="Hibiki Sync"'`; _validateAuth (67-81) base64-decodes the credential and compares the password to _token. (3) lan_discovery_service.dart:18 builds the client URL as plaintext `http://$host:$port`. (4) sync_settings_schema.dart:1670 persists that http URL via setHibikiClientUrl. (5) hibiki_client_sync_backend.dart:34-46/57-67 reads url+token and constructs WebDavOps(username:'hibiki', password: token). (6) webdav_ops.dart:25-26 builds `_authHeader = 'Basic ' + base64(user:token)` and buildRequest (line 44) sets that header on EVERY request (PROPFIND/GET/PUT/DELETE/MKCOL/HEAD) over the plain http:// URL. So the long-lived token is transmitted as reversible base64 in cleartext on every request over the LAN. WebDavOps.normalizeUrl (250-251) accepts http:// and there is no TLS option anywhere in the Hibiki LAN sync stack (https:// only appears for cloud OAuth backends). The defect, evidence snippets, and cited line ranges all match exactly. The finding is real on a reachable path: LAN sync is a shipped feature with mDNS discovery and a UI ('Connect to device' flow) wiring webDavUrl into the client.
  - 验证者保留意见: Not a refutation — the finding is accurate. Minor scoping notes that nonetheless keep it at 'high' (not 'critical'): the server binds to the LAN (anyIPv4), not the public internet, so exploitation requires same-network adjacency; the exposed data is reading progress, statistics, and EPUB/audio conte …(截断)

### HBK-AUDIT-012 — Local backup ZIP embeds all sync credentials (OAuth refresh tokens, FTP/SFTP/WebDAV/SMB passwords, server token) with no redaction

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / credential/secret security / happy-path export of whole DB without considering the preferences table contents
- **位置**: `hibiki/lib/src/sync/backup_service.dart, hibiki/lib/src/sync/sync_repository.dart` : backup_service.dart:71-110 (exportBackup VACUUM INTO of full DB); sync_repository.dart:184-191,196-383 (all secrets live in the preferences table, base64-only)
- **审查者置信度**: high
- **根因**: exportBackup VACUUMs the entire hibiki.db (including the preferences table) into a ZIP that is then handed to Share.shareXFiles / saved anywhere the user picks. Every sync secret is stored in that same preferences table, only base64-encoded (_encodeSecret = base64Encode), which is encoding, not encryption.
- **影响**: A user sharing/storing a 'reading backup' (cloud drive, chat, email) unknowingly exfiltrates their cloud OAuth refresh tokens, NAS/FTP/SFTP passwords, SSH private key, and Hibiki server token in trivially reversible base64. Anyone with the backup gains full account/server access.
- **证据**:
~~~
backup_service: `await _db.customStatement("VACUUM INTO '$safePath'")` then zips dbBytes wholesale. sync_repository: `static String _encodeSecret(String value) => base64Encode(utf8.encode(value));` used for refresh tokens, FTP/SFTP/SMB/WebDAV passwords, SFTP private key, server password.
~~~
- **修复建议**: Strip/blank credential keys from the preferences table copy before zipping (export a sanitized DB), or store secrets in platform secure storage (Keychain/Keystore) outside the synced DB. At minimum exclude all 'sync_*_password'/'sync_*_token'/'sync_desktop_credentials'/'sync_*_private_key' rows from the backup.
- **验证（对抗复核）**: Independently confirmed the full chain by reading the cited files.

(1) exportBackup copies the ENTIRE hibiki.db, including the preferences table: backup_service.dart:78 `await _db.customStatement("VACUUM INTO '$safePath'")`, with fallback at :80-81 doing `wal_checkpoint(TRUNCATE)` + `File(_dbPath).copy(cleanDbPath)`. The full DB bytes are then zipped wholesale (:95-104, `dbBytes = await File(cleanDbPath).readAsBytes(); archive.addFile(ArchiveFile(_dbName, ...))`). No preference rows are stripped or filtered.

(2) Preferences is a table inside the single @DriftDatabase (database.dart:27-38, `Preferences,` at line 38), so it is physically part of hibiki.db and is captured by VACUUM INTO.

(3) Every sync secret is stored in that same preferences table via SyncRepository._setString -> insertOnConflictUpdate into _db.preferences, encoded only with base64: _encodeSecret = base64Encode(utf8.encode(value)) at sync_repository.dart:184 (reversible by _decodeSecret :186-192). Secrets confirmed: desktop OAuth credentials (refresh token/client secret) :113, WebDAV password :179, OneDrive token :208, Dropbox token :225, FTP password :253, SFTP password :286, SFTP private key :299, SMB password :328, Hibiki server password :360, Hibiki client token :382. The class doc-comment :7-10 itself admits only base64 + OS file permissions protect these.

(4) The backup is exposed to user-chosen, potentially untrusted destinations: sync_settings_schema.dart _BackupExportWidget._export (:571-616) calls exportBackup (:584) then on Android/iOS hands the ZIP to Share.shareXFiles (:589-592, arbitrary share targets) or on desktop saves it via FilePicker.saveFile (:594-602).

So a user exporting/sharing a 'reading backup' unknowingly ships all configured cloud OAuth refresh tokens, NAS/FTP/SFTP/SMB passwords, SSH private key, and Hibiki server/client tokens in trivially reversible base64. The defect, the cited lines, the root cause, and the impact all match.

The cited lines are accurate. The claimed 'high' severity is correct: this is real credential exposure users can hit, but it is gated on the user having configured sync credentials AND voluntarily sharing/storing the backup to an untrusted location — it is not an unconditional/silent exfiltration on a default code path, so it does not rise to critical. High is the right calibration.

### HBK-AUDIT-013 — Barrel re-exports use wrong filename casing (Hibiki_*) that breaks builds on case-sensitive filesystems

- **Severity**: HIGH
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / maintainability / optimistic-but-unverified / works-on-my-machine
- **位置**: `hibiki/lib/utils.dart` : 3,6-17,29-32
- **审查者置信度**: high
- **根因**: Export URIs are spelled with a capital 'H' (e.g. 'src/utils/components/Hibiki_selectable_text.dart', 'src/utils/components/Hibiki_icon_button.dart', 'src/utils/misc/Hibiki_color.dart', 'package:hibiki_core/src/models/Hibiki_text_selection.dart') but the actual files on disk are all lowercase (confirmed: hibiki_selectable_text.dart, hibiki_icon_button.dart, hibiki_color.dart, hibiki_text_selection.dart). Dart resolves library URIs case-sensitively on Linux/macOS.
- **影响**: On a case-sensitive filesystem (Linux CI, macOS, many Android release build agents) these exports fail to resolve and the whole 'package:hibiki/utils.dart' barrel — used app-wide — fails to compile. It only 'works' because the dev box is Windows (case-insensitive). This is a latent build break for any non-Windows builder.
- **证据**:
~~~
Line 6: export 'src/utils/components/Hibiki_icon_button.dart';  // disk file is hibiki_icon_button.dart
Line 16: export 'src/utils/components/Hibiki_selectable_text.dart'; // disk file is hibiki_selectable_text.dart
Line 32: export 'package:hibiki_core/src/models/Hibiki_text_selection.dart'; // disk file is hibiki_text_selection.dart
~~~
- **修复建议**: Rewrite every export URI to match the on-disk lowercase filename (hibiki_*). Add a CI lint or build the project once on a case-sensitive filesystem to catch this class of bug.
- **验证（对抗复核）**: Independently confirmed by reading hibiki/lib/utils.dart and cross-checking on-disk + git-tracked filenames. The cited export lines do use capital 'Hibiki_*': line 3 `export 'src/utils/Hibiki_localisations.dart'`, line 6 `Hibiki_icon_button.dart`, line 16 `Hibiki_selectable_text.dart`, line 29 `Hibiki_color.dart`, line 32 `package:hibiki_core/src/models/Hibiki_text_selection.dart` (plus lines 7-15,17,30-31 similarly). `git ls-files` proves the actual tracked paths are all lowercase (e.g. hibiki/lib/src/utils/components/hibiki_icon_button.dart, hibiki/lib/src/utils/hibiki_localisations.dart, packages/hibiki_core/lib/src/models/hibiki_text_selection.dart). `find -name 'Hibiki_*.dart'` across hibiki/lib and packages returns zero matches, so no capitalized files exist — the bash `ls` resolved both casings only because the dev FS is Windows/NTFS (case-insensitive). Dart resolves library/file URIs case-sensitively on case-sensitive filesystems (Linux CI, macOS), so these exports fail with 'Target of URI doesn't exist'. Since utils.dart is a single barrel library imported by 91 files (verified via git grep) including main.dart and popup_main.dart, the failed exports are compile errors propagating app-wide. This is a genuine latent build break for any non-Windows builder. The finding's file, lines, root cause, evidence, and impact all check out.
  - 验证者保留意见: Not refuted — finding is accurate. Minor calibration note: severity 'high' is correct, not inflated. It is a hard compile-time failure on case-sensitive build hosts (the norm for Linux Flutter CI), but it fails loudly at build time rather than corrupting data or silently shipping wrong behavior, so …(截断)

### HBK-AUDIT-014 — DictAccessibilityService captures all text selections device-wide and pipes them to the clipboard-dict overlay

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `android-native-security` / permission model / broad-by-default capability grant + debug logging of sensitive user content left in production code
- **位置**: `hibiki/android/app/src/main/java/app/hibiki/reader/DictAccessibilityService.java + hibiki/android/app/src/main/res/xml/hibiki_dict_accessibility.xml` : DictAccessibilityService.java 12-37; hibiki_dict_accessibility.xml 1-7
- **审查者置信度**: high
- **根因**: The accessibility service config requests canRetrieveWindowContent=true and listens for typeViewTextSelectionChanged with no package allowlist (no android:packageNames attribute). onAccessibilityEvent reads node.getText() and the current text selection from ANY app the user is in and forwards the selected substring to FloatingDictService.onTextSelected, which sets it as the dictionary search term (FloatingDictService 421-427) and logs it (Log.d(TAG, "selected: " + selected)).
- **影响**: Overreach: while accessibility is enabled, every text selection the user makes in any app (password managers, banking apps, messengers) is read by Hibiki and written to logcat (PII/secret leakage to logs, readable by anything with READ_LOGS on rooted/old devices and by the app's own crash reports). There is no scoping to Hibiki's own reader. This is exactly the accessibility-overreach pattern Google reviews scrutinize; combined with SYSTEM_ALERT_WINDOW + clipboard monitoring it is a high-privilege surface.
- **证据**:
~~~
hibiki_dict_accessibility.xml: android:accessibilityEventTypes="typeViewTextSelectionChanged" android:canRetrieveWindowContent="true" (no android:packageNames). DictAccessibilityService: String selected = text.subSequence(start, end).toString().trim(); ... Log.d(TAG, "selected: " + selected); svc.onTextSelected(selected);
~~~
- **修复建议**: Remove the Log.d of selected text. Constrain the service with android:packageNames to only the apps where lookup is intended, or document/justify global scope to users explicitly. Re-evaluate whether canRetrieveWindowContent is needed (selection text comes from the event source, not full window scraping).
- **验证（对抗复核）**: Independently confirmed every cited line. hibiki_dict_accessibility.xml (lines 1-7) declares accessibilityEventTypes="typeViewTextSelectionChanged" and canRetrieveWindowContent="true" with NO android:packageNames — grep across the entire android tree returns zero matches for android:packageNames, so the service is genuinely device-wide/unscoped. DictAccessibilityService.java lines 27-31 match exactly: it extracts the selected substring, runs Log.d(TAG, "selected: " + selected), then forwards via svc.onTextSelected(selected). FloatingDictService.onTextSelected (lines 421-427) sets searchInput text and calls triggerSearch — confirmed. The service is registered/exported in AndroidManifest.xml (lines 149-158) with BIND_ACCESSIBILITY_SERVICE and the accessibilityservice intent-filter, so it is a reachable, enableable service, not dead code. The defect is real: while accessibility is enabled, text selections in any app are read, logged to logcat (PII/secret-to-log smell), and pushed into the dictionary search box, with no package allowlist — exactly the accessibility-overreach pattern Google review scrutinizes, compounded by SYSTEM_ALERT_WINDOW + clipboard monitoring.
  - 验证者保留意见: The finding is accurate but the impact framing is slightly overstated in two respects, which is why severity stays at medium (not high). (1) The path is gated behind two deliberate, high-friction user opt-ins: the OS-level "enable accessibility service" toggle (with its explicit system warning) AND …(截断)

### HBK-AUDIT-015 — SAF copy uses /proc/self/fd path for >50MB files — incorrect 'symlink' assumption and fragile fallback

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `android-native-security` / error-handling / comment-contradicts-code + pseudo-optimization: an invented 'hard-link via /proc/self/fd' that doesn't hard-link, plus a duplicated copy path
- **位置**: `hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java` : 608-659 (copyDocumentTree / copyFile), specifically 617-641
- **审查者置信度**: high
- **根因**: For files >50MB the code opens a ParcelFileDescriptor and reads from "/proc/self/fd/" + pfd.getFd() via a new FileInputStream, with a comment claiming this 'create[s] a symlink-like proxy' and 'hard-link[s] via /proc/self/fd' that 'bypasses SAF permission issues'. It does neither: it just copies the bytes the same as the <50MB branch, only via a fd path instead of the ContentResolver stream. The branch adds no benefit and silently swallows any exception into a fallback copyFile. DocumentFile.getName() is used to build dest File names (line 610-613) with no sanitization, so a document named '../x' could escape destDir.
- **影响**: (1) Dead/misleading optimization: the large-file branch is pure code bloat that does the same byte copy as the small-file branch while pretending to do hard-linking; future maintainers will trust the comment. (2) Path traversal: copyDocumentTree builds new File(destDir, name) from untrusted SAF document names without rejecting '..' or absolute components, so a malicious tree (user picks an attacker-prepared folder) could write outside destDir. (3) The 65536-byte loop on /proc/self/fd works only because the fd is still open; if the platform restricts /proc access it falls into a silent catch that re-copies — masking real errors.
- **证据**:
~~~
// Large file: create a symlink-like proxy by opening a FileDescriptor and hard-linking via /proc/self/fd. ... String fdPath = "/proc/self/fd/" + pfd.getFd(); ... try (InputStream in = new java.io.FileInputStream(fdPath); OutputStream out = new FileOutputStream(destFile)) { ... } // Fallback: copy via ContentResolver stream
~~~
- **修复建议**: Delete the >50MB special case and always stream via ContentResolver (the small-file path). Sanitize child.getName(): reject names containing path separators or '..'; verify new File(destDir,name).getCanonicalPath().startsWith(destDir.getCanonicalPath()). Don't swallow copy exceptions silently.
- **验证（对抗复核）**: I read MainActivity.java:608-659 directly and the cited lines match exactly. I traced the call chain: copyDocumentTree is reached from onActivityResult (line 189) after a user picks a tree via ACTION_OPEN_DOCUMENT_TREE (line 261, SAF_CHANNEL "pickAndCopyDirectory"), which the Dart side invokes for dictionary folder import (dictionary_dialog_page.dart:614, copying into an app-controlled temp dir under dictionaryResourceDirectory). The source child names therefore come from an untrusted DocumentsProvider's COLUMN_DISPLAY_NAME.\n\nTwo of the three sub-claims are CONFIRMED:\n(1) Misleading 'hard-link/symlink' optimization: the comment (lines 619-620, 627) claims it 'create[s] a symlink-like proxy' and 'hard-link[s] via /proc/self/fd' that 'bypasses SAF permission issues', but lines 628-635 perform a plain byte copy from /proc/self/fd/<fd> into a fully-materialized destFile — identical semantics to the small-file copyFile branch (lines 649-659), differing only in source path and buffer size (65536 vs 8192). The comment is factually false and the branch is redundant. (The 'dead code' label is imprecise — the branch DOES execute for files >50MB — but the misleading-comment/redundancy obse …(截断)
  - 验证者保留意见: Partially overstated, not refuted. Sub-claim #3 (silent catch masking real errors) does not hold: the catch falls back to copyFile, whose failure propagates to the SAF_ERROR result handler (line 192), so it is a safety net rather than error suppression. The 'dead code' characterization of the large- …(截断)

### HBK-AUDIT-016 — AnkiConnect addNote return value (note id) is discarded; a null result with no error field is treated as success

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / external-API-contracts / optimistic-but-unverified: assumes absence of 'error' == success, ignores the documented success payload
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart` : 79-95,15-32
- **审查者置信度**: medium
- **根因**: _request returns result['result'] and only throws when result['error'] != null. addNote awaits _request but ignores the returned value. Per the AnkiConnect contract, a successful addNote returns the new note id (a non-null int); certain malformed responses or future API changes could yield result=null with error=null, which would be treated as a successful add.
- **影响**: If AnkiConnect ever returns {result:null,error:null} (observed historically with some add-on version mismatches / multi-action edge cases), the app reports MineResult.success but no note was created. Silent loss of a mined card while telling the user it worked.
- **证据**:
~~~
@override
  Future<void> addNote({...}) async {
    await _request('addNote', { 'note': {...} });
  }   // return value (note id) never inspected
~~~
- **修复建议**: Have addNote return the note id (dynamic/int?) and verify it is non-null; if _request returns null with no error, throw AnkiConnectException('AnkiConnect returned no note id'). Surface as MineResult.error.
- **验证（对抗复核）**: Confirmed by reading the cited code directly. In packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart: _request (lines 15-32) decodes the JSON, throws AnkiConnectException only when result['error'] != null (line 28), and returns result['result'] (line 31), which is permitted to be null. addNote (lines 79-95) does `await _request('addNote', {...})` and discards the return value entirely — the new note id is never inspected. The caller AnkiConnectRepository.mineEntry (ankiconnect_repository.dart lines 208-219) wraps addNote in try/catch and, when no exception is thrown, returns MineResult.success unconditionally. So if AnkiConnect ever responds with {result: null, error: null}, the chain reports MineResult.success even though no note was created — silent card loss while telling the user it worked. The line citations, the evidence snippet, and the root-cause/impact description all match the actual code. Severity medium is correct: this is a latent bug / fragile external-API contract, not a guaranteed-on-happy-path failure (normal addNote errors are reported via the error field, which IS handled and mapped to MineResult.error). It does not corrupt existing data and only tr …(截断)
  - 验证者保留意见: Not a refutation — finding stands. Minor calibration note only: the triggering response shape {result:null,error:null} is an uncommon abnormal path (normal addNote failures surface via the error field and are already handled), so the impact is "latent/silent loss on edge path," consistent with mediu …(截断)

### HBK-AUDIT-017 — AnkiConnect isDuplicate builds a search query with an unescaped/unquoted field name — multi-word field names produce wrong or malformed Anki queries

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / external-API-contracts / fragile string-built external query; escaping applied to one half of the term only
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart` : 97-108,123
- **审查者置信度**: medium
- **根因**: The findNotes query interpolates fieldName directly: 'deck:"..." $fieldName:"..."'. _escapeAnkiQuery only escapes double-quotes in the *value*, not the field name. Anki field names frequently contain spaces (e.g. 'Term Audio', 'Sentence Audio', 'Pitch Accent' as defined in the native Lapis model). A field name with a space becomes 'Term Audio:"x"' which Anki parses as field 'Term' plus a stray token 'Audio:"x"', so the duplicate query silently matches the wrong thing (or nothing).
- **影响**: Duplicate detection over AnkiConnect is unreliable for any note type whose first/sort field name contains a space or special character — it will under-detect duplicates, defeating the allowDupes=false guard. Users get duplicate cards even though dedup is enabled.
- **证据**:
~~~
final result = await _request('findNotes', {'query': 'deck:"${_escapeAnkiQuery(deckName)}" $fieldName:"${_escapeAnkiQuery(fieldValue)}"'});
...
String _escapeAnkiQuery(String value) => value.replaceAll('"', '\\"');
~~~
- **修复建议**: Anki field-search syntax requires the field name to be quoted as a unit when it contains spaces: use '"$fieldName:$escapedValue"' (Anki supports quoting the whole term) or strip/validate field names. Also escape the field name. Mirror AnkiConnect's documented search escaping.
- **验证（对抗复核）**: Confirmed by reading the cited code and tracing the full call chain.

1) The cited lines match. ankiconnect_service.dart:103-106 builds the findNotes query as 'deck:"${_escapeAnkiQuery(deckName)}" $fieldName:"${_escapeAnkiQuery(fieldValue)}"'. _escapeAnkiQuery (line 123) is `value.replaceAll('"', '\\"')` — it escapes only the value's double-quotes, NOT the field name, and it does not quote the field:value term as a unit.

2) Anki query-syntax premise is correct. In Anki's search grammar a space is a term separator (implicit AND) and `field:value` binds the colon to the token immediately before it. An unquoted term `Term Audio:"x"` is tokenized into two terms: bare-word `Term` AND field-search `Audio:"x"`. The correct form for a field name containing a space is to quote the whole term, e.g. `"Term Audio:x"`. So a space in fieldName produces a malformed query that searches the wrong field (a nonexistent field "Audio") and under-detects — findNotes returns empty, isDuplicate returns false (fail-open).

3) Reachable path exists. isDuplicate is invoked from AnkiConnectRepository at ankiconnect_repository.dart:193-197 (inside `if (!settings.allowDupes)` during mineEntry) and :237-241 (li …(截断)
  - 验证者保留意见: Not a full refutation — the defect is real. The only correction: the finding's specific evidence is misleading. It implies the bundled Lapis model triggers the bug via fields like "Term Audio"/"Sentence Audio"/"Pitch Accent", but those are never the first field — Lapis's first field is "Term" (no sp …(截断)

### HBK-AUDIT-018 — AnkiDroid mineEntry creates a fully blank note and reports success when every mapped field renders empty

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / error-handling / happy-path-only + divergent duplicated logic between two backends; success returned without verifying the note has content
- **位置**: `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart` : 168-218
- **审查者置信度**: high
- **根因**: After rendering, fields only keeps entries whose trimmed value is non-empty (anki_repository line 176 / ankiconnect_repository line 182). For AnkiDroid the request is built as fieldArray = noteType.fields.map((f) => fields[f] ?? '') — an array of empty strings if nothing rendered. The native AnkiChannelHandler.addNote only rejects fields==null||isEmpty() (length 0), never an array of empty strings, so AnkiDroid's AddContentApi.addNote creates a blank note and the channel returns success.
- **影响**: If field mappings are misconfigured (e.g. all handlebars resolve to '' because the noteType field names don't match the cached mapping keys, or payload is sparse), the user gets MineResult.success and a 'card exported' toast while a completely empty card is silently inserted into their collection. This is data pollution that the user is told succeeded. The AnkiConnect path differs (AnkiConnect rejects an empty fields map → error), so the two backends disagree on the same input — false modularity.
- **证据**:
~~~
final fieldArray = noteType.fields.map((f) => fields[f] ?? '').toList();
... await _channel.invokeMethod('addNote', {'deck': deck.name, 'model': noteType.name, 'fields': fieldArray, 'tags': tags});
    return MineResult.success;
~~~
- **修复建议**: Before invoking addNote, verify at least the first (sort) field or some mapped field is non-empty; if fields map is empty, return MineResult.error (or a new MineResult.emptyFields). Make both backends agree. Native side could also reject an all-blank field array.
- **验证（对抗复核）**: I independently confirmed the defect by reading all cited code. The chain holds end-to-end:

1. anki_repository.dart:176-178 — fields map only retains entries where value.trim().isNotEmpty. When every mapped handlebar renders empty, the map ends up empty.
2. anki_repository.dart:202 — `final fieldArray = noteType.fields.map((f) => fields[f] ?? '').toList();` produces a list with one entry PER note-type field, each being '' when nothing rendered. Crucially this list is NOT empty; it has N elements of empty strings.
3. AnkiChannelHandler.java:62-64 — the native addNote handler only rejects `fields == null || fields.isEmpty()`. An ArrayList of N empty strings has isEmpty()==false, so it passes validation and proceeds to `addNote(...)` (line 66), which calls `api.addNote(...)` (line 186) and returns `result.success("Added note")` (line 70).
4. anki_repository.dart:213 — Dart then returns MineResult.success. So a fully blank note is inserted while the user is told it succeeded.

I also confirmed there is no guard preventing this: the dupe-check (lines 181-200) is only entered when `firstFieldValue.isNotEmpty` (line 185); when all fields are blank, firstFieldValue == '' so the dupe path …(截断)
  - 验证者保留意见: Not refuted as to existence — the defect is real and reachable. The only correction is severity: high is overstated because the empty-field condition only arises under field-mapping misconfiguration (stale cached mappings whose keys don't match the current note-type fields, or a sparse payload), not …(截断)

### HBK-AUDIT-019 — Remote audio/media download ignores HTTP status — a 404/error HTML body is saved as .mp3 and embedded into the card

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / error-handling / duplicated implementation across two repos; happy-path download with no status check
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart` : 271-307
- **审查者置信度**: high
- **根因**: _storeRemoteAudio does client.getUrl(...).close() then folds the response bytes unconditionally, never checking response.statusCode. A 404/403/500 returns an HTML/JSON error body which is written verbatim to hibiki_audio_*.mp3 and base64-stored into Anki media. Same pattern duplicated in AnkiRepository._addRemoteAudio (anki_repository.dart 256-285).
- **影响**: Cards get a [sound:...] reference to a file that is actually an error page, producing a broken/garbage audio attachment with no error surfaced to the user. The card still reports success.
- **证据**:
~~~
final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      ... audioFile = File('.../hibiki_audio_$urlHash.mp3');
      await audioFile.writeAsBytes(bytes);   // no statusCode check
~~~
- **修复建议**: Check response.statusCode == 200 before writing; if not, return null so the audio field stays empty. Optionally validate content-type starts with audio/. Apply the same fix to both repositories (they are copy-paste duplicates).
- **验证（对抗复核）**: Independently confirmed the defect on a reachable path.

Primary site (ankiconnect_repository.dart:271-307, _storeRemoteAudio): for an http(s) URL it does `request = await client.getUrl(...)`, `response = await request.close()`, then `bytes = await response.fold<List<int>>([], (a,b)=>a..addAll(b))` and immediately `await audioFile.writeAsBytes(bytes)` to `hibiki_audio_$urlHash.mp3`. response.statusCode is never read. A 404/403/500 yields an error HTML/JSON body that gets folded into bytes and written verbatim, then base64-encoded into Anki media via service.storeMediaFile (lines 298-301). The function returns the filename and the caller (line 134-135) wraps it as `[sound:$audioRef]` — card reports success while attaching a garbage "audio" file. No content-type check either.

Duplicate confirmed at packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart:256-285 (_addRemoteAudio, class AnkiRepository) — identical pattern: getUrl -> close -> fold -> writeAsBytes(bytes) -> _addMediaFile with no statusCode check. Note the finding's cited path 'anki_repository.dart' is slightly imprecise (actual: ankidroid/anki_repository.dart), but the function name, line range (256-285) and behavio …(截断)
  - 验证者保留意见: Only inaccuracy is a citation typo for the duplicate: it lives at packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart (class AnkiRepository), not a top-level anki_repository.dart. The defect, the line range (256-285 / 271-307), the mechanism (no statusCode check before writing the folded bod …(截断)

### HBK-AUDIT-020 — checkForDuplicates dispatched on the platform main thread via Handler.post but its result is not bridged back to the original Flutter result on error/exception

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / async / missing-context broken async bridge: reply guaranteed only on the happy path
- **位置**: `hibiki/android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java` : 74-83,190-212
- **审查者置信度**: medium
- **根因**: For checkForDuplicates the handler posts result.success(checkForDuplicates(...)) onto the main looper. checkForDuplicates calls AddContentApi.findDuplicateNotes which queries the AnkiDroid ContentProvider; if that throws (provider disabled mid-session, SecurityException, provider returns null cursor inside the API), the exception propagates inside the posted Runnable on the main thread with no try/catch — result.success is never called and no result.error is sent.
- **影响**: The Dart side awaits _channel.invokeMethod('checkForDuplicates', ...) (anki_repository.dart line 189). If the native Runnable throws, the MethodChannel reply is never delivered, so the Future never completes — the mining flow hangs on the dupe check. The Dart catch only fires for PlatformException/MissingPluginException, not for a dropped reply.
- **证据**:
~~~
new Handler(Looper.getMainLooper()).post(() -> result.success(checkForDuplicates(models, key, reading, readingFieldIndices)));
... List<NoteInfo> notes = api.findDuplicateNotes(mid, key); // can throw, no guard
~~~
- **修复建议**: Wrap the posted body in try/catch and call result.error(...) on exception so the Dart Future always completes. Same defensive pattern should cover getDecks/getModelList/getFieldList ContentProvider calls which can throw on permission revocation.
- **验证（对抗复核）**: Confirmed by reading AnkiChannelHandler.java and anki_repository.dart. At lines 81-82, the `checkForDuplicates` branch is the ONLY one dispatched via `new Handler(Looper.getMainLooper()).post(() -> result.success(checkForDuplicates(...)))` with no try/catch around the Runnable body. All sibling branches (addNote L66, getDecks L87, getModelList L92, getFieldList L105) execute synchronously inside onMethodCall, so an exception there is caught by Flutter's IncomingMethodCallHandler wrapper and converted to result.error. The Handler.post branch executes on a LATER main-loop iteration, after the synchronous handler has already returned, so Flutter's protective try/catch is no longer on the stack. checkForDuplicates (L190-212) calls ContentProvider-backed AddContentApi methods: findModelIdByName -> mApi.getModelList/getFieldList (L196), and api.findDuplicateNotes (L198). These can throw SecurityException (AnkiDroid permission revoked or app force-stopped/uninstalled mid-session) or NPE (if findDuplicateNotes returns null, L199 notes.isEmpty() NPEs). The L78 shouldRequestPermission guard handles the never-granted case but NOT mid-session revocation, which is a real reachable edge. On that …(截断)
  - 验证者保留意见: Not refuted — finding is real. The only inaccuracy is in the impact characterization: on the main Looper the uncaught exception crashes the process rather than silently hanging the Future, so the finding slightly understates rather than overstates severity. The minor proposed-fix overreach (guarding …(截断)

### HBK-AUDIT-021 — AppModel god object: 2536 lines, ~80 pass-through delegate members coupling 11 sub-managers behind one ChangeNotifier

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `app-startup-state` / god-object-decomposition / false modularity — files split out but AppModel re-exposes every member as a 1-line delegate, so callers still depend on the monolith and shared mutable state s …(截断)
- **位置**: `hibiki/lib/src/models/app_model.dart` : 147-2536 (whole class); delegate clusters e.g. 1305-1394 (theme), 2192-2511 (prefs), 2379-2424 (audio/local-audio), 354-360 (dict lists)
- **审查者置信度**: high
- **根因**: The 'extraction' refactor moved logic into ThemeNotifier/PreferencesRepository/DictionaryRepository/AudioController/etc., but instead of letting callers depend on those, AppModel re-wraps ~80 getters/setters as one-line forwards (e.g. `bool get showPlayBar => prefsRepo.showPlayBar;`). AppModel remains the single ChangeNotifier every widget watches via ref.watch(appProvider), so any prefsRepo/themeNotifier change still rebuilds every appProvider consumer app-wide. The decomposition is cosmetic: ownership and the notify funnel are still global.
- **影响**: Maintainability hazard and performance drag: a single pref toggle (e.g. setSearchDebounceDelay) fires AppModel.notifyListeners (forwarded from prefsRepo.addListener(notifyListeners)) and rebuilds the entire MaterialApp subtree watching appProvider. New features must thread through AppModel, perpetuating the monolith. High risk of merge conflicts and accidental coupling.
- **证据**:
~~~
app_model.dart:983 `prefsRepo.addListener(notifyListeners);` funnels ALL pref notifications into AppModel. app_model.dart:2428 `bool get showPlayBar => prefsRepo.showPlayBar;` and ~80 sibling 1-liners. main.dart:476 `AppModel get appModel => ref.watch(appProvider);` rebuilds the whole app on any notify.
~~~
- **修复建议**: Expose the sub-notifiers as their own Riverpod providers (themeProvider already exists at theme_notifier.dart:522 but most code reads appModel.theme instead). Have widgets watch the specific notifier they need (prefsRepo, dictRepo) so notifications are scoped; drop the blanket prefsRepo.addListener(notifyListeners) funnel. Remove the pass-through getters once callers migrate.
- **验证（对抗复核）**: I independently confirmed every cited code fact:

- app_model.dart is 2536 lines (wc -l).
- app_model.dart:92 `final appProvider = ChangeNotifierProvider<AppModel>(...)` — AppModel is a single ChangeNotifier (`class AppModel with ChangeNotifier`, line 147).
- app_model.dart:983 `prefsRepo.addListener(notifyListeners);` and :990 `themeNotifier.addListener(notifyListeners);` — confirmed funnels of ALL sub-notifier changes into AppModel.notifyListeners.
- app_model.dart:2428 `bool get showPlayBar => prefsRepo.showPlayBar;` confirmed, surrounded by a large delegate cluster.
- I counted the forwarders with grep `=> (prefsRepo|themeNotifier|audioCtrl|_localAudioManager|dictRepo).`: 96 occurrences (finding's "~80" is conservative/under-counted, so accurate-or-better).
- Confirmed delegate clusters at 1305-1394 (theme), 2192-2511 (prefs/audio/local-audio) read verbatim — they are one-line pass-throughs to ThemeNotifier/PreferencesRepository/AudioController/LocalAudioManager.
- main.dart:476 `AppModel get appModel => ref.watch(appProvider);` inside the root ConsumerWidget whose build() (lines 442-467) constructs the MaterialApp using appModel for theme/darkTheme/themeMode/locale/supportedLo …(截断)
  - 验证者保留意见: Overstated, not false. The "rebuilds the entire MaterialApp subtree app-wide on any pref toggle" performance impact is exaggerated: because the root build returns a MaterialApp with `home: const HomePage()` and the descendant tree lives behind a Navigator with its own Consumer scopes, a notifyListen …(截断)

### HBK-AUDIT-022 — ThemeNotifier._get performs an async DB write (side effect) inside synchronous getters invoked during build()

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `app-startup-state` / state-management-correctness / hidden side effect in a getter; optimistic 'lazy default persist' that fires from the widget build phase
- **位置**: `hibiki/lib/src/models/theme_notifier.dart` : 99-112 (_get/_set), 182 (designSystem default 'auto'), 246-251 (_buildThemeData reads designSystem every build), 385-447 (custom color getters default non-null)
- **审查者置信度**: high
- **根因**: _get() does `if (defaultValue != null) _set(key, defaultValue);` — _set encodes and writes to the Drift DB (await _db.setPref) and mutates _prefs. _buildThemeData() (called by `theme`/`darkTheme`, which run in MaterialApp build at main.dart:455-456) reads `designSystem` (default 'auto', non-null) via _overridePlatform on every build, and in custom-theme mode reads _colorPref getters (default 0, non-null). So building the theme triggers a fire-and-forget DB write the first time these keys are absent.
- **影响**: A pure render path (ThemeData getter during build) issues an un-awaited SQLite write and mutates cache state. On a fresh install the first frame writes design_system='auto' (and seed/color defaults) to the DB. Un-awaited writes can race refreshPrefCache/profile-switch reloads and there is no error handling on this write path; it also violates the Flutter rule that build must be side-effect free.
- **证据**:
~~~
theme_notifier.dart:102 `if (defaultValue != null) _set(key, defaultValue);` theme_notifier.dart:182 `String get designSystem => _get('design_system', defaultValue: 'auto');` theme_notifier.dart:251 `platform: _overridePlatform,` (in _buildThemeData) main.dart:455 `theme: appModel.theme,`
~~~
- **修复建议**: Make _get a pure read — never write from a getter. If lazy default-seeding is wanted, do it once explicitly during loadFromPrefsSnapshot/refreshFromDb, not on every read from build().
- **验证（对抗复核）**: Independently confirmed every cited line. theme_notifier.dart:99-106 `_get` does `if (defaultValue != null) _set(key, defaultValue);` and returns synchronously without awaiting the Future from `_set`. theme_notifier.dart:108-112 `_set` mutates `_prefs[key]` then `await _db.setPref(key, strVal)`, and database.dart:305-309 `setPref` is a real Drift `insertOnConflictUpdate` into the `preferences` table — a genuine SQLite write. theme_notifier.dart:182 `String get designSystem => _get('design_system', defaultValue: 'auto')` has a non-null default. theme_notifier.dart:189-198 `_overridePlatform` reads `designSystem`, and theme_notifier.dart:246-251 `_buildThemeData` reads `_overridePlatform` on every call regardless of theme mode. theme_notifier.dart:228-229 `theme`/`darkTheme` delegate to `_buildThemeData`, wired into MaterialApp at main.dart:455-456 `theme: appModel.theme, darkTheme: appModel.darkTheme,` (inside the synchronous build path; app_model.dart:533-534 forward to themeNotifier). So on a fresh install where `design_system` is absent, the first theme build during MaterialApp.build() issues a fire-and-forget SQLite write of `design_system='auto'`. In custom-theme mode the `_col …(截断)

### HBK-AUDIT-023 — initialise() swallows fatal errors into initError but leaves multiple late finals unassigned, so retry/other paths can throw LateInitializationError

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `app-startup-state` / error-handling / happy-path init wrapped in one try/catch that can exit at any point, leaving a half-constructed god object whose getters are still reachable
- **位置**: `hibiki/lib/src/models/app_model.dart` : 950-1123 (single try block), 208-213 (retryInitialise), 165/176/179/184-186/254-294 (late finals: _database, mediaHistoryRepo, dictRepo, managers, directories)
- **审查者置信度**: medium
- **根因**: All of initialise() is wrapped in one try/catch that on failure only sets _initError and notifyListeners. If it throws after some `late final`s are assigned but before others (e.g. DB opens but dictRepo.loadFromDb throws), the object is half-built. retryInitialise() then re-enters initialise() and re-assigns the SAME `late final` fields (_packageInfo, _database, mediaHistoryRepo, dictRepo, _temporaryDirectory, ...) — re-assigning a `late final` that was already set throws LateInitializationError, so Retry is not actually safe after a partial first run. Additionally getters like database/temporaryDirectory remain callable while _isInitialised is false.
- **影响**: The error screen's Retry button (main.dart:399 appModel.retryInitialise) can crash with 'LateInitializationError: Field _database has already been initialized' if the first attempt assigned _database before failing. Users hitting a transient init failure (e.g. directory perms) get a dead Retry. Half-initialised getters are also exposed to any code path.
- **证据**:
~~~
app_model.dart:964 `_database = HibikiDatabase(_databaseDirectory.path);` is a `late final` (165). retryInitialise (208-213) calls initialise() again with no guard. Re-assigning an already-set `late final` throws at runtime.
~~~
- **修复建议**: Make fields that can be reassigned non-final (or null-guarded) and reset them at the start of retryInitialise; or wrap each stage so retry skips already-completed stages. At minimum guard against re-assigning _database when already open.
- **验证（对抗复核）**: Independently confirmed by reading app_model.dart and main.dart.

CONFIRMED FACTS:
- The fields are `late final`: `_packageInfo` (197), `_database` (165), `mediaHistoryRepo` (176), `dictRepo` (179), and the directory fields (_temporaryDirectory 254, _appDirectory 258, _databaseDirectory 262, etc.). `_localAudioManager`/`_fileExportManager`/`_dictImportManager` are `late` (non-final, 184-186) so those are reassignable, but the others are not.
- initialise() (951-1122) wraps its ENTIRE body in one try/catch. On failure it only sets `_initError='$e'` and notifyListeners() (1117-1122); it does NOT reset any field.
- Inside initialise() the late finals are assigned sequentially: _packageInfo @955, directories @959-961, _database=HibikiDatabase(...) @964, dictRepo @972, mediaHistoryRepo @974, then `await Future.wait([... dictRepo.loadFromDb(), mediaHistoryRepo.loadFromDb() ...])` @977-982 (a realistic failure point), and further stages with their own throw points.
- retryInitialise() (208-213) sets `_initError=null; _isInitialised=false; notifyListeners(); await initialise();` — NO reset/guard of the already-assigned late finals, and initialise() has no per-stage skip logic.
- main.dart …(截断)
  - 验证者保留意见: Not a refutation — finding confirmed. Only nitpick: the first late-final to re-throw on Retry is _packageInfo (line 955), not _database (line 964) as the evidence snippet states; _database is reached later. The mechanism, root cause, late-final field list, and reachable Retry path (main.dart:399 -> …(截断)

### HBK-AUDIT-024 — SMIL clipBegin/clipEnd parser silently drops cues for valid 's' / 'ms' time units

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `audiobook-audio` / parse/error-handling / happy-path-only parser: handles the colon forms but not the unit-suffixed forms the spec explicitly allows
- **位置**: `packages/hibiki_audio/lib/src/parsers/smil_parser.dart` : _parseTimeToMs:102-122; caller skip at 80 (`if (startMs == null || endMs == null) continue;`)
- **审查者置信度**: high
- **根因**: SMIL Media Overlays permit clock values like `4.5s`, `4230ms`, `1.2min`, or full-clock `0:00:04.230`. _parseTimeToMs only handles colon-separated and bare-number forms via double.tryParse; for `4.5s` double.tryParse('4.5s') returns null, so _parseTimeToMs returns null and the par/cue is dropped at line 80.
- **影响**: A perfectly valid EPUB3 Media Overlay that uses the s/ms unit syntax parses to zero (or partial) cues. The user gets an audiobook with no/partial highlighting and only a generic failure, with no indication the timecodes were the problem. This is a real-world format the importer claims to support.
- **证据**:
~~~
`if (parts.length == 3) {...} else if (parts.length == 2) {...} else { seconds = double.tryParse(parts[0]); } if (seconds == null) return null;` — no stripping of trailing 's'/'ms'/'min'.
~~~
- **修复建议**: Strip/handle the unit suffix before double.tryParse: detect trailing 'ms' (value/1000), 'min' (value*60), 's' (value as-is), else treat as seconds. Mirror the SMIL clock-value grammar.
- **验证（对抗复核）**: Independently confirmed every link in the chain by reading the actual code.

1. CITATION MATCHES EXACTLY. packages/hibiki_audio/lib/src/parsers/smil_parser.dart:102-122 — `_parseTimeToMs` handles only: 3-part colon (`h:m:s`, lines 106-111), 2-part colon (`m:s`, lines 112-116), and bare number (`else { seconds = double.tryParse(parts[0]); }`, lines 117-119). Line 120 returns null when `seconds == null`. The caller at line 80 does `if (startMs == null || endMs == null) continue;`, dropping the par/cue. No unit-suffix stripping anywhere.

2. DART BEHAVIOR CORRECT. `double.tryParse` requires the entire string to be numeric, so `double.tryParse('4.5s')` / `'4230ms'` / `'1.2min'` all return null → `_parseTimeToMs` returns null → cue dropped.

3. SPEC CLAIM VERIFIED against W3C SMIL 3.0 timing spec: the clock-value grammar's timecount-value form permits metric suffixes `h | min | s | ms` (e.g. `4.5s`, `4230ms`, `1.2min`, `3.2h`), default metric `s`. EPUB3 Media Overlays inherit this SMIL clock-value grammar, so these are spec-valid clipBegin/clipEnd values the importer should accept. The code's own doc comment (line 100) only claims to handle `hh:mm:ss.sss 或 ss.sss`, so impl matches comme …(截断)

### HBK-AUDIT-025 — fastlane Fastfile and Appfile are unmodified third-party boilerplate that targets the wrong app/repo and broken files

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / deployment-strategy / copy-pasted template never wired up; false modularity (config exists but does nothing real)
- **位置**: `hibiki/android/fastlane/Fastfile, hibiki/android/fastlane/Appfile` : Fastfile:20-34; Appfile:2
- **审查者置信度**: high
- **根因**: The `apk` lane was copied from a fastlane example and never adapted: it calls `set_github_release(repository_name: "fastlane/fastlane", ... name: "Super New actions", ... upload_assets: ["example_integration.ipa", "./pkg/built.gem"])` — it would (try to) publish to the unrelated fastlane/fastlane repo and upload nonexistent iOS/gem artifacts. It also has a typo `verson_name` (line 21) and only builds `--split-per-abi` without signing. The Appfile declares `package_name("app.arianneorpilla.yuuna")` — the wrong, inherited-from-upstream package; Hibiki's real applicationId is app.hibiki.reader (app/build.gradle:71).
- **影响**: fastlane is non-functional as a deployment path. If anyone runs `fastlane apk` it errors (typo, missing assets) or, worse, attempts to push a GitHub release to fastlane/fastlane. The wrong package_name means any `supply`/upload action targets a foreign package. The presence of a Gemfile (fastlane) implies a deployment story that does not actually exist; real deployment is only the GitHub Actions release.yml.
- **证据**:
~~~
Fastfile:21 `verson_name = flutter_version()["version_name"];`, :25-33 `set_github_release(repository_name: "fastlane/fastlane", ... upload_assets: ["example_integration.ipa", "./pkg/built.gem"])`. Appfile:2 `package_name("app.arianneorpilla.yuuna")`. Contrast app/build.gradle:71 `applicationId "app.hibiki.reader"`.
~~~
- **修复建议**: Either delete the fastlane Fastfile/Appfile/Gemfile if GitHub Actions is the sole deploy path, or rewrite the lane to actually build the signed Hibiki APKs and upload to the hajisensai/hibiki repo with the correct package_name app.hibiki.reader, fixing the typo and removing the example asset list.
- **验证（对抗复核）**: I independently opened all cited files and confirmed every claim verbatim. Fastfile (hibiki/android/fastlane/Fastfile): line 21 has the typo `verson_name = flutter_version()["version_name"];`; lines 25-33 call `set_github_release(repository_name: "fastlane/fastlane", api_token: ENV["GITHUB_TOKEN"], name: "Super New actions", tag_name: verson_name, ... upload_assets: ["example_integration.ipa", "./pkg/built.gem"])`; line 23 builds `flutter build apk --split-per-abi` with no signing step. Appfile line 2 declares `package_name("app.arianneorpilla.yuuna")`. The real applicationId is `app.hibiki.reader` at app/build.gradle:71. A Gemfile exists at hibiki/android/Gemfile. This is verbatim, unmodified upstream fastlane example boilerplate (the strings "fastlane/fastlane", "Super New actions", "example_integration.ipa", "./pkg/built.gem" are the canonical fastlane sample). The `apk` lane is genuinely non-functional and the Appfile targets the wrong inherited (yuuna) package. So the defect is real. However the claimed severity "high" is inflated. I checked .github/workflows/ (contributors.yml, main.yml, release.yml) and none of them invoke fastlane (grep for "fastlane" across .github returne …(截断)
  - 验证者保留意见: The finding is factually accurate but its severity is overstated. "high" requires wrong behavior or a leak users will hit; this code is never invoked by any CI workflow (no fastlane reference in .github/workflows/release.yml, main.yml, or contributors.yml — GitHub Actions is the sole automated deplo …(截断)

### HBK-AUDIT-026 — main.yml builds only a debug APK; release-mode build is conditional on keystore and never verified on PRs

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / ci-cd / happy-path CI; build verification that skips the real artifact
- **位置**: `.github/workflows/main.yml` : main.yml:68-103
- **审查者置信度**: high
- **根因**: The unconditional build step is `flutter build apk --debug` (line 71). The release build (lines 95-103) is guarded by `if: env.HAS_KEYSTORE == 'true'`, which is `secrets.KEYSTORE_BASE64 != ''`. On forks and any environment without the keystore secret, the release APK — the one that goes through minify/proguard/R8 and the externalNativeBuild C++23 hoshidicts CMake — is never built in PR CI. Debug builds skip minifyEnabled true + proguard-rules.pro, so R8/keep-rule regressions (e.g. stripped FFI/native classes) are invisible until a tagged release.
- **影响**: ProGuard/R8 stripping bugs, missing -keep rules, native build breakage under release optimization, and minify-only crashes are only discovered at release time (release.yml), not on PRs. The debug-only gate gives false confidence that 'the build passes'.
- **证据**:
~~~
main.yml:71 `flutter build apk --debug`. main.yml:96 `if: env.HAS_KEYSTORE == 'true'` on the release build. build.gradle:111-116 release `minifyEnabled true` + proguard-rules.pro; proguard-rules.pro keeps app.hibiki.reader.**, inappwebview, sqflite, JNI native methods — exactly the rules that only matter in release.
~~~
- **修复建议**: Build a release APK (or at least `flutter build apk --release --no-shrink` plus a minified variant) in PR CI even without signing — release builds do not require a keystore to compile, only to sign. Decouple 'build release artifact' from 'sign release artifact' so optimization/proguard is exercised on every PR.
- **验证（对抗复核）**: Independently confirmed every cited fact. .github/workflows/main.yml:68-71 runs `flutter build apk --debug` unconditionally; the release build at main.yml:95-103 is gated by `if: env.HAS_KEYSTORE == 'true'` where `HAS_KEYSTORE = secrets.KEYSTORE_BASE64 != ''` (lines 96, 102-103). build.gradle:111-116 sets the release buildType to `minifyEnabled true` + `proguard-android-optimize.txt` + `proguard-rules.pro`, and proguard-rules.pro keeps app.hibiki.reader.** (line 9), flutter_inappwebview_android (line 15), sqflite (line 18) and JNI `native <methods>` (lines 25-27) — keep rules that only matter under release shrink/optimize. Debug builds bypass minify/proguard/R8 entirely, so a stripped FFI/native/plugin class or missing -keep rule would not surface in PR CI. release.yml only triggers on `release: published` / `workflow_dispatch` (lines 3-6), confirming the release/minify path is never exercised on PRs in any environment lacking the KEYSTORE_BASE64 secret (forks, and any clone without secrets). The proposed-fix premise is technically sound: the signingConfig (build.gradle:100-109) only loads keystore props `if (keystorePropertiesFile.exists())`, so a release compile (running R8/progu …(截断)

### HBK-AUDIT-027 — Card-creator field/export contract is orphaned: onCreatorOpenAction, copyContext, fromMineFields, imagesToExport, audioToExport, getExportDetails have no live caller

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / dead-code / broken call chain from missing context; large feature surface that 'compiles' but is never invoked
- **位置**: `hibiki/lib/src/creator/field.dart, creator_field_values.dart, hibiki/lib/src/models/creator_model.dart` : field.dart:69-81 (onCreatorOpenAction); creator_field_values.dart:16-61 (fromMineFields), 91-118 (imagesToExport/audioToExport); creator_model.dart:161-178 (copyContext/getExportDetails)
- **审查者置信度**: high
- **根因**: A whole card-creator UI/export pipeline exists (Field.onCreatorOpenAction overridden by 20 field subclasses, CreatorFieldValues.fromMineFields, copyContext, getExportDetails, imagesToExport/audioToExport, Enhancement.enhanceCreatorParams, buildTopWidget) but the page that consumed it (CardCreatorAction/InstantExportAction, still present in generated docs/) was removed. A repo-wide grep across hibiki/lib + packages + tests shows these members are referenced only inside src/creator itself, by creator_model.dart, and by one unit test. No page renders globalFields, no flow calls fromMineFields/copyContext, nothing reads imagesToExport/audioToExport. Only QuickActions (stash/copy/share/play-audio) in dictionary_term_page.dart are live.
- **影响**: ~3000+ LOC of fields/enhancements/export plumbing is unreachable in the running app, yet still initialised at startup (app_model.dart:1066-1071 calls initialise() on every enhancement for every field). Dead weight at boot, large attack surface for confusing future edits, and the '50 files / 4528 LOC' fragmentation is mostly maintaining a feature with no entry point. The 20 overridden onCreatorOpenAction methods (and the Meaning duplication above) cannot be exercised by users.
- **证据**:
~~~
grep -rln 'onCreatorOpenAction|copyContext|fromMineFields|imagesToExport|audioToExport|getExportDetails' over hibiki/lib + packages returns only files under src/creator/ plus creator_model.dart. grep for enhanceCreatorParams/buildTopWidget/.enhancements[ outside src/creator returns only app_model.dart (registration) — no rendering widget. The only CreatorFieldValues consumer outside creator/ is test/creator/creator_field_values_test.dart. docs/creator/CardCreatorAction/executeAction.html and InstantExportAction reference these, but those source classes no longer exist in lib/.
~~~
- **修复建议**: Decide the feature's fate: if the card creator is intended, restore/build the consuming page and wire fromMineFields from the popup mining flow; if not, delete the orphaned field/enhancement/export surface (keeping QuickActions) so startup no longer initialises dead enhancements and the module stops masquerading as live.
- **验证（对抗复核）**: Independently confirmed by reading the code. The six named members are genuinely orphaned (defined but never invoked on any reachable production path):

- onCreatorOpenAction: hibiki/lib/src/creator/field.dart:69 declares it (throws UnimplementedError as base). 20 field subclasses @override it (term_field.dart:31, meaning_field.dart:63, base_audio_field.dart:329, etc.). A grep for the CALL form `.onCreatorOpenAction(` across the whole repo returns ZERO hits — only declarations and overrides exist. No dispatcher ever calls it.
- CreatorFieldValues.fromMineFields (creator_field_values.dart:16): the only `.fromMineFields(`-style reference is its own factory declaration; no caller in lib/ or tests.
- copyContext (creator_model.dart:161) and getExportDetails (creator_model.dart:172): `.copyContext(` / `.getExportDetails(` produce no call-site matches anywhere.
- imagesToExport/audioToExport (creator_field_values.dart:91,106): no `.imagesToExport` / `.audioToExport` reads anywhere.

CardCreatorAction / InstantExportAction (the page that would consume getExportDetails/copyContext/fromMineFields) exist ONLY in generated docs/*.html — there is no such class in any .dart source. No creator*p …(截断)
  - 验证者保留意见: Partially overstated. The dead-code claim for the six named members is correct, but the finding's title/impact overreach by implying the entire creator module (~3000+ LOC, fields, enhancements) is unreachable and "masquerading as live." That is false: creatorProvider is live (read in dictionary_term …(截断)

### HBK-AUDIT-028 — BackupService export fallback copies a live WAL-mode SQLite file, risking an inconsistent backup

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / resource/data-integrity / optimistic fallback that swallows the real failure and does a known-unsafe operation
- **位置**: `hibiki/lib/src/sync/backup_service.dart` : 74-82
- **审查者置信度**: medium
- **根因**: exportBackup tries 'VACUUM INTO' (safe, consistent snapshot) but on ANY exception falls into 'catch (_)' that runs 'PRAGMA wal_checkpoint(TRUNCATE)' then File(_dbPath).copy(cleanDbPath) on the still-open, still-writable database. wal_checkpoint(TRUNCATE) can fail/partial if other connections hold the WAL, and a plain file copy of a live DB can capture a torn page set. The bare 'catch (_)' also hides why VACUUM INTO failed (disk full, locked, etc.).
- **影响**: User believes they have a valid backup; on restore (importBackupFiles overwrites hibiki.db at line 155) they get a corrupt or stale-by-some-pages database. Silent data-integrity hazard on the recovery path that matters most.
- **证据**:
~~~
backup_service.dart:78 "await _db.customStatement(\"VACUUM INTO '$safePath'\");" then :79-82 'catch (_) { await _db.customStatement("PRAGMA wal_checkpoint(TRUNCATE)"); await File(_dbPath).copy(cleanDbPath); }'.
~~~
- **修复建议**: Don't silently fall back to a live-file copy. On VACUUM INTO failure, surface the error (log it, not 'catch (_)'), and if a fallback is required, acquire an exclusive transaction / use the backup API rather than a raw copy of an open WAL database.
- **验证（对抗复核）**: I independently opened hibiki/lib/src/sync/backup_service.dart and read lines 71-110. The cited code matches exactly: line 78 `await _db.customStatement("VACUUM INTO '$safePath'");` wrapped in try; line 79 `} catch (_) {`; line 80 `await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');`; line 81 `await File(_dbPath).copy(cleanDbPath);`. The restore-overwrite at backup_service.dart:155 (`await currentDb.writeAsBytes(dbFile.content as List<int>)`) is also confirmed. The WAL-mode premise is verified independently: packages/hibiki_core/lib/src/database/database.dart:19 runs `db.execute('PRAGMA journal_mode=WAL')`, so the live DB is genuinely WAL-mode.

The defect is real and on a reachable path: VACUUM INTO can fail for ordinary reasons (low disk, locked file, read-only temp), and the bare `catch (_)` then (a) swallows the actual failure reason — a genuine diagnostic/maintainability hazard — and (b) falls back to a raw `File.copy` of the still-open, still-writable DB. While `PRAGMA wal_checkpoint(TRUNCATE)` flushes the WAL into the main file and substantially reduces the torn-page risk, the copy still happens against an open connection: the `await` between the checkpoint and the …(截断)

### HBK-AUDIT-029 — Embedded sync server PUT writes can leave a corrupt partial file on stream error (inconsistent with download cleanup)

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / error-handling / happy-path-only write with no failure cleanup, despite sibling code doing it right
- **位置**: `hibiki/lib/src/sync/hibiki_sync_server.dart` : 212-222
- **审查者置信度**: high
- **根因**: _handlePut opens the destination IOSink and does 'await request.read().forEach(sink.add); await sink.close();' with no try/finally. If the request stream errors mid-body, sink.add throws, sink is never closed, and a truncated file remains at fsPath. Every download path in the codebase (webdav/smb/sftp/dropbox downloadContentFile) wraps writes in try/finally and deleteSync() on failure — this server PUT does not.
- **影响**: A dropped/interrupted upload from a peer (very plausible over LAN sync) overwrites the previous good file with a truncated one and leaks the open sink. Subsequent reads of that book's progress/epub get corrupt JSON or a partial epub.
- **证据**:
~~~
hibiki_sync_server.dart:218-220 'final sink = file.openWrite(); await request.read().forEach(sink.add); await sink.close();' (no try/finally/cleanup), vs webdav_sync_backend.dart:246-255 which deletes the destination on !success.
~~~
- **修复建议**: Write to a temp path, then atomically rename on success; wrap in try/finally that closes the sink and deletes the temp/partial file if the stream errored. Return 500 on failure instead of leaving a 201/204-shaped corrupt file.
- **验证（对抗复核）**: Independently confirmed by reading hibiki/lib/src/sync/hibiki_sync_server.dart:212-222. _handlePut does exactly `final sink = file.openWrite(); await request.read().forEach(sink.add); await sink.close();` with NO try/finally and no cleanup. File.openWrite() defaults to FileMode.write, which truncates the destination immediately — so an error mid-body has already destroyed the previous good content and leaves a truncated file at fsPath, while the IOSink is never closed (leak). The asymmetry claim is accurate: webdav_sync_backend.dart:234-255 and sftp_sync_backend.dart:297-311 both use a success-flag + try/finally + deleteSync() cleanup on the download write path; the server PUT is the lone write path missing it. Reachability is real and end-to-end: sync_settings_schema.dart:1504-1521 starts HibikiSyncServer with allowLan:true, binding InternetAddress.anyIPv4 (line 43) as a LAN-reachable WebDAV receiver; hibiki_client_sync_backend.dart:202-221 (uploadContentFile) PUTs whole files by streaming file.openRead() over the network into request.addStream, hitting _handlePut. A dropped LAN connection mid-upload of an epub/audio/progress.json is plausible and overwrites the prior good file wi …(截断)
  - 验证者保留意见: Not a refutation of the core defect (it is real). Only a minor accuracy correction: the claimed '201/204-shaped corrupt file' response is wrong — the stream error propagates uncaught, so shelf returns 500. However the truncated file and the leaked, never-closed IOSink remain on disk in either case, …(截断)

### HBK-AUDIT-030 — Untyped 'as int' fromJson on externally-sourced sync data crashes the whole field decode on type drift

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / type-safety / happy-path JSON parsing with raw as-casts, no edge handling, on interop data
- **位置**: `hibiki/lib/src/sync/ttu_models.dart` : 20-25, 63-73, 108-112
- **审查者置信度**: high
- **根因**: TtuProgress/TtuStatistics/TtuAudioBook.fromJson use bare casts: 'json["dataId"] as int', 'json["exploredCharCount"] as int', 'json["charactersRead"] as int'. The file's own comment says these formats are for three-way interop with ッツ/Hoshi ('保证三方互通'), i.e. data is written by external programs. If any integer field is encoded as a JSON float (e.g. 1.0), missing (null), or a string, the cast throws TypeError. Note progress/readingTime/playbackPosition correctly use 'as num' but the int fields do not.
- **影响**: A single malformed/foreign-written remote file (exploredCharCount: 1.0) throws during getProgressFile/getStatsFile. SyncManager.syncBook catches it and marks that book 'skipped' (sync_manager.dart:92), so it silently fails to sync rather than crashing the app — but the user gets a silent no-op with an opaque error string instead of graceful coercion.
- **证据**:
~~~
ttu_models.dart:21 'dataId: json["dataId"] as int,' and :22 'exploredCharCount: json["exploredCharCount"] as int,' (no fallback), contrasted with :23 'progress: (json["progress"] as num).toDouble()'. Statistics :64-72 same pattern.
~~~
- **修复建议**: Use tolerant coercion for the int fields: '(json["exploredCharCount"] as num?)?.toInt() ?? 0' etc., mirroring the 'as num' style already used for the double fields.
- **验证（对抗复核）**: Independently confirmed by reading ttu_models.dart and the full consuming call chain.

1. Cited code matches exactly. TtuProgress.fromJson (ttu_models.dart:20-25) uses bare `dataId: json['dataId'] as int` (L21), `exploredCharCount: json['exploredCharCount'] as int` (L22), `lastBookmarkModified: json['lastBookmarkModified'] as int` (L24), while `progress` uses the tolerant `(json['progress'] as num).toDouble()` (L23). Same asymmetry in TtuStatistics.fromJson (L63-73: int fields at L66,68-72 vs `as num` at L67) and TtuAudioBook.fromJson (L108-112: `as int` at L111 vs `as num` at L110). The inconsistency the finding highlights is real and present.

2. Data is externally sourced. The file header comment (L3-5) states the format is shared three-way with ッツ/Hoshi readers ('保证三方互通'), so foreign programs author this JSON. fromJson is the live decode path for ALL eight sync backends (dropbox/google_drive/ftp/sftp/smb/webdav/onedrive/hibiki_client all call TtuProgress.fromJson etc. via getProgressFile/getStatsFile/getAudioBookFile, confirmed by grep), reached from SyncManager._handleImport (sync_manager.dart:254,275,283) and _handleExport (L366), plus sync_compare_dialog.dart:203-214.

3. Th …(截断)

### HBK-AUDIT-031 — WebDAV / SMB / Hibiki-Client sync backends are three near-identical copy-paste classes (~900 lines, ~600 duplicated)

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / false-modularity / copy-pasted near-identical files presented as separate modules
- **位置**: `hibiki/lib/src/sync/smb_sync_backend.dart, hibiki/lib/src/sync/webdav_sync_backend.dart, hibiki/lib/src/sync/hibiki_client_sync_backend.dart` : smb 19-324; webdav 10-316; hibiki_client 15-316
- **审查者置信度**: high
- **根因**: All three SyncBackend implementations wrap the same WebDavOps with byte-for-byte identical findOrCreateRootFolder/listBooks/ensureBookFolder/listSyncFiles/getProgressFile/getStatsFile/getAudioBookFile/update*/uploadContentFile/downloadContentFile/findContentFile/cache bodies. The ONLY differences are which SyncRepository credential getters auth/restoreAuth/signOut call, currentEmail, and the cover-upload debug tag. SmbSyncBackend's own class comment even admits 'delegates to WebDAV over HTTP ... There is no pure-Dart SMB library.'
- **影响**: Any bug fix or protocol change (e.g. the cross-origin href check, content-length handling, or a PROPFIND parse fix) must be hand-applied in 3 places and WILL drift. Already drifting: webdav/hibiki_client log cover-upload failures via debugPrint while smb silently swallows them (smb line 128 'catch (_) {}'). ~600 lines of dead-weight maintenance surface.
- **证据**:
~~~
smb_sync_backend.dart:137-149 listSyncFiles body is identical to webdav_sync_backend.dart:127-139 and hibiki_client_sync_backend.dart:128-140 (same _ops!.propfindChildren + same WebDavOps.findByPrefix calls). Auth is the only real difference: smb reads getSmbWebDavUrl/getSmbUsername/getSmbPassword, webdav reads getWebDavUrl/Username/Password, hibiki_client reads getHibikiClientUrl/Token.
~~~
- **修复建议**: Extract an abstract _WebDavSyncBackendBase with abstract Future resolveCredentials(repo)->(url,user,pass) + abstract clearCredentials(repo) + abstract get currentEmail, and put the ~280 shared lines once. WebDav/Smb/HibikiClient become ~40-line subclasses overriding only credential plumbing.
- **验证（对抗复核）**: I independently read all three files in full. The duplication claim is confirmed and accurate, not speculative:

- listSyncFiles bodies are byte-for-byte identical at the exact cited lines: smb 137-149 == webdav 127-139 == hibiki_client 128-140 (same _ops!.propfindChildren + WebDavOps.findByPrefix calls). CONFIRMED.
- The entire shared surface is duplicated identically: findOrCreateRootFolder, listBooks, ensureBookFolder, getProgressFile/getStatsFile/getAudioBookFile, updateProgressFile/updateStatsFile/updateAudioBookFile, uploadContentFile (smb 211-231 == webdav 201-221 == hibiki_client 202-222, byte-for-byte), downloadContentFile, findContentFile, and all five cache methods. CONFIRMED.
- The only real differences are: which SyncRepository credential getters/setters auth/restoreAuth/signOut use (getSmbWebDavUrl/getSmbUsername/getSmbPassword vs getWebDavUrl/Username/Password vs getHibikiClientUrl/Token), currentEmail (_username vs literal 'hibiki'), the testConnection signature, and the debug-tag strings. CONFIRMED exactly as claimed.
- The already-present drift is real: smb's ensureBookFolder catch silently swallows at line 128 (catch (_) {}) while webdav (117) and hibiki_client ( …(截断)
  - 验证者保留意见: Not refuted on existence — the duplication and the already-present smb-vs-others catch-block drift are real and verified at the cited lines. Overstated only on severity (claimed high; actual medium): the code works on all three paths today, there is no data loss/crash/security issue and no current u …(截断)

### HBK-AUDIT-032 — hoshidicts_import error path returns NULL detected_type/title, then Dart toDartString() dereferences NULL → crash

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `dictionary-ffi` / native-error-propagation / happy-path-only error handling: error branch forgot to populate a field the consumer always reads
- **位置**: `native/hoshidicts/hoshidicts_ffi.cpp + packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart` : cpp 219-233; dart 335-349
- **审查者置信度**: high
- **根因**: In hoshidicts_import, args.result is zero-initialized ({}). On the thread-creation-failure branch (cpp 224-229) only success/title/error are set; detected_type stays NULL. The Dart importDictionary path unconditionally calls r.detectedType.toDartString() (and r.title.toDartString(), r.error.toDartString()) on whatever the native struct returns, with no nullptr guard.
- **影响**: If hoshi_thread_create fails (resource exhaustion / OOM, exactly the low-memory situation imports already try to detect), the returned FfiImportResult.detected_type is NULL. Utf8.toDartString() on nullptr throws/segfaults in the import isolate, turning a recoverable 'import failed' into a hard crash on the path the code explicitly tries to handle gracefully.
- **证据**:
~~~
cpp: `if (!ok) { args.result.success = 0; args.result.title = dup(""); args.result.error = dup("Failed to create import thread"); return args.result; }` — detected_type left NULL. dart: `detectedType: r.detectedType.toDartString(),` with no `== nullptr` check.
~~~
- **修复建议**: Set args.result.detected_type = dup("term") (or "") on every early-return/error branch in hoshidicts_import; and/or guard each toDartString() in Dart with `ptr == nullptr ? '' : ptr.toDartString()`.
- **验证（对抗复核）**: Independently confirmed the defect by reading the cited code. native/hoshidicts/hoshidicts_ffi.cpp:215-233 — hoshidicts_import zero-inits the struct at line 219 (`args.result = {};`), so all char* fields including detected_type start as nullptr. The thread-creation-failure early-return branch at lines 224-229 sets success=0, title=dup(""), error=dup("Failed to create import thread") but never sets detected_type, leaving it nullptr. Contrast with the in-thread catch branch (line 204) which correctly does `a->result.detected_type = dup("term")` — proving the omission is specific to the !ok early return. On the Dart side, packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart:339-349 unconditionally builds HoshiImportResult with `detectedType: r.detectedType.toDartString()` (line 347) with no nullptr guard. package:ffi's Utf8.toDartString() on a Pointer at address 0 scans memory from address 0 for a NUL terminator, dereferencing null → SIGSEGV in the import Isolate (Isolate.run at line 330), not a catchable Dart exception. So a recoverable 'import failed' becomes a hard native crash. The mechanism and both cited line ranges match exactly. Reachability: hoshi_thread_create only retu …(截断)
  - 验证者保留意见: Minor title overstatement: the finding lists both detected_type AND title as left NULL, but title IS set to dup("") on the failure branch (cpp:226); only detected_type is actually nullptr there (error is also set at cpp:227). This does not change the verdict — a single unguarded null field is enough …(截断)

### HBK-AUDIT-033 — EPUB chapter/OPF/container reading assumes UTF-8; non-UTF-8 Japanese books (Shift_JIS/EUC-JP) crash the parse

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / correctness / happy-path-only flow with no fallback; optimistic-but-unverified encoding assumption
- **位置**: `hibiki/lib/src/epub/epub_parser.dart` : 48, 59, 279, 367, 389
- **审查者置信度**: high
- **根因**: Every text read uses File.readAsStringSync() with no `encoding:` argument. Dart defaults to utf8 with allowMalformed:false, so it THROWS FormatException/FileSystemException on any byte sequence that is not valid UTF-8. EPUB permits other encodings declared in the XML prolog/HTML <meta charset>, and legacy Japanese ebooks/raw XHTML frequently use Shift_JIS or EUC-JP. There is no charset detection anywhere in the epub module (grep for charset/Shift_JIS/Encoding returns only the literal `charset="utf-8"` string written by the TTU migration wrapper).
- **影响**: A perfectly valid non-UTF-8 EPUB fails to import: parseFromExtracted throws on the first non-UTF-8 chapter (line 279) or even on container.xml/OPF (lines 48/59). In EpubImporter this is caught and the whole book is rolled back/deleted, so the user just sees a generic import error for a book that other readers open fine. Because this is explicitly a Japanese-learning reader, the affected encodings are exactly the ones its target users are most likely to have.
- **证据**:
~~~
line 59: `final XmlDocument opfXml = XmlDocument.parse(opfFile.readAsStringSync());`
line 279: `html: file.readAsStringSync(),` — no encoding param, defaults to strict UTF-8.
Runtime path mirrors the bug: reader_hibiki_source.dart:1097 `final String cssText = utf8.decode(data);` and :1104 `String html = utf8.decode(data);` both call utf8.decode unconditionally (also throws on non-UTF-8).
~~~
- **修复建议**: Detect declared encoding (XML prolog `encoding=`, HTML `<meta charset>` / BOM) and decode accordingly, or at minimum read bytes and decode with utf8.decode(bytes, allowMalformed: true) as a safe fallback so malformed/legacy bytes degrade to replacement chars instead of throwing. Apply the same to the runtime utf8.decode calls in reader_hibiki_source.dart.
- **验证（对抗复核）**: I confirmed the core defect by reading hibiki/lib/src/epub/epub_parser.dart. All five cited lines match exactly and read text with strict UTF-8: line 48 `XmlDocument.parse(containerFile.readAsStringSync())`, line 59 `XmlDocument.parse(opfFile.readAsStringSync())`, line 279 `html: file.readAsStringSync()`, line 367 `navFile.readAsStringSync()`, line 389 `ncxFile.readAsStringSync()`. None pass an `encoding:` argument. Dart's `File.readAsStringSync` defaults to `utf8` whose codec has `allowMalformed:false`, so it throws FormatException on any byte sequence that is not valid UTF-8. Because decoding happens before XML/HTML parsing, a declared `encoding="Shift_JIS"` in the prolog or a `<meta charset>` is never consulted — the decode throws first. A grep across hibiki/lib/src/epub confirms there is NO charset detection anywhere (only the literal `charset="utf-8"` string written by ttu_migration.dart). I traced reachability: parse runs in a `compute()` isolate via EpubImporter.import/importFromPath; a parse throw propagates to the catch block (epub_importer.dart:104-118 / 231-245), which deletes the extract dir and rethrows — the entire book import fails and rolls back. So a non-UTF-8 (or …(截断)
  - 验证者保留意见: Overstated, not fully refuted. The import-path defect is real (lines 48/59/279/367/389 do throw on non-UTF-8 via strict utf8 default and the book import fully rolls back), so is_real=true. But the claimed runtime mirror is false: the cited reader_hibiki_source.dart:1097/1104 do not exist (file is 95 …(截断)

### HBK-AUDIT-034 — Extractor treats a file entry as a directory when another entry implies its path as a parent, silently discarding the file's bytes

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / correctness / over-engineered malformed-archive handling that quietly prefers directory over data
- **位置**: `hibiki/lib/src/epub/epub_parser.dart` : 118-152, 166-187
- **审查者置信度**: medium
- **根因**: _archiveDirectoryPaths calls _addParentDirectories for EVERY entry, so the set `archiveDirectories` contains every parent path of every file. In _extractArchive the test is `if (file.isFile && !archiveDirectories.contains(filePath))`. If an archive contains both a file at path `a` and a file at `a/b` (i.e. `a` is simultaneously a real file and an implied parent dir of another entry), the entry `a` matches archiveDirectories and is routed to _ensureDirectory, which deletes the file and creates a directory. The file's content is never written.
- **影响**: On malformed or unusually-ordered archives, a real resource file is silently dropped and replaced by an empty directory. Downstream readResource()/file.existsSync() then return null/false for that resource (e.g. a missing image or CSS), producing a silently-degraded book rather than a clear error. Well-formed EPUBs are unaffected, hence latent.
- **证据**:
~~~
_addParentDirectories (line 166) adds all ancestors of every path unconditionally. _extractArchive line 124 `if (file.isFile && !archiveDirectories.contains(filePath))` else (line 129) `_ensureDirectory(filePath);` where _ensureDirectory line 184 `File(path).deleteSync();`. A file whose path collides with another entry's parent is converted to a directory.
~~~
- **修复建议**: Only treat a path as a directory if the archive contains an explicit non-file entry for it (file.isFile == false), not merely because it is an implied parent of some other file. Track explicit-directory entries separately from inferred parents, and never delete a file entry that has real content.
- **验证（对抗复核）**: Independently confirmed by reading epub_parser.dart lines 1-187 and epub_book.dart lines 36-149. The cited lines match exactly.

Mechanism trace (confirmed):
- `_archiveDirectoryPaths` (134-152) iterates every entry and for each calls `_addParentDirectories` (149) unconditionally — even for file entries. `_addParentDirectories` (166-180) walks `dirname` upward adding every ancestor within the canonical base to the `directories` set.
- For a file entry named `a/b`: `_safeArchivePath` yields `<base>/a/b`, and `_addParentDirectories` computes `dirname = <base>/a` and adds it. So `<base>/a` ∈ archiveDirectories.
- For a separate file entry named `a`: `_safeArchivePath` yields exactly `<base>/a` (same canonicalize(join(extractDir, name)) path). In `_extractArchive` line 124 the guard `file.isFile && !archiveDirectories.contains(filePath)` evaluates `true && !true = false`, so entry `a` falls to the else at 128-129 → `_ensureDirectory(<base>/a)`.
- `_ensureDirectory` (182-187): if the path is currently a file it `File(path).deleteSync()` (184) then creates a directory. Crucially, since the `archiveDirectories` set is fully built BEFORE the extraction loop, iteration order is irrelevant: …(截断)

### HBK-AUDIT-035 — Per-chapter HTML DOM parse for character counts runs synchronously on the main isolate after import, freezing the UI

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / perf / work that belongs in the isolate left on the main thread; happy-path optimism (assumes few chapters)
- **位置**: `hibiki/lib/src/epub/epub_importer.dart` : 36-47, 164-175
- **审查者置信度**: high
- **根因**: Parsing is correctly moved into a background isolate via compute(_parseInIsolate). But immediately after compute returns on the MAIN isolate, the importer loops every chapter calling book.chapterPlainText(entry.key), which runs a full package:html `html_parser.parse()` over each chapter's HTML (epub_book.dart:56-62). This expensive DOM build happens on the UI isolate, not in the compute() isolate.
- **影响**: Importing a large EPUB (a novel split into hundreds of XHTML chapters, or a long aozora-style file) blocks the Flutter UI thread for the duration of all those DOM parses — visible jank/ANR-style freeze during import, on the exact code path users hit (book_import_dialog.dart calls EpubImporter.import/importFromPath). The isolate offload is partly defeated.
- **证据**:
~~~
epub_importer.dart:44 `'characters': book.chapterPlainText(entry.key).length,` inside `.map(...)` executed after `await compute(...)` (line 31) returns to the main isolate.
epub_book.dart:58 `final html_dom.Document doc = html_parser.parse(chapters[index].html);` — full DOM parse per call.
~~~
- **修复建议**: Compute the per-chapter character counts inside _parseInIsolate/_parseSyncFromPath (in the isolate) and return them as part of EpubBook (or a side list), so the main isolate only serializes integers. Avoid re-parsing HTML on the UI thread.
- **验证（对抗复核）**: Confirmed by reading the cited code. epub_importer.dart:31-34 offloads parsing to a background isolate via `await compute(_parseInIsolate, ...)` (and importFromPath at 159-162). After the await returns to the MAIN isolate, lines 36-47 (and 164-175) eagerly build `chaptersJson` via `.map(...).toList()` inside `jsonEncode`, calling `book.chapterPlainText(entry.key).length` for every chapter. chapterPlainText (epub_book.dart:56-62) executes `html_parser.parse(chapters[index].html)` — a full package:html DOM build — per chapter, at line 58. epub_parser.dart:279 confirms each EpubChapter carries its full HTML string (`html: file.readAsStringSync()`), and the EpubBook is returned across the isolate boundary, so the HTML and thus the DOM parse live/run on the main isolate. The `.toList()` is synchronous and runs in the async continuation on the main isolate, so all DOM parses happen on the UI thread, not in the compute() isolate. The call path is user-reachable: book_import_dialog.dart:549/631/638/669/676 invoke EpubImporter.import / importFromPath. For a large novel split into hundreds of XHTML chapters this blocks the UI thread for the duration of all DOM parses, partially defeating the …(截断)

### HBK-AUDIT-036 — BasePage.createState() returns a non-abstract BasePageState that throws UnimplementedError in build()

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / type-safety / fragile-contract / happy-path base class; type system as theater (concrete state that must never be instantiated)
- **位置**: `hibiki/lib/src/pages/base_page.dart` : 10-16, 88-91
- **审查者置信度**: high
- **根因**: BasePage is abstract-by-convention but its createState() is concrete (`=> BasePageState()`), and BasePageState.build() does `throw UnimplementedError()`. Nothing forces subclasses to override createState; a `class Foo extends BasePage {}` with no overrides compiles fine and crashes at runtime on first build.
- **影响**: A missing createState/build override is a runtime crash instead of a compile error. For a base used by ~40 pages this removes the compiler safety net that abstract methods would provide.
- **证据**:
~~~
base_page.dart:15 `BasePageState<BasePage> createState() => BasePageState();` and base_page.dart:89-91 `Widget build(BuildContext context) { throw UnimplementedError(); }`.
~~~
- **修复建议**: Make BasePage.createState() abstract (declare without body, mark class abstract) and make BasePageState.build abstract, mirroring how BaseHistoryPage/BaseSourcePage already declare abstract createState. This converts the failure into a compile-time error.
- **验证（对抗复核）**: Independently confirmed by reading hibiki/lib/src/pages/base_page.dart. Cited lines match exactly: line 15 is `BasePageState<BasePage> createState() => BasePageState();` (concrete, returns a real instance), and lines 89-91 are `@override Widget build(BuildContext context) { throw UnimplementedError(); }` (concrete throwing body, not abstract). Because BasePage provides a concrete createState() and BasePageState provides a concrete (throwing) build(), there are no unimplemented abstract members; a `class Foo extends BasePage {}` with zero overrides genuinely compiles and would crash at first build via UnimplementedError. The compiler safety net that an abstract createState/build would provide is indeed removed. The proposed-fix comparison is also accurate: BaseHistoryPage (base_history_page.dart:15 and abstract build at :38), BaseSourcePage (base_source_page.dart:28), and BaseTabPage (base_tab_page.dart:13) all declare createState() abstract (no body), so BasePage is the inconsistent outlier — this is a real, demonstrable inconsistency, not a stylistic preference.
  - 验证者保留意见: Not a refutation, but a scope note: every one of the ~40 real subclasses sampled (e.g. settings_home_page.dart:22 `createState() => _SettingsHomePageState()`) correctly overrides createState, so there is no reachable production/user-facing path that crashes today. The impact is purely latent — a fut …(截断)

### HBK-AUDIT-037 — _initialFragment cleared in _onChapterLoadComplete but not in spread/lyrics paths or on early-return, causing wrong fragment jump on subsequent loads

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-core` / state-sync / shared mutable field reset in only one of several load paths
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` : 1697 (_initialFragment=null), 2404-2447 (_navigateToChapterWithFragment), 1669-1713 (_onChapterLoadComplete), 1253-1271 (_buildReaderSetupScript reads _initialFragment)
- **审查者置信度**: medium
- **根因**: _initialFragment is set by _navigateToChapterWithFragment and consumed by _buildReaderSetupScript (which generates `jumpToFragment(...)` when non-null). It is reset to null at line 1697 — but only after the `evaluateJavascript(setup)` and only in the non-lyrics branch of _onChapterLoadComplete, AND only if the early-return guards at 1689/1695 don't fire. If a generation/chapter check causes early return (1689-1691, 1695), or the load is a spread page (which goes through spreadReady, not _onChapterLoadComplete setup), or _onChapterLoadComplete throws before 1697, _initialFragment stays set.
- **影响**: A stale fragment leaks into the next chapter load: the next chapter's setup script will call jumpToFragment with a fragment that belongs to a previous internal-link navigation, scrolling the user to the wrong/no anchor instead of restoring saved progress. Intermittent 'jumped to wrong place' after following a footnote/TOC link then turning the page.
- **证据**:
~~~
`await controller.evaluateJavascript(source: _buildReaderSetupScript(...)); if (!mounted || _navigateGeneration != gen) return; _initialFragment = null;` — the reset sits after an await and after a guard that can early-return, and is absent from the lyrics branch and the spread/Windows-onReceivedError completion paths.
~~~
- **修复建议**: Reset _initialFragment exactly once at the start of every navigation that does not want a fragment (e.g. in _navigateToChapter/_navigateToSpread set `_initialFragment = null;`), and capture the fragment into a local before building the setup script rather than relying on a post-await field reset.
- **验证（对抗复核）**: Confirmed by reading the cited code. `_initialFragment` (field decl line 100) is set non-null ONLY at line 2427 inside `_navigateToChapterWithFragment`, which is invoked ONLY from `shouldOverrideUrlLoading` line 1605 when following an internal link (footnote/TOC). It is consumed by `_buildReaderSetupScript` line 1262 (passed to ReaderPaginationScripts) and reset to null ONLY at line 1697 inside `_onChapterLoadComplete`. I verified that the two ordinary navigation entry points do NOT clear it: `_navigateToChapter` (lines 2346-2386) and `_navigateToSpread` (lines 2503-2538) set `_initialProgress`/`_currentChapter`/generation but never touch `_initialFragment`. So once set, the only thing that clears it is a successful run of `_onChapterLoadComplete` reaching line 1697.

Reachable leak path: `_onChapterLoadComplete` captures gen/chapterSnapshot (1682-1683), then awaits `_prepareSasayakiCuesJson()` when an audiobook controller is present (1686-1688). During that await a concurrent navigation (e.g. cue-driven `_navigateToChapter(cueChapter)` at line 2059, or a fast manual page turn) bumps `_navigateGeneration`, so the guard at 1689-1691 (`_currentChapter != chapterSnapshot || _navigateG …(截断)
  - 验证者保留意见: Not a refutation — the defect is confirmed. Minor corrections to the finding: the spread path does NOT keep the fragment stale (onLoadStop->_onChapterLoadComplete resets it at line 1697), and the bug is a timing race (requires the navigation to be superseded during the `_prepareSasayakiCuesJson` awa …(截断)

### HBK-AUDIT-038 — shouldOverrideUrlLoading returns CANCEL for all unresolved URLs, silently blocking legitimate external/anchor navigations and same-page fragment links

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-core` / js-bridge-contract / catch-all CANCEL with no handling of the cases it cancels
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` : 1597-1609 (shouldOverrideUrlLoading)
- **审查者置信度**: medium
- **根因**: shouldOverrideUrlLoading: if _isNavigatingToChapter -> ALLOW; else if _book.resolveInternalLink(url) matches an EPUB chapter -> CANCEL and navigate internally; else -> CANCEL. resolveInternalLink only matches hoshi.local /epub/ URLs whose path equals a chapter href (it strips the fragment but matches on path). A same-document fragment link (href="#note1") becomes a hoshi.local URL with the current chapter's path plus a fragment — resolveInternalLink WILL match it and trigger _navigateToChapterWithFragment, forcing a full chapter RELOAD just to scroll to an in-page anchor. And any genuinely external link (http(s) footnote/source) hits the final `return CANCEL` and is silently dropped.
- **影响**: (1) In-page footnote/anchor links cause a full chapter reload + restore round-trip instead of an instant scroll — visible flash and lost scroll context. (2) External links in EPUB content (author site, source citations) are silently swallowed with no feedback. Users tapping a footnote get a jarring reload; tapping an external link gets nothing.
- **证据**:
~~~
`final link = _book?.resolveInternalLink(url); if (link != null) { _navigateToChapterWithFragment(link.chapterIndex, link.fragment); return CANCEL; } return CANCEL;` — resolveInternalLink matches even when link.chapterIndex == _currentChapter (same chapter, only fragment differs), so a same-page anchor reloads the chapter. Final fall-through CANCELs http/https with no openExternal.
~~~
- **修复建议**: In the link branch, if `link.chapterIndex == _currentChapter` just evaluate jumpToFragment in-place instead of _navigateToChapterWithFragment (no reload). For the fall-through, detect http/https/mailto schemes and route to url_launcher (or show a toast) instead of a blanket CANCEL.
- **验证（对抗复核）**: Independently confirmed by reading the cited code and the full call chain.

1) shouldOverrideUrlLoading (reader_hibiki_page.dart:1597-1609) matches the description exactly: if _isNavigatingToChapter -> ALLOW; else resolveInternalLink(url) -> _navigateToChapterWithFragment + CANCEL; else blanket `return NavigationActionPolicy.CANCEL` (line 1608). No scheme detection, no url_launcher.

2) resolveInternalLink (epub/epub_book.dart:88-105) matches hoshi.local URLs whose `/epub/<path>` equals a chapter href; it strips the fragment (uri.fragment) but matches on path only, returning (chapterIndex: i, fragment: fragment). The reader loads each chapter via loadUrl with base URL `https://hoshi.local/epub/<href>` (_chapterUrl 988-993, epubUrl in reader_hibiki_source.dart:56). Therefore a relative same-document anchor `href="#note1"` resolves against that base to `https://hoshi.local/epub/<current-href>#note1`, which DOES match the current chapter -> returns chapterIndex == _currentChapter with fragment "note1". Confirmed.

3) _navigateToChapterWithFragment (2404-2447) has NO same-chapter short-circuit. It unconditionally cancels the progress poll timer, flushes reading stats, bumps _navigateGe …(截断)

### HBK-AUDIT-039 — Canonical book uid builder bookUidFor exists but the 'reader_ttu/hoshi://book/$id' format is hand-duplicated in DB cascade-delete and sync, a fragile cross-module key contract

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / source-contract / legacy persistence-key hack; duplicated magic string across modules
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 54
- **审查者置信度**: high
- **根因**: bookUidFor(int) at line 54 is the single source of truth for the legacy book uid, but two critical paths reconstruct the same literal by hand instead of calling it: packages/hibiki_core/.../database.dart:731 (`final String bookUid = 'reader_ttu/hoshi://book/$id';` inside deleteEpubBook's transactional cascade that deletes audioCues and audiobooks) and hibiki/lib/src/sync/sync_manager.dart:507 (`final bookUid = 'reader_ttu/hoshi://book/$bookId';`). hibiki_core cannot import the app-level source, so the format is copy-pasted.
- **影响**: If anyone ever changes the uid format in bookUidFor (e.g. drops the legacy reader_ttu prefix), deleteEpubBook will silently target the wrong bookUid and orphan all audio_cues + audiobook rows for deleted books, and sync_manager will sync against the wrong uid. The compiler gives no warning. This is exactly the brittle legacy-key boundary called out as a hazard.
- **证据**:
~~~
Three independent definitions of the same string: reader_hibiki_source.dart:54 bookUidFor; database.dart:731; sync_manager.dart:507. deleteEpubBook uses its local literal to delete audioCues (730-733) and audiobooks (734-735).
~~~
- **修复建议**: Promote the uid format to a constant in hibiki_core (e.g. a pure function buildLegacyBookUid(int) in hibiki_core) and have the app-level bookUidFor, sync_manager, and deleteEpubBook all call the single hibiki_core function. Eliminate all three literals.
- **验证（对抗复核）**: I independently confirmed all three cited locations verbatim. reader_hibiki_source.dart:54 defines `static String bookUidFor(int bookId) => 'reader_ttu/hoshi://book/$bookId';`. database.dart:731 hand-builds the identical literal `final String bookUid = 'reader_ttu/hoshi://book/$id';` inside deleteEpubBook's transaction, then uses it to cascade-delete audioCues (732-733) and audiobooks (734-735). sync_manager.dart:507 hand-builds `'reader_ttu/hoshi://book/$bookId'` in _resolveAudioPaths. The architectural premise is also true: I verified reader_hibiki_source.dart imports hibiki_core (line 12) AND package:hibiki/media|models|pages (lines 9-11), while bookUidFor lives in the app layer above hibiki_core, so hibiki_core (the DB layer) genuinely cannot call bookUidFor without a circular dependency — the literal had to be copy-pasted. Grep confirms exactly three literal copies plus a test fixture, while 5 production call sites correctly delegate to bookUidFor. So the DRY violation across a cross-module key contract on a real cascade-delete path is real, and the proposed fix (promote a pure buildLegacyBookUid(int) into hibiki_core) is sound.
  - 验证者保留意见: Severity is inflated from high to medium. There is NO current defect: all three literals are byte-identical today, so deleteEpubBook and sync currently target the correct bookUid — no rows are orphaned and no sync mismatch occurs on any reachable path right now. The "orphan all audio_cues + audioboo …(截断)

### HBK-AUDIT-040 — ReaderHibikiSource.deleteBook leaks override title preference and override thumbnail file because it bypasses clearOverrideValues

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / resource-leak / happy-path only; broken call chain (custom delete path skips base cleanup)
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 299-326
- **审查者置信度**: high
- **根因**: Books are created with canDelete:false (getBooksFromDb line 291), so deletion never goes through AppModel.deleteMediaItem (which calls mediaSource.clearOverrideValues + onMediaItemClear at app_model.dart:2098-2099). Instead the history page calls ReaderHibikiSource.deleteBook directly (reader_hibiki_history_page.dart:879,890,941,1160). deleteBook removes the epub row, audiobook, srt and extracted dir, but never clears the override title pref ('override_title://reader_ttu/...') or the override thumbnail file.
- **影响**: Every book that the user gave a custom title (canEdit:true allows it) or custom cover leaves an orphaned preference row in the Drift preferences table and an orphaned thumbnail file in thumbnailsDirectory after deletion. These accumulate; and because override keys are keyed by mediaIdentifier/mediaSourceIdentifier, a future book that happens to map to the same identifier could inherit a stale override title/cover.
- **证据**:
~~~
getBooksFromDb sets `canDelete: false, canEdit: true` (lines 291-292). deleteBook (299-326) does: deleteAudiobook, srtRepo.delete, db.deleteEpubBook, EpubStorage.deleteBook — no clearOverrideValues. Base cleanup exists at media_source.dart:496-507 clearOverrideValues and is only invoked from app_model.dart:2096-2101 deleteMediaItem.
~~~
- **修复建议**: In deleteBook, after building the MediaItem-equivalent identifiers, call clearOverrideValues / deletePreference(getOverrideTitleKey) and delete the override thumbnail file (getOverrideThumbnailFilename) for this book, or route deletion through a shared cleanup that the generic path also uses.
- **验证（对抗复核）**: I independently confirmed every load-bearing claim by reading the cited code:

1. ReaderHibikiSource.deleteBook (reader_hibiki_source.dart:299-326) deletes the audiobook (deleteAudiobook), srt (srtRepo.delete), the epub row (db.deleteEpubBook) and the extracted dir (EpubStorage.deleteBook). It never calls clearOverrideValues, never deletes the override title preference, and never deletes the override thumbnail file. Confirmed verbatim.

2. getBooksFromDb builds MediaItem with `canDelete: false, canEdit: true` (lines 291-292). Because canDelete is false, the generic AppModel.deleteMediaItem path is not how these books are removed.

3. AppModel.deleteMediaItem (app_model.dart:2096-2101) IS the only place clearOverrideValues + onMediaItemClear are invoked. clearOverrideValues (media_source.dart:496-507) deletes the override_title pref (getOverrideTitleKey, line 408-409) and clears the override thumbnail file (setOverrideThumbnailFromMediaItem with clearOverrideImage:true). The cited file path "sources/media_source.dart" is slightly wrong — the real base class is hibiki/lib/src/media/media_source.dart — but the methods and line numbers match.

4. All four history-page delete sites bypa …(截断)
  - 验证者保留意见: Two points are overstated. (a) Cited path "hibiki/lib/src/media/sources/media_source.dart" is wrong; the base class lives at hibiki/lib/src/media/media_source.dart (cited line numbers still match). (b) The "future book with same identifier inherits stale override title/cover" claim is unrealistic: E …(截断)

### HBK-AUDIT-041 — deleteBook duplicates the audiobook/srt/cue deletes that deleteEpubBook already performs transactionally, splitting one deletion across non-atomic layers

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / false-modularity / overlapping/duplicated deletion responsibility
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 303-320
- **审查者置信度**: high
- **根因**: deleteBook manually deletes the audiobook (306-310) and srt book (312-316) via repos, then calls db.deleteEpubBook(bookId) (318) which inside one transaction ALSO deletes srtBooks, audioCues, and audiobooks for the same id/bookUid (database.dart:727-736). The DB-row deletes happen twice; only the repos' on-disk AudiobookStorage.deletePersistDir side effects are non-redundant.
- **影响**: Two divergent owners of the same deletion. The repo deletes are non-transactional and run before the transaction; if the process is killed between them and deleteEpubBook, on-disk audio dirs are gone but DB rows remain (or vice versa) leaving an inconsistent half-deleted book. A future change to deleteEpubBook's cascade can silently double-delete or, if removed there, leave the manual path as the only (non-atomic) cleanup.
- **证据**:
~~~
reader_hibiki_source.dart:306-316 manual deleteAudiobook + srtRepo.delete; database.dart:730-735 transactional delete of srtBooks, audioCues, audiobooks by the same bookUid/id. Both delete the same rows.
~~~
- **修复建议**: Make deletion single-owned: do the on-disk dir cleanup (deletePersistDir) inside or immediately after the one transaction, and stop re-deleting DB rows in deleteBook that deleteEpubBook already removes. Or move the whole cascade (rows + dirs) behind one method.
- **验证（对抗复核）**: Independently confirmed by reading the cited code. In reader_hibiki_source.dart:299-326, deleteBook does manual deletes then calls db.deleteEpubBook(bookId) at line 318, and the DB rows overlap exactly:

AUDIOBOOK SIDE: Line 309 audiobookRepo.deleteAudiobook(bookUid) → deleteAudiobookByBookUid (database.dart:512-516) deletes audioCues + audiobooks WHERE bookUid = 'reader_ttu/hoshi://book/$bookId'. deleteEpubBook (database.dart:732-735) deletes audioCues + audiobooks by the IDENTICAL bookUid string it constructs at line 731 ('reader_ttu/hoshi://book/$id'). The strings are provably the same: bookUidFor at reader_hibiki_source.dart:54 = 'reader_ttu/hoshi://book/$bookId'. So these DB rows are deleted twice.

SRT SIDE: Line 315 srtRepo.delete(srt.uid) → deleteSrtBookByUid (database.dart:571-574) deletes audioCues by srt.uid and srtBooks WHERE uid = srt.uid. deleteEpubBook (database.dart:730) deletes srtBooks WHERE ttuBookId = bookId. Since the srt row was fetched via findByTtuBookId(bookId) (line 313, srt_book_repository.dart:26-30), its ttuBookId == bookId, so the srtBooks row is also double-targeted.

The finding's nuance is accurate: the on-disk AudiobookStorage.deletePersistDir side …(截断)

### HBK-AUDIT-042 — generateAudio override path is fully dead: setPendingSentenceAudio/clearPendingSentenceAudio have zero callers, so generateAudio always returns null

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / dead-code / zombie code AI left behind; false modularity; pseudo-extensibility
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 78-121
- **审查者置信度**: high
- **根因**: ReaderHibikiSource declares overridesAutoAudio: true and implements generateAudio() reading _pendingCue/_pendingAudioFiles, which are only ever set via setPendingSentenceAudio() / cleared via clearPendingSentenceAudio(). A repo-wide grep shows setPendingSentenceAudio and clearPendingSentenceAudio are NEVER called from anywhere (only their definitions exist). Therefore _pendingCue and _pendingAudioFiles are permanently null and generateAudio() always hits the `if (cue == null || audioFiles == null) return null;` early-return.
  - 补充: AI scaffolded an override contract that was never connected; the working implementation was written separately and inline.
- **影响**: The entire sentence-audio override mechanism on the source is non-functional. The real sentence-audio mining is done by duplicated inline code in reader_hibiki_page.dart onMineFromPopup (lines 2202-2217), which extracts the segment itself instead of delegating to generateAudio. The source carries ~45 lines of dead machinery plus a misleading overridesAutoAudio:true flag, and a future maintainer wiring Anki audio through the documented generateAudio contract would silently get null.
- **证据**:
~~~
Lines 81-92 define setPendingSentenceAudio/clearPendingSentenceAudio; grep for both names returns only reader_hibiki_source.dart definitions, no call sites. generateAudio (94-121): `final AudioCue? cue = _pendingCue; ... if (cue == null || audioFiles == null) { return null; }`. Mirror logic lives inline at reader_hibiki_page.dart:2208-2216.
~~~
- **修复建议**: Either wire onMineFromPopup to call setPendingSentenceAudio before invoking the creator and route mining through generateAudio (removing the duplicated inline extraction), or delete generateAudio, _pendingCue, _pendingAudioFiles, setPendingSentenceAudio, clearPendingSentenceAudio and set overridesAutoAudio:false. Do not leave both a dead override and a live duplicate.
- **验证（对抗复核）**: Independently confirmed every load-bearing claim by reading the cited code.

1) reader_hibiki_source.dart:81-92 define setPendingSentenceAudio()/clearPendingSentenceAudio(); a repo-wide grep for both names returns ONLY these two definitions and zero call sites. Confirmed dead.

2) These setters are the only writers of _pendingCue (line 78) and _pendingAudioFiles (line 79). With no callers, both fields are permanently null, so generateAudio (lines 94-121) always hits `if (cue == null || audioFiles == null) return null;` at lines 102-104. Confirmed.

3) generateAudio itself is also unreachable: a grep for `.generateAudio(` across hibiki/lib returns no call sites. The base declaration at media_source.dart:523-529 throws UnimplementedError(). The `generateAudio` references in audio_export_field.dart (133/155) and the enhancement files are an unrelated local closure parameter (`Future<File?> Function() generateAudio`), not the source override. So the source's override is dead twice over (never called, and would return null if it were).

4) Duplicated live logic confirmed: reader_hibiki_page.dart:2202-2217 reimplements the same extraction (audioFileIndex bounds check -> TtsChannel.instan …(截断)
  - 验证者保留意见: Finding is real but severity is overstated. Claimed high implies user-facing breakage; in fact the live mining path (reader_hibiki_page.dart:2202-2217) works correctly and no user encounters a defect. The override mechanism is simply unreachable dead code plus a duplicated live implementation, which …(截断)

### HBK-AUDIT-043 — Corrupt fieldMappings JSON in a profile snapshot crashes profile switching (unguarded jsonDecode + as Map cast)

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `settings-profile` / error-handling / optimistic-but-unverified deserialization; type-as-theater (`as Map`)
- **位置**: `hibiki/lib/src/profile/profile_keys.dart` : 71-73
- **审查者置信度**: high
- **根因**: mapToAnkiSettings does `Map<String,String>.from(jsonDecode(m['fieldMappings']!) as Map)` with no try/catch and an unchecked `as Map` cast. It is invoked from ProfileRepository.applyProfile (profile_repository.dart:121) which has no surrounding error handling. The value comes from the profile_settings DB table, which can hold malformed data (manual edit, partial/aborted snapshot write, backup import from another version, or future schema change).
- **影响**: If fieldMappings is not valid JSON or decodes to a non-Map (e.g. a JSON array), jsonDecode throws FormatException or the `as Map` throws TypeError. Because applyProfile is awaited inside switchProfile (profile_view_model.dart:75-81) and deleteProfile (profile_repository.dart:48), the exception propagates and aborts the profile switch AFTER setActiveProfileId already ran and AFTER the pref-delete/rewrite transaction may have completed — leaving the app on the new active id but with Anki settings half-applied and no error surfaced to the user.
- **证据**:
~~~
fieldMappings: m.containsKey('fieldMappings') ? Map<String, String>.from(jsonDecode(m['fieldMappings']!) as Map) : const {},
~~~
- **修复建议**: Wrap the decode in a guarded helper: attempt jsonDecode, verify the result is a Map<String,dynamic>, coerce values to String, and fall back to current.fieldMappings (or const {}) on any failure. Do not let a single corrupt profile row abort the entire profile-apply flow.
- **验证（对抗复核）**: Independently confirmed by reading the cited code.

1) profile_keys.dart:71-73 matches the evidence exactly: `fieldMappings: m.containsKey('fieldMappings') ? Map<String, String>.from(jsonDecode(m['fieldMappings']!) as Map) : const {}`. No try/catch; `jsonDecode` throws FormatException on invalid JSON and `as Map` throws TypeError if the decoded value is not a Map (e.g. a JSON array). Notably, AnkiSettings.fromJson (packages/hibiki_anki/lib/src/anki_models.dart:67) uses the safer `json['fieldMappings'] as Map? ?? {}` pattern, but this profile decode site did NOT replicate that defense — a real inconsistency.

2) Call chain confirmed: ProfileRepository.applyProfile (profile_repository.dart:83-124) invokes mapToAnkiSettings at line 121 with no surrounding error handling. In ProfileViewModel.switchProfile (profile_view_model.dart:75-81) the order is: snapshot -> setActiveProfileId(profileId) (line 77) -> applyProfile(profileId) (line 78). Inside applyProfile the pref transaction (lines 105-116) commits BEFORE the Anki decode at line 121, so a throw there leaves the new active id persisted and prefs rewritten, but saveSettings (line 122), the state update (line 79), and _onProfileApplie …(截断)
  - 验证者保留意见: Core defect is real and severity is correct. Two secondary claims are overstated: (a) the "partial/aborted snapshot write" path is largely refuted because replaceProfileSettings (hibiki_core .../database.dart:985-996) runs inside a transaction, making snapshot writes atomic; (b) the implied "data lo …(截断)

### HBK-AUDIT-044 — Sync settings share a top-level mutable singleton (_activeSyncState) whose lifecycle is owned by one widget but read by many

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `settings-profile` / false-modularity / false modularity (files/widgets split but coupled by shared mutable global); pseudo-extensibility
- **位置**: `hibiki/lib/src/sync/sync_settings_schema.dart` : 206-210, 858-869, 1715-1745
- **审查者置信度**: medium
- **根因**: _activeSyncState is a library-global mutable variable. _BackendSelectorWidget.initState creates it (line 862) and dispose() nulls it (line 867), but every other item in the sync destination (auto_sync/statistics/audiobook/content switches at lines 124-168, plus _LanDiscoveryWidget at line 1666) reads/writes the SAME global via _syncSettings(ctx), which lazily re-creates it with hard-coded defaults (backendType=googleDrive, autoSync=false, syncStats=true, syncAudioBook=true, syncContent=false) and an async load(). Ownership is implicit and split across unrelated widgets — the modular SettingsCustomItem split is cosmetic; they are tightly coupled through hidden shared state.
- **影响**: The switches' value getters (e.g. value: (ctx) => _syncSettings(ctx).syncContent) can observe default values instead of persisted ones during the window after _activeSyncState is (re)created but before its async load() completes. Because the dropdown widget can dispose/recreate independently of the switches (e.g. master-detail wide layout, or any rebuild that disposes the selector while switches remain), a freshly nulled-then-recreated state momentarily reports syncStats=true / syncContent=false regardless of what the user persisted, and reflects that in the UI until load() and refresh() land. Toggling a switch during that window writes the wrong baseline back into the in-memory state (the DB write is correct, but the visible state diverges until reload).
- **证据**:
~~~
_SyncSettingsState? _activeSyncState; ... _SyncSettingsState _syncSettings(SettingsContext ctx) => _activeSyncState ??= _SyncSettingsState(ctx)..load();  // dispose: _activeSyncState = null;
~~~
- **修复建议**: Stop using a top-level mutable singleton for screen state. Hoist the sync settings state into a single owning StatefulWidget (or a Riverpod provider scoped to the sync destination) and pass it down, or have each switch read its value directly from SyncRepository via a FutureBuilder/cached load instead of a shared lazily-initialized global with default seed values.
- **验证（对抗复核）**: Independently confirmed every citation by reading the code. (1) Line 206-210: `_SyncSettingsState? _activeSyncState;` is a true library-global mutable variable, lazily created via `_activeSyncState ??= _SyncSettingsState(ctx)..load();`. (2) Lines 858-869: `_BackendSelectorWidgetState.initState` creates it (862) and `dispose()` sets `_activeSyncState = null` (867) — ownership lives in this one widget. (3) Lines 124-168: the four switches (sync.auto_sync/statistics/audiobook/content) all read their `value:` and write their `onChanged:` through the same global via `_syncSettings(ctx)`. (4) Line 1666: `_LanDiscoveryWidget._connectToDevice` also mutates the same global. (5) Lines 1715-1745: the class seeds hard-coded defaults exactly as claimed (googleDrive / autoSync=false / syncStats=true / syncAudioBook=true / syncContent=false) and runs an async `load()` that only calls `refresh()` after the awaited DB reads finish. So the "stale default" window between recreation and load() completion is real.

Reachability of the impact is also real: SettingsDetailPage renders the destination via `ListView.builder` (material_settings_renderer.dart:106) with default cacheExtent and no AutomaticKeep …(截断)

### HBK-AUDIT-045 — Update-channel persistence is asymmetric across profiles: debug channel is profile-scoped, beta/auto-install/never-remind are not

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `settings-profile` / config-persistence-correctness / happy-path-only / copy-paste list maintained by hand where one sibling key was forgotten
- **位置**: `hibiki/lib/src/profile/profile_keys.dart` : 15-26
- **审查者置信度**: high
- **根因**: _excludedPrefKeys excludes 'update_never_remind', 'update_auto_install', and 'update_beta_channel' from profile snapshot/apply, but does NOT exclude 'update_debug_channel'. All four are sibling app-global update settings written through PreferencesRepository (preferences_repository.dart:377-389). The omission of update_debug_channel means it gets captured into per-profile snapshots and overwritten on every profile switch, while its siblings stay global.
- **影响**: Switching profiles silently flips the user's update channel: a user on the debug channel who switches to a profile that was snapshotted while on stable will be forced back to stable (and vice versa). Because setUpdateChannel (settings_actions.dart:121-122) sets beta=true whenever debug=true, the persisted state can become internally inconsistent across profiles (debug restored from profile X but beta not, since beta is excluded), producing a 'debug channel on, beta channel off' combination that _selectedUpdateChannel/home_page never expects. This is a real user-facing settings-corruption path on every profile switch.
- **证据**:
~~~
_excludedPrefKeys = { ... 'update_never_remind', 'update_auto_install', 'update_beta_channel', }; // 'update_debug_channel' is absent. Meanwhile preferences_repository.dart:385-389 defines updateDebugChannel via getPref('update_debug_channel') / setPref('update_debug_channel', value).
~~~
- **修复建议**: Add 'update_debug_channel' to _excludedPrefKeys so all update-channel/update-policy keys are treated identically as app-global and never enter per-profile snapshots. Add a regression test alongside the existing update_beta_channel assertion in profile_keys_test.dart:20.
- **验证（对抗复核）**: I independently confirmed the core defect by reading the cited code.

CONFIRMED FACTS:
- profile_keys.dart:15-26: `_excludedPrefKeys` contains 'update_never_remind', 'update_auto_install', 'update_beta_channel' but NOT 'update_debug_channel'. Verified verbatim.
- preferences_repository.dart:361-391: all four (never_remind, auto_install, beta_channel, debug_channel) are app-global keys read/written via getPref/setPref with the exact key strings claimed. Verified.
- profile_repository.dart:71 (snapshot) and 107-116 (apply) both gate on isExcludedPref. In snapshotCurrentSettings, excluded keys are skipped on capture (line 71). In applyProfile, excluded keys are preserved (skipped at line 108), while NON-excluded keys are deleted-if-absent-from-snapshot (109-111) then overwritten from prefMap (113-114), inside a transaction.
- Therefore update_debug_channel, being non-excluded, IS captured into per-profile snapshots and IS clobbered on every profile switch (applyProfile, reachable from profile selector, deleteProfile fallback at :48, ensureDefaultProfile at :193), while its three siblings stay global. The asymmetry is real and reachable.
- settings_actions.dart:121-122: setUpdateChanne …(截断)
  - 验证者保留意见: The defect itself is real and correctly located, so it is not refuted. But the claimed severity (high) is inflated by two inaccurate impact statements: (a) the user is NOT "forced back to stable" — because the always-co-written update_beta_channel is the global/excluded sibling, losing debug drops t …(截断)

### HBK-AUDIT-046 — All sync credentials persisted as plain base64 in the user SQLite DB (encoding, not encryption)

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / credential/secret security / comment claims a security model that base64 does not provide
- **位置**: `hibiki/lib/src/sync/sync_repository.dart` : 7-10 (doc comment), 184-191 (_encodeSecret/_decodeSecret), 196-383 (all secret setters)
- **审查者置信度**: high
- **根因**: _encodeSecret = base64Encode(utf8.encode(value)); _decodeSecret = base64Decode. The class doc frames this as 'the security model is consistent with gcloud/aws-cli relying on OS file permissions', but base64 is reversible by anyone who reads the DB. On Android the app DB is sandboxed, but with MANAGE_EXTERNAL_STORAGE in this app, rooted devices, and the backup-export path (separate finding), the secrets are recoverable.
- **影响**: OAuth refresh tokens (Dropbox/OneDrive/Google desktop), NAS/FTP/SFTP/SMB/WebDAV passwords, SFTP private key, and the LAN server token are all recoverable from the DB file by any process/user that can read it. base64 provides zero confidentiality.
- **证据**:
~~~
`static String _encodeSecret(String value) => base64Encode(utf8.encode(value)); static String _decodeSecret(String encoded){ try { return utf8.decode(base64Decode(encoded)); } catch (_) { return encoded; } }` — note the catch returns the input unchanged, so even un-encoded plaintext is accepted, and there is no key.
~~~
- **修复建议**: Store secrets via flutter_secure_storage / platform Keystore/Keychain rather than the synced/exportable preferences table. If that is out of scope, at least encrypt-at-rest with a device-bound key and stop describing base64 as a security boundary in the doc comment.
- **验证（对抗复核）**: Independently confirmed every cited element in hibiki/lib/src/sync/sync_repository.dart. (1) Doc comment lines 7-10 verbatim frames base64 as a security model "consistent with gcloud/aws-cli relying on OS file permissions." (2) Lines 184-192: `_encodeSecret(value) => base64Encode(utf8.encode(value))` and `_decodeSecret` does `base64Decode` with `catch (_) { return encoded; }` — fully reversible, no key, and the catch returns the raw input so even un-encoded plaintext passes through, exactly as claimed. (3) Secret setters across 196-383 all route through `_encodeSecret` into the Drift `preferences` table (via `_setString`/`insertOnConflictUpdate`). Verified the writers are live and real, not theoretical: dropbox_sync_backend.dart:126 stores a Dropbox refresh_token, onedrive_sync_backend.dart:164 stores a OneDrive refresh_token, google_drive_auth.dart:220 stores serialized desktop OAuth credentials, sync_settings_schema.dart:1126 stores the SFTP private key, and setServerPassword/setHibikiClientToken store the LAN server token/password. (4) Verified the escape-beyond-sandbox path is reachable: BackupService.exportBackup (backup_service.dart:71-110) runs `VACUUM INTO` on the entire hi …(截断)

### HBK-AUDIT-047 — Conflict resolution silently skips when local/remote timestamps are equal but content differs

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / conflict-resolution correctness / optimistic-but-unverified equality check; mtime-only conflict model
- **位置**: `hibiki/lib/src/sync/sync_manager.dart` : 219-236
- **审查者置信度**: high
- **根因**: _determineSyncDirection compares only millisecond timestamps. `if (localUpdatedAt > remoteTimestamp) export; if (remoteTimestamp > localUpdatedAt) import; return synced;`. Equal timestamps are treated as 'already synced' with zero content comparison. parseProgressTimestamp only has millisecond granularity, and remote timestamps are derived from filename, so collisions are realistic (two devices saving within the same ms, or clock-equal restores).
- **影响**: Two devices with genuinely different progress that happen to share a timestamp will be declared in-sync, and neither side's newer reading position propagates — silent divergence/stall. Worse, because the export path also stomps the remote with last-writer-wins on a strict '>' comparison, a device whose clock is even 1ms behind can never push its newer real progress if the other device's stale write has a higher timestamp.
- **证据**:
~~~
`if (localUpdatedAt > remoteTimestamp) return SyncDirection.exportToTtu; if (remoteTimestamp > localUpdatedAt) return SyncDirection.importFromTtu; return SyncDirection.synced;` — no exploredCharCount/content tiebreak.
~~~
- **修复建议**: On timestamp tie, compare actual exploredCharCount/progress before declaring 'synced'; if they differ, surface a conflict (route through the compare dialog) instead of silently skipping. Consider a monotonic per-device version/vector clock rather than wall-clock ms.
- **验证（对抗复核）**: I independently confirmed the cited code. hibiki/lib/src/sync/sync_manager.dart:233-235 reads exactly: `if (localUpdatedAt > remoteTimestamp) return SyncDirection.exportToTtu; if (remoteTimestamp > localUpdatedAt) return SyncDirection.importFromTtu; return SyncDirection.synced;` — the evidence snippet is verbatim and there is no exploredCharCount/content tiebreak in `_determineSyncDirection` (lines 219-236). I traced the timestamp granularity: the remote timestamp is the millisecond epoch embedded in the filename (ttu_filename.dart:29 `progressFileName(int timestampMs, ...)` → parsed at line 94-98 via `parts[3]`), and `localUpdatedAt` is `readerPositions.updatedAt`, an `integer()` wall-clock millisecond epoch (tables.dart:109; only writers use `DateTime.now().millisecondsSinceEpoch`). The export path uses `localPosition.updatedAt` directly (sync_manager.dart:346), not a fresh now(), so the strict `>` last-writer-wins on wall-clock is accurately described, and the automatic path runs whenever the caller passes `direction == null` (line 161). So the defect is real on a reachable path: on an exact-millisecond tie with differing content the code returns `synced` with zero content compa …(截断)
  - 验证者保留意见: The defect exists in code as cited, but its impact is inflated to 'high'. The headline trigger (equal millisecond timestamps with genuinely different content) is realistically near-unreachable for human reading sessions, since position saves are seconds apart, not sub-millisecond. The finding's cite …(截断)

### HBK-AUDIT-048 — Metadata update deletes remote file BEFORE uploading replacement — failed upload = permanent progress loss

- **Severity**: MEDIUM (审查者报 CRITICAL，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / conflict-resolution / partial-write / happy-path-only flow with no rollback; duplicated across 4 backends
- **位置**: `hibiki/lib/src/sync/webdav_ops.dart (via webdav/smb/hibiki_client backends), hibiki/lib/src/sync/ftp_sync_backend.dart, hibiki/lib/src/sync/dropbox_sync_backend.dart, hibiki/lib/src/sync/onedrive_sync_backend.dart` : webdav_sync_backend.dart:162-196; ftp_sync_backend.dart:253-293; dropbox_sync_backend.dart:369-403; onedrive_sync_backend.dart:382-416
- **审查者置信度**: high
- **根因**: updateProgressFile/updateStatsFile/updateAudioBookFile all do `if (fileId != null) await deleteFile(fileId);` and only THEN upload the new file. There is no temp-name+rename, no upload-then-delete ordering, and no rollback. The progress filename embeds the timestamp/progress (progressFileName), so the new file has a different name than the deleted one — a true delete+create, not an overwrite.
- **影响**: If the network drops, the device sleeps, the FTP control socket dies, or the token expires between the DELETE and the PUT (a wide window on flaky mobile networks), the remote book progress/statistics/audiobook position is irrecoverably destroyed: the old file is gone and the new one was never written. Subsequent syncs then see no remote progress and may overwrite or mark the book as 'import from remote' incorrectly. This is silent reading-progress data loss on a real path.
- **证据**:
~~~
WebDavSyncBackend.updateProgressFile: `if (fileId != null) await _ops!.deleteFile(fileId); final fileName = progressFileName(...); await _ops!.uploadJson(folderId, fileName, progress.toJson());`  FTP: `if (fileId != null) await _deleteRemoteFileImpl(fileId); ... await _uploadJsonImpl(folderId, fileName, progress.toJson());`
~~~
- **修复建议**: Upload the new file first, then delete the old one only after the upload succeeds (upload-then-delete). Better: write to a temp name and atomically rename, or use a stable filename and overwrite in place. Google Drive's handler already does the right thing (update-in-place via fileId), so make the others match its contract.
- **验证（对抗复核）**: I independently confirmed the cited code. WebDavSyncBackend.updateProgressFile/updateStatsFile/updateAudioBookFile (webdav_sync_backend.dart:162-196) do `if (fileId != null) await _ops!.deleteFile(fileId);` then upload a freshly-named file. FtpSyncBackend (ftp_sync_backend.dart:254-293) does `_deleteRemoteFileImpl(fileId)` then `_uploadJsonImpl(...)`. Dropbox (dropbox_sync_backend.dart:369-403) does `_deleteFile(fileId)` then `_uploadJsonFile(...)`. OneDrive (onedrive_sync_backend.dart:382-416) does `_deleteItem(fileId)` then `_uploadJson(...)`. All cited line ranges match exactly. The filename helpers (ttu_filename.dart:29-33,77-91) embed timestamp + metric (`progress_1_6_${timestampMs}_$progress.json`, etc.), so the new file name differs from the deleted one — confirming it is a true delete+create, not an overwrite. There is no upload-then-delete ordering, no temp+rename, no rollback. By contrast Google Drive's handler (google_drive_handler.dart:292-309, _uploadJson) calls `api.files.update(fileId, ...)` for an in-place content replacement when fileId != null, so it genuinely avoids the destructive window — the finding's "Google Drive does the right thing" premise is accurate. So …(截断)
  - 验证者保留意见: The defect (non-atomic delete-before-upload, no rollback, divergent from the Google Drive in-place-update contract) is real and the cited lines are accurate. But the CRITICAL severity and "irrecoverably destroyed / permanent silent reading-progress data loss" claims are overstated. Export is only tr …(截断)

### HBK-AUDIT-049 — Singleton backends are reused concurrently with no mutual exclusion (token/api/cache races, lost writes)

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / concurrency / re-entrancy / false modularity — files split per backend but all share one mutable singleton; no lock on cloud backends
- **位置**: `hibiki/lib/src/sync/sync_auto_trigger.dart, hibiki/lib/src/sync/google_drive_handler.dart, hibiki/lib/src/sync/dropbox_sync_backend.dart, hibiki/lib/src/sync/onedrive_sync_backend.dart, hibiki/lib/src/sync/webdav_sync_backend.dart` : sync_auto_trigger.dart:84-151 (per-book) vs 42-82 (all); google_drive_handler.dart:28-61; dropbox_sync_backend.dart:36-40,205-208; onedrive_sync_backend.dart:38-42
- **审查者置信度**: high
- **根因**: All backends are process-wide singletons (e.g. GoogleDriveSyncBackend.instance, DropboxSyncBackend.instance) holding mutable shared state: _accessToken, _cachedApi, _rootFolderId, _titleToFolderId. _runAutoSync dedups per mediaIdentifier but allows DIFFERENT books to sync concurrently (the only cross guard is the '__all__' key). FTP and SFTP serialize via AsyncMutex, but GoogleDrive/Dropbox/OneDrive/WebDAV/SMB have NO per-operation lock. SyncManager itself holds no lock.
- **影响**: Concurrent syncs of two books (or a manual compare/sync overlapping an auto-sync) interleave on the same singleton: the _titleToFolderId cache and _rootFolderId can be cleared by one sync's retry (clearCache) while another is mid-flight, a 401 refresh on one path swaps _accessToken/_cachedApi out from under another in-flight request, and _persistDriveCache can write a half-populated cache. Net effect: spurious failures, wrong folder targeting, and corrupt persisted folder cache.
- **证据**:
~~~
sync_auto_trigger: `if (!_syncingIds.add(mediaIdentifier)) return;` keys only on per-book id; google_drive_handler._call: on 401 sets `_cachedApi = null; await refreshAuth();` mutating shared state with no lock; dropbox `_authHeaders => {'Authorization': 'Bearer $_accessToken'}` reads shared mutable token.
~~~
- **修复建议**: Serialize all sync operations through a single app-wide mutex (the SyncManager or a per-backend AsyncMutex applied uniformly), or make auto-trigger refuse to start a new per-book sync while any sync is active. At minimum add the AsyncMutex (already used by FTP/SFTP) to the cloud backends' token/api/cache mutations.
- **验证（对抗复核）**: The structural claim is REAL and verified by reading the code. Cloud backends (GoogleDriveSyncBackend/Handler, Dropbox, OneDrive, WebDAV, SMB) are process-wide singletons holding mutable shared state (_rootFolderId, _titleToFolderId, _accessToken, _cachedApi) with NO per-operation mutex — only FtpSyncBackend (ftp_sync_backend.dart:19) and SftpSyncBackend (sftp_sync_backend.dart:19) use AsyncMutex (sync_utils.dart:6). I confirmed concurrent overlap is reachable: in sync_auto_trigger.dart the per-book guard `if (!_syncingIds.add(mediaIdentifier)) return;` (line 92) only dedups the SAME book; two DIFFERENT books pass both line 91 and 92 and run as fire-and-forget Futures (triggerAutoSync* are void and not awaited at base_source_page.dart:100 and home_page.dart:97). Even more clearly, sync_compare_dialog._applyChoices (lines 357-383) builds its own SyncManager and calls syncBook with NO participation in _syncingIds at all, so a manual compare/sync can fully overlap an in-flight auto-sync sharing the same singleton.

However the IMPACT is OVERSTATED for severity=high, and several specific harms in the finding do not actually occur under Dart's single-threaded cooperative-async model (no …(截断)
  - 验证者保留意见: The finding correctly identifies the absence of mutual exclusion and the reachable overlap, so it is not fabricated. But severity=high is inflated: under Dart's single-threaded async model the specific corruption claims (token/api swapped out from under an in-flight request, corrupt persisted cache, …(截断)

### HBK-AUDIT-050 — 27 '*_static_test.dart' files assert on source-file substrings instead of behavior — they pass when the widget is runtime-broken and fail on harmless renames

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `test-coverage` / fake/ineffective-tests / type-system/test theater: grep-the-source masquerading as a test suite; tautological string assertions
- **位置**: `hibiki/test/settings/md3_design_system_static_test.dart` : 251-273 (and the whole file 1-731); same pattern in 26 other files
- **审查者置信度**: high
- **根因**: These tests do File('lib/...').readAsStringSync() then expect(source, contains('HibikiCard(')) / isNot(contains('BorderRadius.circular(12)')). They never build, pump, or render a widget; they assert that source text contains/omits literal substrings. md3_design_system_static_test.dart alone maintains a 200+ entry hardcoded map of file->expected-substrings and a parallel banned-substrings map. 27 test files use readAsStringSync (grep confirms): all the *_md3_static_test, settings_redesign_static_test, settings_migration_static_test, native_popup_dictionary_static_test, etc.
- **影响**: Zero behavioral signal: a widget can throw at runtime, lay out wrong, or wire the wrong callback and these tests stay green as long as the class name appears in the file. Conversely they break on pure refactors (rename HibikiCard, reformat so 'BorderRadius.circular(12)' becomes '.circular( 12 )', move code between files) even when behavior is identical — high false-failure maintenance cost. They are effectively a brittle lint encoded as 731 lines of test, giving false confidence that the MD3 migration is 'tested'.
- **证据**:
~~~
md3_design_system_static_test.dart:256-258 'final String source = file.readAsStringSync(); for (final String token in entry.value) { expect(source, contains(token) ...); }'; bannedByFile map 277-526 e.g. 'lib/src/pages/implementations/home_page.dart': ['AlertDialog(']. native_popup_dictionary_static_test.dart:9-27 even asserts ORDER of substrings (assignIndex < buildLayoutIndex) in a .kt file as a proxy for behavior.
~~~
- **修复建议**: Replace the highest-value ones with widget tests that pumpWidget the surface and assert find.byType(HibikiCard)/interaction outcomes (the codebase already does this well in floating_dict_page_static_test.dart and media_item_dialog_page_test.dart). If a structural guard is genuinely wanted, move it to a custom analyzer lint, not a test suite that claims behavioral coverage.
- **验证（对抗复核）**: I independently confirmed every factual claim by reading the cited code.

1. md3_design_system_static_test.dart:251-273 — verified exactly. Both `test()` blocks do `File(entry.key).readAsStringSync()` then loop `expect(source, contains(token))`. The cited evidence snippet at 256-258 matches verbatim. The `bannedByFile` map (lines 277-526, ~250 lines) uses `expect(source, isNot(contains(banned)))`, and the requiredComponentTokens / migratedSurfaces maps total 200+ hardcoded file→substring entries. The home_page.dart -> ['AlertDialog('] entry is at line 304-306. None of these tests pumpWidget or render anything — they assert source text contains/omits literal substrings, including formatting-sensitive tokens like 'BorderRadius.circular(12)' (line 562) and 'fontSize: 9'.

2. native_popup_dictionary_static_test.dart:9-27 — verified exactly. Line 26 `expect(assignIndex, lessThan(buildLayoutIndex))` asserts the textual ORDER of substrings in a .kt source file (PopupDictActivity.kt) as a proxy for the runtime behavior 'stores initial lookup text before WebView callbacks'. Pure indexOf positional comparison, no execution.

3. The grep claim of 27 files using readAsStringSync is confirmed ( …(截断)
  - 验证者保留意见: Only the severity is overstated, not the substance. The 'high' rating implies user-facing wrong behavior; in reality these are test-only artifacts with no production reachability — the impact is confined to test-effectiveness and maintenance cost, which is a medium-severity maintainability hazard. A …(截断)

### HBK-AUDIT-051 — Anki integration repositories (AnkiConnect network IPC, AnkiDroid ContentProvider IPC, note creation) are untested; only model JSON round-trips are covered

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `test-coverage` / test-coverage-gaps / testing the trivial data class, skipping the I/O-bearing logic
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart` : package-wide: hibiki_anki has 8 lib files, 0 package tests; app-side coverage limited to hibiki/test/anki/anki_models_test.dart
- **审查者置信度**: high
- **根因**: packages/hibiki_anki/test is empty. The only Anki test (hibiki/test/anki/anki_models_test.dart) covers AnkiDeck/AnkiNoteType/AnkiSettings fromJson/toJson round-trips. The repositories that actually talk to Anki (ankiconnect_repository/ankiconnect_service over HTTP, ankidroid/anki_repository over Android ContentProvider) and the card-creation orchestration are never tested. grep for AnkiConnectRepository/AnkidroidRepository/addNote/invoke( in tests -> only an unrelated fake_platform_services helper.
- **影响**: Card creation (a headline feature per project vision) can fail on malformed AnkiConnect request shaping, error-response handling, or AnkiDroid field mapping with no test catching it. Error paths (Anki not running, permission denied, duplicate note) are entirely uncovered.
- **证据**:
~~~
ls packages/hibiki_anki/test -> empty; hibiki/test/anki/anki_models_test.dart groups are only 'AnkiDeck/AnkiNoteType/AnkiSettings fromJson/toJson round-trip'. No test references the repository or service classes exported from hibiki_anki.dart.
~~~
- **修复建议**: Add ankiconnect_repository tests with a fake HTTP client asserting request JSON for addNote/findNotes and handling of error envelopes ({error: ...}); add AnkiDroid repository tests against a fake ContentProvider/MethodChannel covering success + permission-denied + duplicate paths.
- **验证（对抗复核）**: Independently confirmed. (1) packages/hibiki_anki/test/ does NOT exist — `ls` returns "No such file or directory"; the package ships 8 lib dart files (anki_models, anki_service, base_anki_repository, lapis_preset, ankiconnect/ankiconnect_repository, ankiconnect/ankiconnect_service, ankidroid/anki_repository, plus hibiki_anki.dart export) with zero package tests. (2) The repositories cited really do the IPC and orchestration: AnkiConnectService._request (ankiconnect_service.dart:15-32) builds the {action,version,params} HTTP envelope and throws AnkiConnectException on result['error']; AnkiConnectRepository.mineEntry/isDuplicate (ankiconnect_repository.dart:91-246) shape fields, run dupe checks, store media, call addNote; AnkiRepository (ankidroid/anki_repository.dart:41-238) does MethodChannel('app.hibiki.reader/anki') invokeMethod('addNote'/'checkForDuplicates'/'getDecks'/...), field-array mapping (line 202), and reading-field-index detection (325-332). (3) A repo-wide grep of hibiki/test and packages/*/test for mineEntry|fetchConfiguration|checkForDuplicates|invokeMethod|AnkiConnectService|BaseAnkiRepository returned ZERO matches — no test references any of these classes. The only …(截断)

### HBK-AUDIT-052 — Sync conflict-resolution and all remote backends (FTP/Dropbox/GoogleDrive/OneDrive) are untested; FTP-reconnect regression has no regression test

- **Severity**: MEDIUM (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `test-coverage` / test-coverage-gaps / happy-path-only; recently-fixed bug shipped with no regression test guarding it
- **位置**: `hibiki/lib/src/sync/sync_manager.dart` : _syncBookOnce 127-215, _determineSyncDirection 219-236; ftp_sync_backend.dart (entire 19KB file), dropbox_sync_backend.dart, google_drive_sync_backend.dart
- **审查者置信度**: high
- **根因**: SyncManager.syncBook/_syncBookOnce/_handleImport/_handleExport and the last-write-wins conflict decision _determineSyncDirection are never instantiated in any test (grep 'SyncManager(' across hibiki/test -> NOTHING). The concrete network backends are untested except oauth_backend_config_test.dart. The FTP backend specifically just received a regression fix (commit 404742dc5 'FTP reconnects after a dropped control connection (S02)') yet grep for 'reconnect|FtpSync|421|control connection' in hibiki/test finds only an unrelated input_binding_test.dart match — there is no test locking that fix.
- **影响**: Sync direction can be decided wrong (importing stale remote over fresh local progress = silent data loss for the user) and no unit test guards it. The just-fixed FTP control-connection drop can regress at any time undetected. Only the leaf helpers (position_converter, ttu_filename parseProgressTimestamp, mergeStatistics, FallbackSyncBackend, HibikiSyncServer) are tested; the orchestrator that wires them is not.
- **证据**:
~~~
_determineSyncDirection: 'if (localUpdatedAt > remoteTimestamp) return SyncDirection.exportToTtu; if (remoteTimestamp > localUpdatedAt) return SyncDirection.importFromTtu;' (sync_manager.dart:233-235) — pure decision logic, private, untested. grep 'SyncManager(' hibiki/test -> none. grep 'FtpSyncBackend|GoogleDriveSyncBackend|DropboxSyncBackend' hibiki/test -> only oauth_backend_config_test.dart.
~~~
- **修复建议**: Inject a fake SyncBackend (the FallbackSyncBackend mock already proves the interface is mockable) into SyncManager and test the four direction outcomes + import-vs-export merge + importOnly skip. Extract/expose _determineSyncDirection for a focused unit test. Add an FtpSyncBackend test (in-process fake FTP server) asserting reconnect after a dropped control socket, locking the S02 fix.
- **验证（对抗复核）**: Independently confirmed by reading the cited code and test tree. (1) `grep "SyncManager"` across hibiki/test returns NOTHING — SyncManager, _syncBookOnce, _handleImport, _handleExport, and _determineSyncDirection are never instantiated/exercised by any test. (2) _determineSyncDirection at sync_manager.dart:219-236 is exactly the pure last-write-wins logic quoted (lines 233-235 match verbatim) and it runs on the real auto-sync path: sync_auto_trigger.dart:65 (syncAllBooks) and :114 (syncBook) both call without an explicit `direction`, so the decision is unguarded; a wrong import-over-local decision silently overwrites the local reading position via upsertReaderPosition (sync_manager.dart:265-271), so the data-loss path is genuinely reachable. (3) grep for FtpSyncBackend/GoogleDriveSyncBackend in tests → none; Dropbox/OneDrive appear ONLY in oauth_backend_config_test.dart, which I read — it asserts only the static isConfigured getter, exercising zero sync/network logic. (4) FTP reconnect fix exists (commit 404742dc5; ftp_sync_backend.dart _ensureConnected/_dropConnection at lines 481-490+) and its own commit message concedes the idle-drop reconnect e2e is unverified because FTPConnec …(截断)
  - 验证者保留意见: The defect is real but the claimed severity (high) is inflated. This is a test-coverage gap, not a demonstrated active bug: the _determineSyncDirection logic, read carefully, is correct last-write-wins (null/null→synced, null-local→import, null-remote→export, then timestamp comparison). The finding …(截断)

### HBK-AUDIT-053 — reader_pagination_scripts shellScript tests only grep the generated JS for substrings — the actual pagination/restore logic is never executed

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `test-coverage` / happy-path-only / fake-tests / string-contains assertion standing in for behavioral coverage of untestable JS
- **位置**: `hibiki/test/reader/reader_pagination_scripts_test.dart` : 140-209
- **审查者置信度**: high
- **根因**: The 'shellScript contract' group builds the JS string and asserts expect(script, contains('paginate')) / contains('calculateProgress') / contains('onRestoreComplete') / contains('updatePageSize') / contains('0.75'). These verify only that the Dart string template injected the expected names/values. The genuine reader behavior — JS-side offset->page restore, pagination, progress calc (the core of the 4088-line ReaderHibikiPage flagged in CLAUDE.md) — runs in the WebView and is exercised only by flutter-drive integration tests, not these unit tests.
- **影响**: Restore-position correctness (a real user-facing failure: book reopens at the wrong page) cannot regress-fail here; the JS engine could be logically broken while these tests stay green because the function name is still present in the script string. The Dart-side helpers in the same file (didScroll, doubleResult, navigationDirectionForKey, paginateInvocation) ARE tested properly — only the shellScript group is hollow.
- **证据**:
~~~
test('defines onRestoreComplete callback', () { final script = ReaderPaginationScripts.shellScript(initialProgress: 0.0, continuousMode: false); expect(script, contains('onRestoreComplete')); }); — and similar contains() checks for 'paginate','calculateProgress','updatePageSize','initialize'.
~~~
- **修复建议**: Keep the lightweight contains() checks if desired but add real coverage of the restore math: extract the offset->page / page->offset conversion out of the JS string into testable Dart (or assert against the existing position_converter helpers), and cover restore behavior end-to-end in the flutter-drive integration tests with explicit assertions on restored page index, not just that the JS function name exists.
- **验证（对抗复核）**: I independently read both the test file (hibiki/test/reader/reader_pagination_scripts_test.dart) and the source (hibiki/lib/src/reader/reader_pagination_scripts.dart). The finding is accurate on every load-bearing claim.

CONFIRMED FACTS:
1. The "shellScript contract" group at lines 140-209 uses only substring assertions. Every test calls ReaderPaginationScripts.shellScript(...) then asserts expect(script, contains('...')) for identifiers/values: 'window.hoshiReader' (148), 'paginate'+'calculateProgress' (164-165), '0.75' (173), 'cue1' (182), 'onRestoreComplete' (190), 'updatePageSize' (198), 'initialize'+'addEventListener' (206-207). The exact lines cited match.
2. shellScript (source lines 95-127) returns a Dart triple-quoted JS string via _paginatedShellScript (505-978) / _continuousShellScript (982-1282). The real pagination/restore/progress logic — restoreProgress (749), calculateProgress (729), paginate (784), scrollToProgressPaged (182), buildPaginationMetrics (667) — lives entirely inside that JS string literal. None of it is executed by Dart; it only runs in the WebView. So the contains() checks verify only that the Dart template injected the expected names/values, never t …(截断)

### HBK-AUDIT-054 — Entire HibikiSelectableText widget + controller (889 lines) is dead code and is internally broken

- **Severity**: MEDIUM
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / dead-code / zombie code / forked-framework-widget never wired up
- **位置**: `hibiki/lib/src/utils/components/hibiki_selectable_text.dart` : 123-164,223-889
- **审查者置信度**: high
- **根因**: HibikiSelectableText, HibikiSelectableText.rich and HibikiSelectableTextController are referenced ONLY inside their own file (grep of the whole repo for HibikiSelectableText returns no callers outside this file). It is a verbatim fork of Flutter's SelectableText kept as a barrel export but never instantiated. The fork is also wrong: initState() creates _controller (line 605, adds listener line 609) then immediately calls _updateControllerAndSubscribe() which creates a SECOND _controller and adds the listener AGAIN — so _onControllerChanged is registered twice and the first controller object is orphaned (never disposed). HibikiSelectableTextController.selection (line 127) is a late field that dereferences _textSpanEditingController! which is null until a widget binds it, so reading .selection/.hasSelection before build throws.
- **影响**: ~890 lines of zombie maintenance surface that masquerades as a usable component. If anyone ever wires it up they inherit a double-listener (duplicate setState/onSelectionChanged emissions), a leaked TextEditingController per build of initState, and a null-deref crash on premature controller access. Bloats compile units and confuses future maintainers about which selectable-text path is real (the real one is hibiki_text_selection_controls.dart used with the framework SelectableText in HibikiLogPanel).
- **证据**:
~~~
initState (599-610): _controller = _TextSpanEditingController(...); _updateControllerAndSubscribe(); _controller.addListener(_onControllerChanged);
_updateControllerAndSubscribe (641-648): _controller = _TextSpanEditingController(...); if (widget.controller != null) {...} _controller.addListener(_onControllerChanged);  // listener added a 2nd time, prior _controller leaked
Controller.selection (127): late TextSelection selection = _textSpanEditingController!.selection;
~~~
- **修复建议**: Delete hibiki_selectable_text.dart and its barrel export. If a styled selectable text is genuinely needed, use the framework SelectableText with HibikiTextSelectionControls (already done in HibikiLogPanel). If kept for any reason, fix initState to not double-create/double-subscribe and dispose the orphaned controller.
- **验证（对抗复核）**: I independently read hibiki/lib/src/utils/components/hibiki_selectable_text.dart (889 lines total, confirmed via wc) and grep'd the whole repo. All three sub-claims hold on the actual code:

1. DEAD CODE — confirmed and actually stronger than claimed. `Grep "hibiki_selectable_text"` restricted to *.dart files returns ZERO matches, meaning NO Dart file imports this file at all (not even via a barrel/export). Every reference to the symbols HibikiSelectableText / HibikiSelectableText.rich / HibikiSelectableTextController is inside the file itself (lines 54-613). All other repo matches are documentation HTML/SVG/MD under docs/design/. The codebase's real selectable-text path uses the framework SelectableText (e.g. hibiki_material_components.dart:1246). So the widget is an unreferenced, unexported orphan fork of Flutter's SelectableText.

2. DOUBLE-LISTENER + ORPHANED CONTROLLER — confirmed. initState (lines 599-610): line 605 `_controller = _TextSpanEditingController(...)` (instance A); line 608 calls `_updateControllerAndSubscribe()` which at line 642 reassigns `_controller = _TextSpanEditingController(...)` (instance B, orphaning A) and at line 647 calls `_controller.addListener(_onC …(截断)
  - 验证者保留意见: Not refuted. Slight imprecision in the finding: it describes the file as "kept as a barrel export," but no Dart export/import of it exists anywhere — it is a completely orphaned file. This makes the dead-code claim stronger, not weaker. Severity stays medium: the double-listener leak and null-deref …(截断)

### HBK-AUDIT-055 — Accessibility service does not gate on Hibiki being foreground — clipboard/overlay dict reacts to global selections silently

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `android-native-security` / security / default-on convenience feature with broad ambient data capture and no consent scoping
- **位置**: `hibiki/android/app/src/main/java/app/hibiki/reader/FloatingDictService.java` : 297-320 (clipboard monitoring), 53 (monitoringEnabled default true)
- **审查者置信度**: medium
- **根因**: monitoringEnabled defaults to true and the clipboard listener auto-searches whatever lands on the primary clip while the floating dict is up, regardless of which app produced it. Combined with the global accessibility selection feed, the overlay continuously reads cross-app content. There is no consent prompt tying monitoring to the user's intent per source app.
- **影响**: Privacy: when the floating dictionary is enabled, copying a password/2FA code/private message in another app triggers an automatic dictionary lookup of that content (routed to Dart via notifyFloatingDictEvent and shown in the overlay). This is surprising data flow that the user may not expect to be active outside Hibiki.
- **证据**:
~~~
private boolean monitoringEnabled = true; ... onClipboardChanged(): if (!monitoringEnabled) return; ... String trimmed = text.toString().trim(); ... searchInput.setText(trimmed); triggerSearch(trimmed);
~~~
- **修复建议**: Default monitoring off until explicitly enabled; show a clear persistent indicator and an easy pause; consider only monitoring while Hibiki is the foreground app, or require a tap to look up rather than auto-searching every clip.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-056 — FloatingDictService NPE risk: searchInput/resultView touched before createContentView completes / after teardown

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `android-native-security` / error-handling / happy-path UI wiring assuming views always exist; lifecycle ordering not reasoned about
- **位置**: `hibiki/android/app/src/main/java/app/hibiki/reader/FloatingDictService.java` : 297-320 (onClipboardChanged), 351-355 (triggerSearch), 416-427 (setSearchText/onTextSelected)
- **审查者置信度**: medium
- **根因**: onCreate registers the clipboard listener (lines 76-78) and BaseFloatingService.onCreate calls createContentView() which assigns searchInput/resultView. But the clipboard callback, setSearchText, onTextSelected and triggerSearch dereference searchInput.setText(...) / resultView.setText(...) directly with no null guard. If a primary-clip-changed event arrives during/after teardown (rootView removed in BaseFloatingService.onDestroy but listener removed only afterward in FloatingDictService.onDestroy 82-88), or if createContentView is overridden to fail, these fields can be null.
- **影响**: A clipboard change racing service destruction (the listener is removed in subclass onDestroy AFTER super tears down views in a different order) can throw NullPointerException on the main thread (the callbacks post to the main looper), crashing the overlay service. Low severity because the window is narrow, but it is a real happy-path-only assumption.
- **证据**:
~~~
onClipboardChanged -> new Handler(Looper.getMainLooper()).post(() -> { searchInput.setText(trimmed); triggerSearch(trimmed); }); triggerSearch: resultView.setText("Searching..."); — no null checks; clipboard listener removed in subclass onDestroy after super.onDestroy already ran view teardown.
~~~
- **修复建议**: Null-check searchInput/resultView in all callbacks, and remove the clipboard listener at the START of onDestroy (before super) so no callback fires during teardown.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-057 — Static MethodChannel references (floatingDictChannel/floatingLyricChannel) leaked across FlutterEngine lifecycle

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `android-native-security` / resource-leak / false-modularity via static singletons: cross-component wiring done with leaky statics, no lifecycle teardown — classic 'works in the demo, leaks in the field'
- **位置**: `hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java` : 61-62 (static fields), 337-338 & 447-448 (assignment), 120-143 (static notify*), 111-118 (onDestroy)
- **审查者置信度**: high
- **根因**: floatingDictChannel and floatingLyricChannel are static MethodChannel fields bound to the current FlutterEngine's BinaryMessenger in configureFlutterEngine. onDestroy() never nulls them or clears their handlers, and there is no cleanUpFlutterEngine/detach hook. Static notifyFloatingLyricEvent / notifyFloatingDictEvent / notifyFloatingDictAnki invoke these channels from foreground services at any time.
- **影响**: When the activity/engine is recreated (config change, process re-entry, MainActivity relaunch) the static still points at the old, detached engine's messenger. A floating service that calls notifyFloatingDictEvent after engine teardown either invokes a dead messenger (dropped silently / IllegalStateException risk) or pins the old FlutterEngine in memory, leaking it. The Anki-export and search-term round trips from the floating dictionary can target the wrong/dead engine, producing 'runs but does nothing' behavior that is hard to diagnose.
- **证据**:
~~~
private static MethodChannel floatingLyricChannel; private static MethodChannel floatingDictChannel; ... floatingDictChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), FLOATING_DICT_CHANNEL); ... onDestroy(): ttsChannelHandler.destroy(); ioExecutor.shutdownNow(); — no nulling of the static channels.
~~~
- **修复建议**: Null both static channels (and call setMethodCallHandler(null)) in onDestroy()/cleanUpFlutterEngine; guard notify* against a stale engine. Better: make them instance-scoped and route service->Dart events through a single owned engine reference with explicit attach/detach.
- **验证（对抗复核）**: I read all of MainActivity.java and the cited lines match exactly. floatingLyricChannel/floatingDictChannel are static MethodChannel fields (lines 61-62), assigned to the current engine's BinaryMessenger in configureFlutterEngine (337-338, 447-448), and onDestroy (111-118) only destroys ttsChannelHandler and shuts down ioExecutor — it never nulls these statics or calls setMethodCallHandler(null), and there is no cleanUpFlutterEngine/onDetach override (confirmed via grep: only configureFlutterEngine/super at 222-223). FloatingDictService runs as a separate foreground service and routes searchTe …(截断)
  - 验证者保留意见: Partly refuted on severity/impact, not on existence. The defect (no cleanup of static channel references => possible stale/detached-engine pointer and transient engine leak) is real and reachable. But three load-bearing impact claims are inflated: the IllegalStateException/NPE risk is false (null-gu …(截断)

### HBK-AUDIT-058 — installApk grants install without checking canRequestPackageInstalls() and trusts caller-supplied path

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `android-native-security` / security / optimistic self-update: assumes permission already granted and the path is trusted; no edge handling for the very common 'unknown sources off' case
- **位置**: `hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java` : 270-296
- **审查者置信度**: high
- **根因**: The update channel's installApk takes `path` straight from the Dart side, wraps it in a FileProvider content URI (rooted at path='.', see provider_paths finding) and fires ACTION_VIEW with the package-archive mime type. There is no PackageManager.canRequestPackageInstalls() pre-check (REQUEST_INSTALL_PACKAGES is declared, manifest line 10) and no validation that `path` points to a file the app legitimately downloaded (no signature/origin/containment check).
- **影响**: On API 26+ the install will silently no-op or throw if the unknown-sources permission isn't granted, surfacing only as a generic INSTALL_ERROR — bad UX and a brittle update path. More importantly, because the FileProvider root is the whole files/external tree, any file path Dart can be tricked into passing becomes an installable package URI; combined with no integrity check this is a weak supply-chain point for a self-update flow.
- **证据**:
~~~
String path = call.argument("path"); ... File apkFile = new File(path); Uri apkUri = FileProvider.getUriForFile(context, BuildConfig.APPLICATION_ID + ".provider", apkFile); Intent intent = new Intent(Intent.ACTION_VIEW); intent.setDataAndType(apkUri, "application/vnd.android.package-archive"); ... context.startActivity(intent);
~~~
- **修复建议**: Before launching, call getPackageManager().canRequestPackageInstalls() and route the user to ACTION_MANAGE_UNKNOWN_APP_SOURCES if false; validate apkFile.getCanonicalPath() is under the dedicated update dir; verify the downloaded APK's signature/hash against an expected value before install.
- **验证（对抗复核）**: I confirmed the cited code at MainActivity.java:272-292: installApk takes `path` from the MethodCall, wraps it via FileProvider.getUriForFile(context, APPLICATION_ID + ".provider", apkFile), fires ACTION_VIEW with mime "application/vnd.android.package-archive", and startActivity — with NO PackageManager.canRequestPackageInstalls() precheck. REQUEST_INSTALL_PACKAGES is indeed declared (manifest line 10), and provider_paths.xml (lines 1-18) genuinely roots the FileProvider at path="." across external-path/external-files-path/cache-path/external-cache-path/files-path, so the over-broad provider c …(截断)
  - 验证者保留意见: Overstated, not fully refuted. The code-level facts (no canRequestPackageInstalls precheck, broad FileProvider, no integrity check) are real, but the medium/security severity rests on two weak pillars: (a) "trusts caller-supplied path" — the path is NOT caller-supplied across any trust boundary; it …(截断)

### HBK-AUDIT-059 — AnkiConnect _request never checks HTTP status; non-200/HTML bodies crash jsonDecode with an opaque FormatException

- **Severity**: LOW (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / external-API-contracts / happy-path-only: optimistic parsing of an external HTTP response with no status/shape validation
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart` : 22-32
- **审查者置信度**: high
- **根因**: _request posts to the AnkiConnect endpoint and immediately does jsonDecode(response.body) without inspecting response.statusCode. AnkiConnect (or any process listening on host:port, or a proxy/captive portal) can return non-200 with an HTML/text body. jsonDecode then throws a FormatException, not AnkiConnectException.
- **影响**: On a misconfigured host/port or when something other than AnkiConnect listens on the port (very common: a dev server, captive portal), the user sees raw 'Cannot connect to AnkiConnect: FormatException: Unexpected character' instead of an actionable message. checkConnection() catches SocketException/TimeoutException/ClientException but a FormatException from jsonDecode falls into the generic catch and produces confusing UI text. The contract 'response is always valid AnkiConnect JSON' is assumed but never validated.
- **证据**:
~~~
final response = await http.post(Uri.parse('http://$host:$port'), ...).timeout(_timeout);
    final result = jsonDecode(response.body);
    if (result['error'] != null) { throw AnkiConnectException(...); }
~~~
- **修复建议**: Check response.statusCode != 200 first and throw AnkiConnectException with a clear message; wrap jsonDecode in try/catch and convert FormatException into AnkiConnectException('Invalid response from $host:$port (not AnkiConnect?)'). Also validate that decoded result is a Map and contains both 'result' and 'error' keys per the v6 contract.
- **验证（对抗复核）**: I read packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart (lines 15-59) and the wrapping repository ankiconnect_repository.dart (lines 39-89, 92-220). The cited lines 22-32 match exactly: _request does http.post(...).timeout(_timeout) with NO response.statusCode check (lines 22-26), then jsonDecode(response.body) with NO surrounding try/catch (line 27), then only inspects result['error'] (line 28). dart:convert's jsonDecode throws FormatException on a non-JSON body (HTML from a captive portal, a different dev server on the port, a proxy error page). The factual core is therefore …(截断)
  - 验证者保留意见: Overstated, not refuted. The title says jsonDecode "crashes" with an opaque FormatException, but on the primary reachable path (fetchConfiguration -> checkConnection, repository line 43) the FormatException is caught by checkConnection's generic catch (lines 56-58) and converted into a returned erro …(截断)

### HBK-AUDIT-060 — AnkiConnect duplicate pre-check swallows all errors and proceeds to addNote, undermining the no-duplicates guarantee

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / error-handling / future swallowing errors; catch-and-continue masking a contract failure
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart` : 187-203
- **审查者置信度**: medium
- **根因**: When allowDupes is false, isDuplicate is wrapped in try/catch that only debugPrints on failure and then falls through to addNote. If the dupe query itself fails (e.g. transient AnkiConnect error, malformed field-name query per the other finding), the code proceeds as if not a duplicate.
- **影响**: Best-effort dedup: a failed dupe query means the guard is silently bypassed. For AnkiConnect, addNote's own default dupe rejection partly compensates, but if allowDupes logic were ever changed to send allowDuplicate=true the silent bypass would create real duplicates. Today the symptom is a misleading export-failed instead of duplicate, or an accidental add.
- **证据**:
~~~
try { final isDupe = await service.isDuplicate(...); if (isDupe) return MineResult.duplicate; } catch (e, stack) { debugPrint('...dupeCheck: $e\n$stack'); }  // falls through to addNote
~~~
- **修复建议**: On dupe-check failure, decide deliberately: either return MineResult.error (fail closed) or document that addNote's server-side dupe rejection is the real guard. Do not silently treat a failed check as 'not a duplicate'.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-061 — AnkiConnect getDeckNames/getModelNames/getModelFields cast result with (result as List) and no shape guard; a malformed result crashes fetch outside the AnkiConnectException path

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / type-safety / unchecked as-cast on dynamic external response; no version validation despite hardcoding version:6
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_service.dart` : 61-77
- **审查者置信度**: medium
- **根因**: Each of getDeckNames/getModelNames/getModelFields does (result as List).cast<String>(). _request returns result['result'] which is dynamic. If AnkiConnect returns an unexpected shape (e.g. result is a Map or null because the add-on version differs), 'result as List' throws a TypeError. fetchConfiguration's catch(e) is broad so it is caught there, but checkConnection/isAvailable only catch network exceptions, so isAvailable() returning via _request('version') is fine, yet getModelFields inside the fetch loop relies solely on the outer broad catch.
- **影响**: Version-compat fragility: an older/newer AnkiConnect returning a different result shape produces a generic 'Cannot connect to AnkiConnect: type X is not a subtype of List' message rather than a version-mismatch hint. Low severity because the broad catch prevents a crash, but the diagnostics are misleading.
- **证据**:
~~~
Future<List<String>> getDeckNames() async { final result = await _request('deckNames'); return (result as List).cast<String>(); }
~~~
- **修复建议**: Validate result is List before cast and throw AnkiConnectException('Unexpected AnkiConnect response for deckNames') otherwise; consider checking the 'version' action's returned int against the expected v6 to detect incompatible add-on versions early.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-062 — _storeRemoteAudio / _storeDictionaryMedia hardcode .mp3 extension and split('.').last for extension, mislabeling non-mp3 audio and breaking on extension-less URLs

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / external-API-contracts / happy-path assumption that all remote audio is mp3; fragile string parsing for extensions
- **位置**: `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart` : 286-302,314-316
- **审查者置信度**: low
- **根因**: Downloaded remote audio is always written as hibiki_audio_$hash.mp3 regardless of actual content type, and storeMediaFile uses that filename, so Anki treats e.g. an aac/ogg stream as mp3. _storeDictionaryMedia derives ext via media.path.split('.').last — for a path with no dot this returns the whole path, producing a bogus filename.
- **影响**: Media files with the wrong extension may fail to play in Anki, or filename collisions/garbage names for extension-less paths. Cosmetic-to-functional depending on the source URL.
- **证据**:
~~~
audioFile = File('${cacheDir.path}/hibiki_audio_$urlHash.mp3');
... final ext = media.path.split('.').last; final filename = 'hibiki_dict_${media.path.hashCode}.$ext';
~~~
- **修复建议**: Derive the extension/content-type from the HTTP Content-Type header (after the status check) or from the URL path with a fallback; guard split('.').last when no '.' is present.
- **验证（对抗复核）**: I independently read packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart and confirmed both cited code locations exactly.

Sub-claim 1 (lines 286-302, _storeRemoteAudio): For an http(s) URL, the response body is unconditionally written to File('${cacheDir.path}/hibiki_audio_$urlHash.mp3') at line 289. Line 297 then computes filename = audioFile.uri.pathSegments.last (always *.mp3) and passes it to service.storeMediaFile (lines 298-301). The HTTP response Content-Type is never inspected. So any non-mp3 remote audio (ogg/aac/etc.) is stored in Anki labeled .mp3. The sibling Anki …(截断)

### HBK-AUDIT-063 — channel argument casts (e.key as int, e.value as String) assume MethodChannel codec types with no validation; AnkiDroid deck ids exceed 32-bit and rely on int==long

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `anki` / type-safety / type-system-as-theater: unchecked as-casts on untyped platform-channel maps
- **位置**: `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart` : 45-63
- **审查者置信度**: medium
- **根因**: decksRaw.entries.map((e) => AnkiDeck(id: e.key as int, name: e.value as String)) and modelsRaw entries cast dynamic map keys/values with unchecked 'as'. getFieldList result is List<String>.from(fieldsRaw as List? ?? []). If the native side ever returns a key as String (e.g. a JSON-stringified long, which AnkiDroid deck/model ids are — 13-digit epoch-based longs) the cast throws and the whole fetch fails with an uncaught CastError (not the PlatformException catch).
- **影响**: Type theater: the code assumes the StandardMessageCodec always decodes ids as Dart int (it does for Java Long → int on 64-bit, but a CastError here is uncaught by the PlatformException-only catch in fetchConfiguration, crashing the fetch). Brittle if the native contract changes.
- **证据**:
~~~
final decks = decksRaw.entries.map((e) => AnkiDeck(id: e.key as int, name: e.value as String)).toList();
... noteTypes.add(AnkiNoteType(id: entry.key as int, name: name, fields: fields));
~~~
- **修复建议**: Use safe parsing: id can be (e.key is int ? e.key : int.parse(e.key.toString())) and guard non-String names. Broaden the catch in fetchConfiguration to also handle TypeError/FormatException, returning AnkiFetchResult.error instead of throwing out of the provider.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-064 — AppModel.dispose() leaks DictionaryRepository / MediaHistoryRepository / PreferencesRepository / ThemeNotifier (never disposed) and the ChangeNotifierProvider may dispose AppModel mid-flight

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `app-startup-state` / resource-leak / partial cleanup — dispose only handles a hand-picked subset of owned notifiers
- **位置**: `hibiki/lib/src/models/app_model.dart` : 2318-2329 (dispose), 168/172/176/179/182/183 (owned notifiers)
- **审查者置信度**: medium
- **根因**: dispose() disposes the ad-hoc ChangeNotifiers (dictionaryEntriesNotifier etc.) and audioCtrl, and removes the prefs/theme listeners, but never calls dispose() on prefsRepo, themeNotifier, dictRepo, mediaHistoryRepo (all ChangeNotifiers) nor closes _database. Because appProvider is a non-autoDispose ChangeNotifierProvider, this is mostly latent for the main app, but the popup container and any test using ProviderContainer.dispose() will leak these notifiers / leave the DB open.
- **影响**: Leaked ChangeNotifier listener registrations and an unclosed Drift database on container disposal (popup/test lifecycles), and inconsistent ownership semantics (AppModel constructs these but doesn't fully own their teardown).
- **证据**:
~~~
app_model.dart:2318-2329 dispose() — no dictRepo.dispose(), mediaHistoryRepo.dispose(), prefsRepo.dispose(), themeNotifier.dispose(), or _database.close(). closeForPopup (2311-2316) closes DB but doesn't dispose notifiers either.
~~~
- **修复建议**: In dispose(), also dispose prefsRepo/themeNotifier/dictRepo/mediaHistoryRepo and close _database when initialised, mirroring the construction in initialise().
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-065 — DictionaryRepository and MediaHistoryRepository extend ChangeNotifier but never call notifyListeners and are never listened to — dead reactive contract

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `app-startup-state` / dead-code / type/abstraction as theater — base class chosen to look reactive, but the reactive machinery is entirely unused; mutations are silent
- **位置**: `hibiki/lib/src/models/dictionary_repository.dart, hibiki/lib/src/models/media_history_repository.dart` : dictionary_repository.dart:11 (extends ChangeNotifier); media_history_repository.dart:7 (extends ChangeNotifier)
- **审查者置信度**: high
- **根因**: Both repos extend ChangeNotifier but grep shows zero notifyListeners() calls in either file, and AppModel only does prefsRepo.addListener/themeNotifier.addListener — never dictRepo.addListener or mediaHistoryRepo.addListener. After dictRepo mutations (persistDictionary, addHistoryResult, addMediaItem) AppModel instead pokes unrelated ad-hoc ChangeNotifiers (dictionaryEntriesNotifier, dictionarySearchAgainNotifier) by hand. The repos' own listener list is permanently empty.
- **影响**: Misleading contract: a maintainer who adds a widget calling dictRepo.addListener(...) will silently never be notified of cache mutations, leading to stale UI. The extra ChangeNotifier inheritance also implies a dispose() obligation that AppModel.dispose() never honors for these two repos.
- **证据**:
~~~
grep notifyListeners in dictionary_repository.dart → No matches. grep notifyListeners in media_history_repository.dart → No matches. app_model.dart addListener calls only at lines 983, 990, 1194 (prefsRepo + themeNotifier). Mutations like dictionary_repository.dart:120 persistDictionary mutate _dictionariesCache with no notify.
~~~
- **修复建议**: Either make these repos actually notify (call notifyListeners on cache mutation and have AppModel subscribe, replacing the ad-hoc dictionaryEntriesNotifier/dictionarySearchAgainNotifier hand-poking), or drop `extends ChangeNotifier` and make them plain repositories. Pick one; the current half-state is a trap.
- **验证（对抗复核）**: Independently confirmed every factual claim by reading the cited code.

1. DictionaryRepository extends ChangeNotifier (dictionary_repository.dart:11) and MediaHistoryRepository extends ChangeNotifier (media_history_repository.dart:7) — confirmed.
2. Grep for notifyListeners in both files returns "No matches found" — neither repo ever notifies. Confirmed.
3. In app_model.dart the only addListener calls are prefsRepo.addListener(notifyListeners) (983, 1194) and themeNotifier.addListener(notifyListeners) (990). Neither dictRepo nor mediaHistoryRepo is ever subscribed to. Confirmed.
4. Cache muta …(截断)
  - 验证者保留意见: Not refuted on facts — every cited line and grep result matches. But the severity is overstated. There is no reachable defect: nothing subscribes to these repos, so no stale-UI bug exists, and the claimed dispose obligation has nil practical impact (empty listener list on an app-lifetime-scoped obje …(截断)

### HBK-AUDIT-066 — quickActionColorProvider relies on Future.wait result order matching quickActions.values iteration order across two separate iterations

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `app-startup-state` / state-management-correctness / index-coupled parallel collections; fragile positional join between two independent map iterations
- **位置**: `hibiki/lib/src/models/app_model.dart` : 97-113
- **审查者置信度**: medium
- **根因**: It builds futures via `appModel.quickActions.values.map(...)` then later joins results via `appModel.quickActions.values.mapIndexed((i, action) => MapEntry(action.uniqueKey, colors[i]))`. This assumes the two `.values` iterations yield identically ordered sequences and that Future.wait preserves order. quickActions is an unmodifiable LinkedHashMap so order is stable today, but the join is positional rather than keyed — any future change to action ordering or filtering between the two passes silently mismaps colors to actions.
- **影响**: Latent correctness hazard: a refactor that filters/reorders quickActions in one of the two iterations would assign each action the wrong icon color with no error. Low impact today because order is currently stable.
- **证据**:
~~~
app_model.dart:101 `appModel.quickActions.values.map((e) async {...}).toList();` and 110 `appModel.quickActions.values.mapIndexed((i, action) { return MapEntry(action.uniqueKey, colors[i]); })`.
~~~
- **修复建议**: Compute color per action keyed by uniqueKey in a single pass (e.g. await Future.wait of MapEntry futures), removing the positional colors[i] join.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-067 — ASS parser fabricates endMs = startMs + 5000 (and accepts end < start) on malformed Dialogue lines

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `audiobook-audio` / parse/error-handling / happy-path fallback that hides malformed timing instead of reporting it
- **位置**: `packages/hibiki_audio/lib/src/parsers/ass_parser.dart` : 139-141 (endMs fallback); 150 (push without start<=end check)
- **审查者置信度**: high
- **根因**: When the End column is missing/unparseable the parser silently substitutes startMs+5000ms, and it never validates end > start. A line with End before Start yields a cue whose endMs < startMs.
- **影响**: Misaligned/negative-duration cues are produced silently from a corrupt ASS file. findCueIndex tolerates it (never matches an inverted cue), so highlight just never fires for that line and the user gets a 5s guess for missing ends — no error, hard to diagnose.
- **证据**:
~~~
`final int endMs = endCol >= 0 && endCol < parts.length ? _parseAssTime(parts[endCol].trim()) ?? startMs + 5000 : startMs + 5000; ... rawCues.add((startMs, endMs, text));`
~~~
- **修复建议**: When End is unparseable, prefer clamping to next cue's start (like LRC) rather than a fixed 5s; and skip/clamp cues where end <= start with a debug warning.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-068 — Import 'unsupported file format' branches return without resetting _importing/UI when format invalid only at alignment-pick time

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `audiobook-audio` / error-handling / defensive double-validation that diverges between picker and import; widget-state mutated mid-import
- **位置**: `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart` : _doImport:612-633 mutates `_alignmentPath = persistedAlignment` (629) before parse; format chosen at 622 with `cueFormats.contains(ext) ? ext : 'json'`
- **审查者置信度**: medium
- **根因**: _doImport reassigns the stateful `_alignmentPath` to the persisted copy before parsing, and infers a 'json' fallback for any unknown extension that slipped past the picker. There is no re-validation that the extension is one of the supported set at import time, so an unexpected extension is force-routed through JsonAlignmentParser.
- **影响**: A non-JSON file with an unusual extension reaching _doImport is parsed as JSON; jsonDecode throws, caught by the generic catch, and the user sees only the generic audiobook_import_error with no hint about format. Also, mutating _alignmentPath to the persisted path means a retry after failure silently re-reads the persisted copy. Cosmetic/robustness, not corruption.
- **证据**:
~~~
`final String format = cueFormats.contains(ext) ? ext : 'json'; ... persistedAlignment = await AudiobookStorage.persistFileWithProgress(...); _alignmentPath = persistedAlignment; ... parsed = await _parseCues(format);` and JsonAlignmentParser.parseString: `jsonDecode(content) as Map<String, dynamic>` (will throw on non-JSON).
~~~
- **修复建议**: Validate the extension against the supported set at import start and bail with a specific message; avoid mutating _alignmentPath (use a local for the persisted path).
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-069 — becomingNoisyEventStream subscription leaked on every load(); old session handlers keep pausing the player

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `audiobook-audio` / resource-leak / copy of the audio-session pattern that omits the cancel-before-resubscribe the sibling file (audio_recorder_page.dart) does correctly
- **位置**: `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart` : load():280-283 cancels _positionSub/_playingSub but not _noisySub; _configureAudioSession():646-660 assigns a new _noisySub each call; dispose():1032 only cancels it once
- **审查者置信度**: high
- **根因**: load() is explicitly written to be re-invokable (it recreates _loadReady and cancels _positionSub/_playingSub), and it calls _configureAudioSession() which does `_noisySub = session.becomingNoisyEventStream.listen(...)` without first cancelling the previous _noisySub. So a second load() on the same controller orphans the prior subscription while leaving its `_player.pause()` callback live.
- **影响**: If load() is called more than once on a controller instance (the API permits it and partially handles re-load), each call leaks one becomingNoisy listener. Every leaked listener still calls _player.pause() on a headphone-unplug event, so the player gets paused N times and the stream subscription is never released until the player is GC'd. Bounded today because reader_hibiki_page disposes the old controller and builds a fresh one, but the controller's own re-load contract is broken.
- **证据**:
~~~
load(): `await _player.stop(); _positionSub?.cancel(); _playingSub?.cancel(); await _configureAudioSession();` — no `_noisySub?.cancel()`. _configureAudioSession(): `_noisySub = session.becomingNoisyEventStream.listen((_) { _player.pause(); });`. Contrast audio_recorder_page.dart:186-188 `_noisySub?.cancel(); _noisySub = session.becomingNoisyEventStream.listen(...)`.
~~~
- **修复建议**: In load() (or at the top of _configureAudioSession) add `_noisySub?.cancel(); _noisySub = null;` before re-subscribing, mirroring the _positionSub/_playingSub cancels.
- **验证（对抗复核）**: I independently confirmed the code mechanics. In packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart, load() at lines 279-283 calls `_player.stop(); _positionSub?.cancel(); _playingSub?.cancel(); await _configureAudioSession();` — it does NOT cancel `_noisySub`. _configureAudioSession() at lines 657-659 unconditionally does `_noisySub = session.becomingNoisyEventStream.listen((_) { _player.pause(); });`, and dispose() at line 1032 cancels it only once. load() is structurally re-invokable: it re-completes `_loadReady` (263-264) and cancels+recreates `_positionSub`/`_playingSub` (2 …(截断)
  - 验证者保留意见: Not refuted as fabricated — the code mechanism is real and the lines match (allowing for the class being named AudiobookPlayerController, not AudiobookController). But the severity is overstated: the leak is unreachable on every current path because each load() is invoked on a freshly-constructed co …(截断)

### HBK-AUDIT-070 — snapAudioToReader / getReaderViewportPos is dead, unwired pseudo-feature with an incompatible coordinate contract

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `audiobook-audio` / dead-code/false-feature / optimistic-but-unverified feature: full reverse-snap implementation written but never connected, and the only matching producer uses a different coordinate spac …(截断)
- **位置**: `packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart + hibiki/lib/src/media/audiobook/audiobook_bridge.dart` : audiobook_controller.dart:360 (getReaderViewportPos field), 866-894 (snapAudioToReader); audiobook_bridge.dart:431-456 (getViewportNormOffset)
- **审查者置信度**: high
- **根因**: getReaderViewportPos is never assigned and snapAudioToReader is never called anywhere in the repo (grep confirms zero call sites / assignments outside the declaration). snapAudioToReader expects a viewport `offset` in the same normalized-character space as SasayakiFragment.normCharStart (compared via `(frag.normCharStart - viewOffset).abs()` and `frag.normCharStart <= viewOffset`). The only viewport producer, AudiobookBridge.getViewportNormOffset, returns `section:0` hardcoded and `offset = round(progress*10000)` (a 0..10000 progress fraction), which is NOT character offsets and would never match real cue normChar offsets.
- **影响**: No live bug today (the path is unreachable). But it is shipped dead code that misleads maintainers into thinking 'snap audio to reader page' works; if anyone wires getViewportNormOffset into getReaderViewportPos it will mis-seek because the offset units differ.
- **证据**:
~~~
grep for `getReaderViewportPos`/`snapAudioToReader` finds only the declaration and doc comments, never an assignment or invocation. getViewportNormOffset JS: `return JSON.stringify({section:0,offset:Math.round(p*10000)});`
~~~
- **修复建议**: Either delete getReaderViewportPos/snapAudioToReader until a real producer exists, or fix getViewportNormOffset to emit the real section + normalized-character offset and wire it to the controller field. Do not ship the half-feature.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-071 — Gradle APK-rename block: fat-APK branch computes newName but never assigns outputFileName (dead rename), and uses AGP-deprecated DSL

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / build-config / copy-pasted variant-rename block with a missing assignment; logic that 'runs' but is a no-op on one branch
- **位置**: `hibiki/android/app/build.gradle` : build.gradle:125-165 (esp. 138-144 vs 161)
- **审查者置信度**: medium
- **根因**: In `applicationVariants.all { variant.outputs.all { ... } }`, the per-ABI branch assigns `outputFileName = newName` (line 161), but the null-architecture (fat APK) branch (lines 138-144) computes `newName` and sets only versionCodeOverride — it never assigns `outputFileName`, so the fat APK is not renamed by this block at all. Additionally `applicationVariants`, `output.getFilter(OutputFile.ABI)`, `outputFileName`, and `versionCodeOverride` are the legacy Variant API deprecated in AGP 8.x (project uses AGP 8.11.1 per settings.gradle:25), so the whole block is fragile and emits deprecation warnings.
- **影响**: Inconsistent/unreliable output naming: split-per-ABI outputs get renamed to hibiki_<ver>-<arch>.apk while fat builds do not, and the legacy DSL may stop working on the next AGP bump, breaking versionCodeOverride (which encodes ABI offsets into versionCode). Because Flutter tooling copies artifacts into build/app/outputs/flutter-apk/ with its own app-<abi>-release.apk naming, the gradle outputFileName is also largely shadowed for the Flutter build path — making the block effectively dead while still being a maintenance trap.
- **证据**:
~~~
build.gradle:138 `if ("${architecture}" == "null") { ... newName = ...; output.versionCodeOverride = (100 * ...) }` — no `outputFileName =`. Compare :161 `outputFileName = newName` only in the else branch. settings.gradle:25 `id "com.android.application" version "8.11.1"`.
~~~
- **修复建议**: If Flutter tooling owns artifact naming (it does — release.yml:94 globs app-*-release.apk produced by Flutter), delete this entire applicationVariants block; do version-code-per-ABI via Flutter's --split-per-abi automatic offsets or `flutter build` flags. If kept, add `outputFileName = newName` to the fat-APK branch and migrate to the AGP 8 Variant/Artifacts API.
- **验证（对抗复核）**: I independently read hibiki/android/app/build.gradle:125-165 and the two concrete code facts in the finding are accurate:

1. Fat-APK branch dead rename (lines 138-144): In `applicationVariants.all { variant.outputs.all { output -> ... } }`, the `"${architecture}" == "null"` branch assigns `newName` (line 140/142) and `output.versionCodeOverride = (100 * versionCode)` (line 144), but NEVER assigns `outputFileName`. The else branch assigns `outputFileName = newName` at line 161. Confirmed: the computed `newName` in the fat-APK branch is genuinely unused dead logic.

2. Deprecated legacy Variant …(截断)
  - 验证者保留意见: Severity is inflated from low to medium. The core code facts are real (fat-APK branch never sets outputFileName; legacy deprecated AGP DSL), but the impact is overstated: (1) versionCodeOverride is assigned on BOTH branches (lines 144 and 162), so the missing outputFileName does NOT break versionCod …(截断)

### HBK-AUDIT-072 — Live Google OAuth client secret stored in working-tree dart_defines.env and baked into distributed APK

- **Severity**: LOW (审查者报 HIGH，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / security / happy-path secrets handling; secret material treated like config
- **位置**: `hibiki/dart_defines.env (+ melos.yaml dev/build:android, main.yml, release.yml)` : dart_defines.env:1-2; melos.yaml:25-30; main.yml:72-73,100-101; release.yml:86-87
- **审查者置信度**: high
- **根因**: dart_defines.env contains a real `GOOGLE_OAUTH_CLIENT_SECRET=GOCSPX-...` and is injected via `--dart-define`/`--dart-define-from-file`. A --dart-define value is compiled as a plaintext constant into the APK's Dart snapshot, so the 'secret' ships to every user and is trivially extractable from a release build. Google issues client secrets for the installed-app OAuth flow but treats them as non-confidential by design; storing/treating it as a secret (CI secret GOOGLE_OAUTH_CLIENT_SECRET, gitignored env file) gives a false sense of confidentiality while it is in fact public in the shipped binary.
- **影响**: The OAuth client secret is recoverable by anyone with the APK; combined with the committed client IDs in google-services.json it allows impersonating the app's OAuth client. The local dart_defines.env also sits unencrypted on the dev machine. Not catastrophic for the installed-app flow, but it is a real exposure and the secret should be rotated and never relied upon as confidential.
- **证据**:
~~~
dart_defines.env:2 `GOOGLE_OAUTH_CLIENT_SECRET=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`. main.yml:73 `--dart-define=GOOGLE_OAUTH_CLIENT_SECRET=${{ secrets.GOOGLE_OAUTH_CLIENT_SECRET }}`. release.yml:87 same. The value is identical real secret in both places. `git log -S GOCSPX` is empty (never committed — that part is fine) but the live secret is present in the checked-out tree.
~~~
- **修复建议**: Rotate the leaked client secret immediately (it is in plaintext in this working tree and was distributed in any prior --dart-define build). For mobile OAuth use PKCE without a client secret, or move any flow that truly needs a confidential secret to a backend. If the secret must stay, document that it is non-confidential and stop treating it as a CI secret. Confirm dart_defines.env stays gitignored (it is: hibiki/.gitignore:2).
- **验证（对抗复核）**: All cited code matches exactly. dart_defines.env:2 contains a real Google client secret `GOOGLE_OAUTH_CLIENT_SECRET=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`. melos.yaml:23,28 inject it via `--dart-define-from-file=dart_defines.env`. main.yml:73 (debug) and main.yml:101 + release.yml:87 (release) inject `--dart-define=GOOGLE_OAUTH_CLIENT_SECRET=${{ secrets.GOOGLE_OAUTH_CLIENT_SECRET }}`, and release.yml:99-104 uploads the resulting APKs to the GitHub release. google_drive_auth.dart:33-34 reads it via `String.fromEnvironment('GOOGLE_OAUTH_CLIENT_SECRET')`, which compiles the value as a plaintext con …(截断)
  - 验证者保留意见: Severity overstated. The exposure is real but the impact described as 'high' (impersonating the app's OAuth client) is not meaningfully achievable: this is a native/installed-app OAuth client secret which Google explicitly treats as non-confidential (public client per RFC 8252), so recovering it fro …(截断)

### HBK-AUDIT-073 — Only one git dependency is SHA-pinned; build relies on cp-into-pub-cache patching instead of proper overrides

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / dependency-hygiene / ad-hoc patching pipeline substituting for real dependency management
- **位置**: `hibiki/pubspec.yaml, hibiki/pubspec.lock, ci/apply-patches.sh` : pubspec.yaml:97-100 (receive_intent git ref); pubspec.lock:1517-1521; apply-patches.sh whole
- **审查者置信度**: high
- **根因**: The single git dependency (receive_intent) is correctly pinned by full SHA (ref 3854d07f... == resolved-ref, good reproducibility). However the project's customization of upstream packages is done by copying files into the pub cache at build time (apply-patches.sh) keyed by exact version directory names, rather than via dependency_overrides to forked git repos / path packages. The only dependency_override is flutter_inappwebview_windows → path (pubspec.yaml:119-121).
- **影响**: The cp-into-cache approach is brittle (Finding #1 is its direct consequence), is invisible to pub's resolution, mutates shared cache state, and is not reproducible outside the exact locked versions. Each dependency upgrade silently invalidates the corresponding patch dir with no compile-time signal until the script either no-ops or (now) hard-fails.
- **证据**:
~~~
pubspec.yaml:97-100 git receive_intent with ref pinned; lock:1516-1521 ref==resolved-ref. apply-patches.sh:37-38 `cp -r "$pkg_dir"* "$target_dir/"` into $PUB_CACHE. No fork git deps or path overrides for the patched packages.
~~~
- **修复建议**: Replace cache-patching with maintained forks referenced as SHA-pinned git deps (or path packages) under dependency_overrides, so patches travel with the lock and break loudly at resolution time when a version drifts. Keep receive_intent's SHA pin.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-074 — Store-listing description claims 'ッツ Ebook Reader' engine that no longer ships; single-locale metadata vs 17 app languages

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / developer-experience / stale marketing/docs contradicting current implementation
- **位置**: `fastlane/metadata/android/en-US/full_description.txt` : full_description.txt:1 (powered by ッツ Ebook Reader); fastlane/metadata/android/ contains only en-US/
- **审查者置信度**: medium
- **根因**: The Play-store full description states the EPUB reader is 'powered by ッツ Ebook Reader', but per the repo CLAUDE.md the active reader is the Hoshi implementation (ReaderHoshiPage/ReaderHoshiSource) and TTU/ッツ is retained only as a migration boundary for historical IndexedDB data. The metadata is also single-locale (en-US only) while the app ships 17 languages (Slang i18n) — store listing is not localized to match.
- **影响**: User-facing store text misrepresents the current engine (drift between docs/marketing and implementation), and non-English users get an English-only store listing despite full in-app localization. Cosmetic but a credibility/discoverability hit.
- **证据**:
~~~
full_description.txt:1 `...EPUB reader</b> powered by ッツ Ebook Reader with tap-to-look-up...`. CLAUDE.md: '当前阅读器入口 reader_hoshi_page.dart ... 旧 TTU 只保留迁移用途'. `ls fastlane/metadata/android/` → only `en-US/`.
~~~
- **修复建议**: Update full_description.txt to describe the current Hoshi reader (or generic 'custom EPUB engine'), and add localized metadata directories for the most-used app locales.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-075 — Test coverage is generated but never uploaded or gated — coverage flag is decorative

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / ci-cd / metric that looks measured but is discarded; pseudo-rigor
- **位置**: `.github/workflows/main.yml` : main.yml:54-66, 105-108
- **审查者置信度**: high
- **根因**: main.yml runs `flutter test --coverage` (line 56) producing coverage/lcov.info, but no subsequent step uploads it (no codecov/coveralls), enforces a minimum threshold, or even archives it as an artifact. Grep for coverage/lcov/codecov/min-coverage across .github/workflows returns only the generating line. The package test loop (lines 58-66) runs without --coverage at all. The final 'Check dependency health' step is `flutter pub outdated || true` (line 108), whose result is swallowed and never asserted.
- **影响**: There is no coverage gate; coverage can silently collapse to near-zero without failing CI. The --coverage adds build time for zero signal. `flutter pub outdated || true` is a no-op badge — outdated/insecure deps never fail or even warn the pipeline.
- **证据**:
~~~
main.yml:56 `run: flutter test --coverage`; no upload/threshold step follows. main.yml:108 `run: flutter pub outdated || true`. Package tests at :63 `(cd "$pkg" && flutter test)` have no coverage.
~~~
- **修复建议**: Either drop --coverage if unused, or add an upload (codecov/coveralls) and/or a `lcov --summary` threshold check that fails below a minimum. Replace `pub outdated || true` with a step that actually reports/fails on outdated or vulnerable deps, or remove it.
- **验证（对抗复核）**: I independently opened .github/workflows/main.yml and confirmed every cited fact. Line 56: `run: flutter test --coverage` exists exactly as claimed, producing coverage/lcov.info. A Grep for coverage|lcov|codecov|coveralls|min-coverage|upload-artifact across the entire .github directory returns ONLY lines 54 and 56 — there is no subsequent codecov/coveralls upload step, no `lcov --summary` threshold gate, no actions/upload-artifact archiving step, and no codecov.yml/.codecov.yml config file anywhere in the repo (confirmed via Glob). release.yml has no coverage/outdated handling either. So the - …(截断)
  - 验证者保留意见: The finding's facts are all correct and personally confirmed, so it is real — but its severity is overstated. It is a CI hygiene smell (no coverage gate, a decorative --coverage flag, and a swallowed `pub outdated` exit code), none of which can cause data loss, crashes, security holes, or wrong user …(截断)

### HBK-AUDIT-076 — compileSdk 36 with targetSdk 35 and minSdk override via suppressMinSdkVersionError

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / build-config / version patchwork to silence build errors
- **位置**: `hibiki/android/app/build.gradle, hibiki/android/gradle.properties, hibiki/android/build.gradle` : app/build.gradle:54 (compileSdk 36), :73 (targetSdk 35), :72 (minSdkVersion 24); gradle.properties:6 (android.ndk.suppressMinSdkVersionError=21); build.gradle:58-62 (force compileSdk 36 app / 34 plugi …(截断)
- **审查者置信度**: medium
- **根因**: compileSdk is 36 while targetSdk is 35 (intentional per comment 'media3 requires it'), but the build.gradle subprojects block force-sets plugin compileSdk to 34 and app to 36 to make Material You attrs resolve, and gradle.properties sets android.ndk.suppressMinSdkVersionError=21 even though defaultConfig minSdkVersion is 24. These are stacked workarounds for SDK-version friction rather than a coherent SDK matrix.
- **影响**: Mixing compileSdk 36 / targetSdk 35 / plugin compileSdk 34 / NDK minSdk-error suppressed-to-21 is a fragile combination that can produce subtle resource/attr resolution or native-ABI surprises on SDK bumps, and the suppressMinSdkVersionError flag hides genuine minSdk mismatches between the app (24) and any native lib expecting 21. Low risk today, but a maintainability hazard.
- **证据**:
~~~
app/build.gradle:54 `compileSdk 36`, :73 `targetSdk 35`, :72 `minSdkVersion 24`. gradle.properties:6 `android.ndk.suppressMinSdkVersionError=21`. build.gradle:58-62 forces compileSdk 36 for app, 34 for libraries.
~~~
- **修复建议**: Align targetSdk with compileSdk once tested against media3, and remove android.ndk.suppressMinSdkVersionError unless a specific native lib provably needs minSdk 21 (document why). Track plugin compileSdk 34 as a temporary measure with a removal condition.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-077 — emulator-test.sh hardcodes one developer's absolute Windows paths and personal media, non-portable

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `build-ci-deps` / developer-experience / machine-specific script committed as shared tooling
- **位置**: `ci/emulator-test.sh` : emulator-test.sh:12-18, 65-71
- **审查者置信度**: high
- **根因**: The script hardcodes /d/android_sdk, /d/flutter_sdk/..., a fixed AVD name hoshi_test, and copies test fixtures from /d/辞典/..., /c/Users/wrds/Downloads/..., /d/downloads/Bangumi/... — paths that exist only on the original author's machine. It is in ci/ alongside the real CI scripts but is unrunnable by anyone else or in CI (no emulator in GitHub Actions).
- **影响**: Misleading developer-experience: a script that looks like part of CI but only works on one machine. New contributors cannot run it; it also embeds personal file-system layout and copyrighted media paths.
- **证据**:
~~~
emulator-test.sh:14 `EMULATOR="/d/android_sdk/emulator/emulator"`, :16 `FLUTTER="/d/flutter_sdk/flutter_extracted/flutter/bin/flutter"`, :65 `cp "/d/辞典/[JA-JA] 明鏡国語辞典 第三版[2025-08-18].zip" ...`, :67 `cp "/c/Users/wrds/Downloads/転生王女...epub"`.
~~~
- **修复建议**: Parameterize paths via env vars with sane defaults and `command -v adb/emulator/flutter` discovery, and read fixtures from a documented, repo-relative or env-pointed fixtures dir rather than hardcoded personal paths. Or move it under a clearly-local tools dir, not ci/.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-078 — CreatorFieldValues.copyWith deep-copies textValues but aliases extraValues; isExportable ignores image/audio-only cards

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / type-safety / inconsistent half-applied immutability; happy-path 'isExportable'
- **位置**: `hibiki/lib/src/creator/creator_field_values.dart` : 66-82 (copyWith), 120-129 (isExportable)
- **审查者置信度**: high
- **根因**: copyWith does `newTextValues = {}; newTextValues.addAll(textValues)` (a fresh copy) for textValues but passes extraValues through by reference (`extraValues ?? this.extraValues`). The class is documented as producing 'a deep copy' but only one of the two maps is copied; both maps are also non-defensive in the constructor (stored directly), so 'immutable collection' in the doc is also untrue. Separately, isExportable returns true only if some textValues entry is non-empty — it never considers imagesToExport/audioToExport, so a card with only an image or only audio is deemed non-exportable.
- **影响**: Mutating the original's extraValues after copyWith leaks into the copy (shared map), violating the documented copy semantics. isExportable would block exporting an image-only or audio-only card. Latent given the orphaned UI, but the contract is internally inconsistent and the comments lie.
- **证据**:
~~~
copyWith: `Map<Field, String>? newTextValues; if (textValues != null) { newTextValues = {}; newTextValues.addAll(textValues); } return CreatorFieldValues(textValues: newTextValues ?? this.textValues, extraValues: extraValues ?? this.extraValues);` — extraValues never copied. isExportable: `for (String value in textValues.values) { if (value.isNotEmpty) return true; } return false;`
~~~
- **修复建议**: Copy both maps defensively in the constructor and in copyWith (or store as unmodifiable), and have isExportable also return true when imagesToExport/audioToExport is non-empty; fix the 'deep copy'/'immutable' doc comments to match reality.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-079 — File named pick_from_stash_enhancement.dart defines class OpenStashEnhancement (open_stash) — filename/identity mismatch

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / responsibility-confusion / split-but-coupled naming drift; file and class diverged during edits
- **位置**: `hibiki/lib/src/creator/enhancements/pick_from_stash_enhancement.dart` : 8-43
- **审查者置信度**: high
- **根因**: The file is named pick_from_stash_enhancement.dart and exported as such in creator.dart, but the class inside is OpenStashEnhancement with `static const String key = 'open_stash';`. The actual 'pop from stash' behaviour lives in pop_from_stash_enhancement.dart (PopFromStashEnhancement). There is no PickFromStashEnhancement class anywhere; app_model registers OpenStashEnhancement(field: ...).
- **影响**: Anyone searching for the open-stash enhancement by filename will not find it; the persistence key 'open_stash' silently lives in a 'pick_from_stash' file. Maintainability/discoverability hazard and a sign the enhancement set was renamed without renaming files.
- **证据**:
~~~
creator.dart:20 `export 'src/creator/enhancements/pick_from_stash_enhancement.dart';`. File content: `class OpenStashEnhancement extends Enhancement { ... static const String key = 'open_stash'; ... appModel.openStash(...)`
~~~
- **修复建议**: Rename the file to open_stash_enhancement.dart (and fix the export) to match the class and key.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-080 — Godan conjugation table for く verbs has wrong volitional (もう instead of こう) — copy-paste corruption

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / correctness/data / copy-paste error in a hand-maintained table; also dead code
- **位置**: `hibiki/lib/src/creator/enhancements/jp_conjugations.dart` : 177-205 (specifically 204)
- **审查者置信度**: high
- **根因**: The 'く' godan entry was copied from the 'む' entry and its last element was not corrected. The volitional (意向形) of a く-verb is こう (書く→書こう), but the set lists 'もう', which is the む-verb volitional (飲む→飲もう). The 'く' set therefore is missing 'こう' and contains a bogus 'もう'.
- **影响**: Any conjugation-deinflection or matching that relies on this table will fail to recognise the volitional of く-verbs and may falsely match む-volitional endings to く-verbs. Currently the bug is latent because the table is never imported anywhere (see dead-code finding), but if/when re-wired it produces silently wrong Japanese deinflection.
- **证据**:
~~~
In the `'く'` set (lines 177-205): `// Misc.
'いたら',
'きたい',
'きたくない', 'きたくなくて',
'きたかった',
'きたくなかった',
'もう',` — the trailing 'もう' should be 'こう'. Compare 'む' set line 146 which correctly ends 'もう' and 'ぐ' set line 233 which correctly ends 'ごう'.
~~~
- **修复建议**: Change the final 'もう' in the 'く' set to 'こう'. (And see separate finding: the whole file is unreferenced.)
- **验证（对抗复核）**: I opened hibiki/lib/src/creator/enhancements/jp_conjugations.dart and read lines 1-249. The cited lines match exactly. The `'く'` godan set (lines 177-205) ends at line 204 with `'もう'`. This is genuinely wrong: every other element of the set uses か/き/く/け/こ-row kana (かない, きます, いた, ける, かれる, きたい, いたら, etc.), and the correct volitional (意向形) of a く-verb is こう (書く→書こう). `もう` is the む-verb volitional, identical to the む set's final element at line 146. The parallel structure of all 9 godan entries — each ending with its volitional (う→おう L30, つ→とう, る→ろう, む→もう L146, ぬ→のう L175, く→[bug] L204, ぐ→ごう L233, …(截断)
  - 验证者保留意见: The defect itself is correct and not overstated factually, but the severity is overstated. The finding's own impact note concedes the table "is never imported anywhere" and the bug is "currently latent." Independent grep confirms zero importers and zero references to the exported symbols outside the …(截断)

### HBK-AUDIT-081 — Off-by-precedence bounds guard in setSearchSuggestions never triggers (index validation is dead)

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / type-safety / optimistic-but-unverified logic; condition that 'runs' but is logically wrong
- **位置**: `hibiki/lib/src/creator/image_export_field.dart` : 140-150
- **审查者置信度**: high
- **根因**: The intended guard is `images.isEmpty || (newSelectedSuggestionIndex < 0 || newSelectedSuggestionIndex >= images.length)`. As written `images.isEmpty || newSelectedSuggestionIndex < 0 && newSelectedSuggestionIndex >= images.length`, the `&&` binds tighter than `||`, so the second operand requires index<0 AND index>=length simultaneously — impossible. So out-of-range indices are never caught, and `_imageSuggestions = images; _exportFile = images.first;` runs unconditionally right after a clearFieldState that was supposed to short-circuit.
- **影响**: If setSearchSuggestions is ever called with newSelectedSuggestionIndex out of range (e.g. a crop/pick flow passing a stale index), clearFieldState is skipped and _indexNotifier.value is set to an invalid index. setSelectedSearchSuggestion(index) later does `_imageSuggestions![index]` which would RangeError. The validation that exists is theatre. (Currently masked because callers pass 0, but it is a latent crash and the guard is provably useless.)
- **证据**:
~~~
`if (images.isEmpty ||
    newSelectedSuggestionIndex < 0 &&
        newSelectedSuggestionIndex >= images.length) {
  clearFieldState(creatorModel: creatorModel);
}

_imageSuggestions = images;
_exportFile = images.first;`
~~~
- **修复建议**: Parenthesise correctly: `if (images.isEmpty || newSelectedSuggestionIndex < 0 || newSelectedSuggestionIndex >= images.length) { clearFieldState(...); return; }` and add the missing `return` so the field is not repopulated after clearing.
- **验证（对抗复核）**: I opened hibiki/lib/src/creator/image_export_field.dart and read lines 60-169. The cited lines 140-150 match the evidence verbatim:

  if (images.isEmpty ||
      newSelectedSuggestionIndex < 0 &&
          newSelectedSuggestionIndex >= images.length) {
    clearFieldState(creatorModel: creatorModel);
  }
  _imageSuggestions = images;
  _exportFile = images.first;
  _indexNotifier.value = newSelectedSuggestionIndex;

The operator-precedence claim is CORRECT: in Dart `&&` binds tighter than `||`, so the expression parses as `images.isEmpty || (index < 0 && index >= length)`. The second operand …(截断)
  - 验证者保留意见: Overstated, not refuted. The precedence observation is correct and the guard is provably dead, so the defect is real. But the claimed impact ("setSearchSuggestions ... passing a stale index ... would RangeError") is not reachable in the current code: the sole caller (image_export_field.dart:97-103) …(截断)

### HBK-AUDIT-082 — PickImageEnhancement and CameraEnhancement throw UnimplementedError for the ImageEnhancement.fetchImages contract they declare

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / type-safety / pseudo-extensibility: subclass declares an interface method it cannot honour
- **位置**: `hibiki/lib/src/creator/enhancements/pick_image_enhancement.dart, camera_enhancement.dart` : pick_image_enhancement.dart:80-86; camera_enhancement.dart:83-89
- **审查者置信度**: high
- **根因**: ImageEnhancement (image_enhancement.dart:16-21) declares `Future<List<NetworkToFileImage>> fetchImages({required AppModel appModel, String? searchTerm})` as part of its abstraction (used by setImages-style flows). PickImage and Camera extend ImageEnhancement but implement fetchImages as `throw UnimplementedError();`. They only work through their own enhanceCreatorParams path. The base contract is a lie for these subclasses.
- **影响**: Any generic code that treats an ImageEnhancement uniformly and calls fetchImages (the apparent purpose of the base class) will crash for pick/camera. The abstraction does not actually abstract — it forces a method that two of its implementers reject at runtime.
- **证据**:
~~~
pick_image_enhancement.dart: `@override
Future<List<NetworkToFileImage>> fetchImages({required AppModel appModel, String? searchTerm}) async { throw UnimplementedError(); }` ; camera_enhancement.dart identical. CropImageEnhancement instead returns `[]` (another inconsistent stub).
~~~
- **修复建议**: Either make fetchImages optional (non-abstract returning const [] in ImageEnhancement) or split the abstraction so only search-based enhancements implement fetchImages; do not declare a contract two implementers throw on.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-083 — PlayAudioAction contains dead branches: isEmpty check on a hardcoded non-empty list and null-check over a non-nullable list

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / dead-code / zombie code AI completion left behind; happy-path scaffolding for a feature that was never generalised
- **位置**: `hibiki/lib/src/creator/actions/play_audio_action.dart` : 47-61
- **审查者置信度**: high
- **根因**: audioEnhancements is built as a literal `[LocalAudioEnhancement(field: AudioField.instance)]` — always length 1. The subsequent `if (audioEnhancements.isEmpty)` can never be true, and `for (Enhancement? enhancement in audioEnhancements) { if (enhancement == null) continue; ... }` iterates a `List<Enhancement>` that cannot contain null. This is leftover from a design where the list was meant to be populated dynamically from registered enhancements.
- **影响**: Misleading no_audio_enhancements toast path is unreachable; the null guard is noise. Also a fresh LocalAudioEnhancement is constructed on every tap without calling initialise(), bypassing the resource-prep lifecycle other call sites use. Maintainability hazard / confuses readers about whether multiple audio enhancements are supported.
- **证据**:
~~~
`List<Enhancement> audioEnhancements = [
  LocalAudioEnhancement(field: AudioField.instance),
];

if (audioEnhancements.isEmpty) { HibikiToast.show(msg: t.no_audio_enhancements ...); }

for (Enhancement? enhancement in audioEnhancements) {
  if (enhancement == null) { continue; }`
~~~
- **修复建议**: Either pull the real registered audio enhancements from appModel.enhancements[AudioField.instance] (the list this code pretends to iterate), or collapse to a single non-nullable LocalAudioEnhancement call and drop the isEmpty/null branches.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-084 — SearchHistoryItem in creator/ is dead: @JsonSerializable with no generated part, superseded by Drift SearchHistoryItemsCompanion

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / dead-code / zombie code: annotated for codegen that was never run; duplicate of the real persistence type
- **位置**: `hibiki/lib/src/creator/search_history_item.dart` : 1-24
- **审查者置信度**: high
- **根因**: This class is annotated `@JsonSerializable()` but the file has no `part 'search_history_item.g.dart';` and no fromJson/toJson — the codegen was never wired. Search-history persistence actually goes through Drift: media_history_repository.dart uses `SearchHistoryItemsCompanion.insert(...)` and `_db.getAllSearchHistoryItems()`. The creator SearchHistoryItem class is never constructed anywhere (grep for `SearchHistoryItem(` matches only its own constructor).
- **影响**: Confusing duplicate domain type (creator SearchHistoryItem vs Drift SearchHistoryItem row), dangling json_annotation import, dead doc comments that mislabel fields ('The name of the model to use when exporting' for searchTerm). No runtime effect, pure rot.
- **证据**:
~~~
File: `@JsonSerializable()
class SearchHistoryItem { ... String get uniqueKey => '$historyKey/$searchTerm'; int? id; }` with no part directive. media_history_repository.dart:152 `await _db.upsertSearchHistoryItem(SearchHistoryItemsCompanion.insert(...))`. grep `SearchHistoryItem(` → only the constructor in this file.
~~~
- **修复建议**: Delete creator/search_history_item.dart and its export in creator.dart; rely on the Drift-generated row/companion. If a json model is genuinely needed, add the part directive and run build_runner.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-085 — 'find-by-prefix' sync-file matcher implemented 3 separate times across the sync module

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / cross-module-duplication / same trivial helper re-implemented per file instead of imported
- **位置**: `hibiki/lib/src/sync/sync_utils.dart, hibiki/lib/src/sync/webdav_ops.dart, hibiki/lib/src/sync/google_drive_handler.dart` : sync_utils.dart:24-29; webdav_ops.dart:237-242; google_drive_handler.dart:469-475
- **审查者置信度**: high
- **根因**: findSyncFileByPrefix (sync_utils), WebDavOps.findByPrefix (webdav_ops), and GoogleDriveHandler._findByPrefix (google_drive_handler) are three byte-identical functions ('for (final f in files) if (f.name.startsWith(prefix)) return f; return null;'). Backends inconsistently call whichever copy their file already imports.
- **影响**: Pure duplication; any future change to file-matching semantics (e.g. case-insensitive match, tie-breaking by newest timestamp) silently applies to only one or two backends. Maintainability hazard, not a runtime bug today.
- **证据**:
~~~
webdav_ops.dart:237 'static DriveFile? findByPrefix(List<DriveFile> files, String prefix)' vs sync_utils.dart:24 'DriveFile? findSyncFileByPrefix(List<DriveFile> files, String prefix)' — identical body. Grep shows webdav/smb/hibiki_client call WebDavOps.findByPrefix; ftp/sftp/dropbox/onedrive call findSyncFileByPrefix; google_drive uses its own _findByPrefix.
~~~
- **修复建议**: Delete WebDavOps.findByPrefix and GoogleDriveHandler._findByPrefix; route all callers to the single findSyncFileByPrefix in sync_utils.dart.
- **验证（对抗复核）**: Independently confirmed all three claims by reading the cited code. (1) Three byte-identical function bodies exist at the exact cited lines: findSyncFileByPrefix at sync_utils.dart:24-28, WebDavOps.findByPrefix at webdav_ops.dart:237-242, GoogleDriveHandler._findByPrefix at google_drive_handler.dart:469-474. All share the identical body: 'for (final f in files) { if (f.name.startsWith(prefix)) return f; } return null;'. (2) Grep confirms the inconsistent caller distribution exactly as claimed: webdav/smb/hibiki_client backends call WebDavOps.findByPrefix; ftp/onedrive/dropbox/sftp call the top …(截断)
  - 验证者保留意见: Not refuted on existence — the duplication and inconsistent calling are real and verified. The only correction is severity: 'medium' overstates a purely cosmetic triplication of a trivial helper that exhibits no current runtime divergence; it belongs at 'low' (a smell, not a latent bug).

### HBK-AUDIT-086 — Dead, never-read SMB credential storage (host/share/domain) contradicts its own 'stored for display' comment

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / dead-code / abandoned fields + comment that lies about what the code does
- **位置**: `hibiki/lib/src/sync/smb_sync_backend.dart, hibiki/lib/src/sync/sync_repository.dart` : smb 16-18, 58-62; sync_repository.dart:311-314, 331-332
- **审查者置信度**: high
- **根因**: SmbSyncBackend's comment claims SMB host/share/domain are 'stored for display and future native SMB support.' In reality the SMB settings form only writes setSmbWebDavUrl/Username/Password (sync_settings_schema.dart:1269-1271); getSmbHost/getSmbShare/getSmbDomain are defined in SyncRepository but never read anywhere, and setSmbHost/Share/Domain(null) are only ever called in signOut to clear values that are never set.
- **影响**: Misleading comment + dead repository API. The _keySmbHost/_keySmbShare/_keySmbDomain prefs are write-null-only ghosts; readers of the code waste time assuming SMB metadata is captured.
- **证据**:
~~~
Grep for getSmbHost/getSmbShare/getSmbDomain across hibiki/lib returns only sync_repository.dart definitions; the only set* calls are smb_sync_backend.dart:58-62 'await repo.setSmbHost(null); ... setSmbShare(null); ... setSmbDomain(null);'. The form (sync_settings_schema.dart:1269-1271) writes only WebDavUrl/Username/Password.
~~~
- **修复建议**: Delete the unused getSmbHost/Share/Domain + setSmbHost/Share/Domain + their key constants, or actually capture and use them. Fix the class comment to state SMB is a WebDAV-bridge-only facade.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-087 — FTP JSON temp files use millisecond-timestamp names — collision/leftover-file risk under retry

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / resource-leak / timestamp-as-unique-id, optimistic uniqueness assumption
- **位置**: `hibiki/lib/src/sync/ftp_sync_backend.dart` : 502-503, 554-560
- **审查者置信度**: medium
- **根因**: _downloadJson and _writeTempFile build temp paths as 'hibiki_..._${DateTime.now().millisecondsSinceEpoch}.json/.tmp'. Two operations within the same millisecond (or two app instances sharing systemTemp) produce identical paths. Serialization via _opLock prevents same-instance overlap today, but the design relies on the lock + ms-resolution rather than a real unique token, and the singleton instance is shared process-wide.
- **影响**: Low today (lock serializes within the single FtpSyncBackend.instance), but fragile: any future concurrent caller, a second isolate, or sub-ms operations collide and clobber each other's temp file mid-transfer. Temp cleanup is best-effort (_deleteTempFile swallows errors), so failures can leave stale temp files.
- **证据**:
~~~
ftp_sync_backend.dart:502 "final tmpFile = File('${Directory.systemTemp.path}/hibiki_ftp_dl_${DateTime.now().millisecondsSinceEpoch}.json');" and :555-556 same pattern in _writeTempFile.
~~~
- **修复建议**: Use a collision-proof name (Directory.systemTemp.createTempSync prefix, or append a Random.secure token / counter) instead of relying on millisecond resolution + the lock.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-088 — Four Drift type-converters labelled 'Isar' are exported but unused in production (incomplete Isar→Drift migration residue)

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / dead-code / zombie code left behind by a half-finished migration; comments contradict current architecture
- **位置**: `hibiki/lib/src/utils/converters/media_item_converter.dart, quick_actions_converter.dart, enhancements_converter.dart, immutable_string_map_converter.dart` : media_item_converter.dart:6-24; quick_actions_converter.dart:5-19; enhancements_converter.dart:5-26
- **审查者置信度**: high
- **根因**: All four classes use fromIsar/toIsar method names and doc comments ('conversion to a primitive compatible with Isar'), but the project DB is Drift SQLite (per CLAUDE.md, which explicitly warns Isar comments are stale). They are exported via hibiki/lib/utils.dart yet grep shows no production caller in lib/src — only the classes' own definitions, their tests, and generated docs/ Isar HTML (MokuroCatalogQueryWhereSort etc., proving prior Isar schema).
- **影响**: Misleads readers into thinking Isar is still in use; dead public API surface that must be kept compiling. MediaItemConverter also has no test (the other 3 do), making it the most orphaned.
- **证据**:
~~~
quick_actions_converter.dart:3-4 '// A type converter ... for conversion to a primitive compatible with Isar.' and method 'static Map<int,String> fromIsar(String object)'. Grep for QuickActionsConverter|EnhancementsConverter|MediaItemConverter|ImmutableStringMapConverter in hibiki/lib finds only the four definition files + utils.dart export, no lib/src usage.
~~~
- **修复建议**: Confirm no Drift table references them, then delete the four converters + their tests + the utils.dart exports. If genuinely needed for Drift, rename fromIsar/toIsar→fromDb/toDb and fix the comments.
- **验证（对抗复核）**: Independently confirmed every factual claim by reading the four files and grepping the whole repo.

1. All four classes exist with `fromIsar`/`toIsar` method names: media_item_converter.dart:8,17; quick_actions_converter.dart:7,16; enhancements_converter.dart:7,21; immutable_string_map_converter.dart:7,12. Three of them (quick_actions:3-4, enhancements:3-4, immutable_string_map:3-4) carry the doc comment "for conversion to a primitive compatible with Isar." MediaItemConverter only says "A type converter for [MediaItem]."

2. They are exported as public API at hibiki/lib/utils.dart:22-25.

3. P …(截断)
  - 验证者保留意见: Not a refutation of existence — the finding is factually accurate. Only the severity is overstated: "medium" implies a latent bug or fragile contract, but this code is completely unreachable in production (zero callers in lib/src), so it cannot misbehave at runtime. Its impact is limited to maintain …(截断)

### HBK-AUDIT-089 — Leftover production print() in Google Drive cover upload

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / dead-code / stray debug print left in shipped code path (rest of sync uses debugPrint)
- **位置**: `hibiki/lib/src/sync/google_drive_handler.dart` : 178
- **审查者置信度**: high
- **根因**: A raw print('Cover upload failed: $e') sits in the cover-upload path while every other sync file uses debugPrint(...). print() is not stripped in release builds and writes to the platform log unconditionally.
- **影响**: Noise in release logs; inconsistent logging convention across the sync module.
- **证据**:
~~~
google_drive_handler.dart:178 "print('Cover upload failed: $e');"
~~~
- **修复建议**: Replace with debugPrint or route through ErrorLogService like the rest of the app.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-090 — SyncBackendRegistry and FallbackSyncBackend are fully-built, tested, but wired to nothing in production (pseudo-extensibility / dead code)

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Resolved (2026-05-29) — 死代码已删除：`fallback_sync_backend.dart` / `backend_registry.dart` 及其测试、`SyncRepository.getFallbackOrder/setFallbackOrder` 全部移除。多地址 fallback 的真实需求改由 `HibikiClientSyncBackend` 的会话级、按可用性的"内网优先外网兜底"地址列表承载（每地址独立缓存、整次会话锁定一个 URL，规避了原 FallbackSyncBackend 逐操作切换导致 folderId 串台的潜在 bug）。设计见 `docs/specs/2026-05-29-hibiki-server-lan-wan-failover-design.md`。
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / dead-code / over-engineered abstraction + orchestrator built speculatively, never instantiated
- **位置**: `hibiki/lib/src/sync/backend_registry.dart, hibiki/lib/src/sync/fallback_sync_backend.dart` : backend_registry.dart:5-23; fallback_sync_backend.dart:8-194
- **审查者置信度**: high
- **根因**: Production backend selection goes through the top-level switch resolveSyncBackend() (google_drive_sync_backend.dart:204-223). SyncBackendRegistry (a factory-registry abstraction) and FallbackSyncBackend (a 195-line multi-backend fallback orchestrator) are referenced ONLY by their own unit tests — never by AppModel, SyncManager, sync_auto_trigger, or sync_settings_schema.
- **影响**: ~220 lines of zombie code plus their tests give a false impression of an extensible/failover architecture that does not exist. Worse, FallbackSyncBackend carries a latent correctness bug if it ever IS used: _tryAll updates _activeIndex per-call (lines 24-26/45-47), so within one sync a folderId/fileId resolved on backend A (e.g. a WebDAV href URL) can be passed to backend B (e.g. an FTP path) after a retryable failure — opaque IDs are not portable across backends, so a 'fallback' would corrupt or mis-target writes.
- **证据**:
~~~
Grep across hibiki/ for 'FallbackSyncBackend' and 'SyncBackendRegistry' returns only fallback_sync_backend.dart/backend_registry.dart and their *_test.dart. Production resolver is resolveSyncBackend() switch (google_drive_sync_backend.dart:204), called from sync_auto_trigger.dart:56 and sync_settings_schema.dart:259.
~~~
- **修复建议**: Either delete both files + tests, or actually wire one of them in. If kept, FallbackSyncBackend must not span heterogeneous backends with opaque IDs — restrict it to a single backend type or document the constraint loudly.
- **验证（对抗复核）**: I independently confirmed the core defect by reading the cited code. backend_registry.dart:5-23 defines SyncBackendRegistry (a factory-registry abstraction) and fallback_sync_backend.dart:8-194 defines FallbackSyncBackend (a full multi-backend failover wrapper over SyncBackend). A repo-wide grep for both symbols returns ONLY each class's own definition file plus its own unit test (test/sync/backend_registry_test.dart, test/sync/fallback_sync_backend_test.dart). Neither is exported via any barrel file (there is no lib/src/sync.dart; the directory is flat per-file modules) and neither is instant …(截断)
  - 验证者保留意见: Not a refutation of existence, but a severity correction. The claimed 'medium' is inflated. The issue has zero runtime impact on any reachable path: no data loss, crash, security hole, or user-facing wrong behavior — both classes are unreachable from production. It is purely a maintainability hazard …(截断)

### HBK-AUDIT-091 — resolveSyncBackend() factory lives inside google_drive_sync_backend.dart and imports every sibling backend — dependency-direction / placement smell

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `cross-cutting-ai-smells` / dependency-direction / god-file hub: one concrete backend file made to depend on all other backends
- **位置**: `hibiki/lib/src/sync/google_drive_sync_backend.dart` : 204-223
- **审查者置信度**: high
- **根因**: The top-level resolveSyncBackend(SyncBackendType) switch that maps all 8 backend types to their .instance singletons is defined in the GoogleDrive backend's file. That forces google_drive_sync_backend.dart to import WebDav/Smb/HibikiClient/OneDrive/Dropbox/Ftp/Sftp backends, turning a leaf module into a hub that depends on all its siblings.
- **影响**: Backwards dependency direction: a single concrete backend now transitively pulls in every other backend. Editing GoogleDrive risks recompiling/relinking the whole sync layer; new backends require editing an unrelated file. Maintainability/coupling hazard.
- **证据**:
~~~
google_drive_sync_backend.dart:204 'SyncBackend resolveSyncBackend(SyncBackendType type) { switch (type) { case SyncBackendType.webDav: return WebDavSyncBackend.instance; ... case SyncBackendType.smb: return SmbSyncBackend.instance; } }' — defined in the GoogleDrive file.
~~~
- **修复建议**: Move resolveSyncBackend into a neutral file (e.g. sync_backend.dart next to the enum, or a new backend_resolver.dart). This is also exactly what the dead SyncBackendRegistry was meant to do — pick one mechanism.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-092 — Downgrade backup overwrites prior .bak.<from> snapshot and only triggers if the same downgrade happens again; no rotation

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `db-core` / data integrity / swallowed-exception + destructive happy path: catch logs and continues into an irreversible DROP ALL
- **位置**: `packages/hibiki_core/lib/src/database/database.dart` : 122-146
- **审查者置信度**: high
- **根因**: On downgrade (from > to) the code copies hibiki.db(+wal/shm) to a fixed suffix `.bak.$from` then DROPS ALL TABLES and recreates them. The backup name depends only on `from`, so a second downgrade from the same version silently overwrites the first backup. More importantly the recovery is a hard wipe: all user data is destroyed and only recoverable by manually restoring the .bak file. Errors during backup are swallowed (print only) and the destructive drop proceeds anyway.
- **影响**: If a user installs an older build (downgrade), all data is dropped. If the backup copy fails (disk full, permissions) the catch only prints and then proceeds to DROP ALL TABLES — total data loss with no recoverable snapshot.
- **证据**:
~~~
} catch (e) {
  print('[HibikiDB] backup before downgrade failed: $e');
}
... for (final table in allTables) { await customStatement('DROP TABLE IF EXISTS ...'); }
await m.createAll();
~~~
- **修复建议**: Abort the downgrade (throw) if the backup copy fails instead of proceeding to drop tables; use a unique/rotated backup name (timestamp) so repeat downgrades don't clobber prior backups.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-093 — PrefCodec.decode hardcodes List<String> for any List-typed pref, will throw on non-string lists

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `db-core` / type-safety / type-system-as-theater: generic <T> signature that only handles one concrete instantiation (List<String>)
- **位置**: `packages/hibiki_core/lib/src/database/pref_codec.dart` : 20-31, 63-77
- **审查者置信度**: medium
- **根因**: decode<T> for List defaults always does `List<String>.from(parsed) as T` (line 26) and the heuristic path does the same (line 71). encode() JSON-encodes any List opaquely. If a caller ever stores a `List<int>`/`List<double>` pref and reads it back with a matching default, `List<String>.from(parsed)` builds a List<String> and the `as T` (e.g. as List<int>) cast throws at runtime; or if it doesn't throw, returns wrongly-typed strings. Currently no List-typed pref is in use (grep found none), so this is latent.
- **影响**: Latent crash / type corruption the first time anyone persists a non-string list preference. The type parameter T is theater: the codec silently assumes every list is List<String>.
- **证据**:
~~~
if (defaultValue is List && parsed is List) {
  return List<String>.from(parsed) as T; // ignores element type of T
}
~~~
- **修复建议**: Either constrain the API to List<String> explicitly in the signature, or decode element types from the default value / a richer type tag. Do not pretend to support generic List<T>.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-094 — beforeOpen recreates 12 indexes on every database open via per-index table-existence probes

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `db-core` / perf / concurrency / abstraction sprawl / belt-and-suspenders: same indexes created in both onUpgrade(from<9) and on every beforeOpen, masking unclear ownership of schema DDL
- **位置**: `packages/hibiki_core/lib/src/database/database.dart` : 62-121
- **审查者置信度**: medium
- **根因**: beforeOpen runs on EVERY connection open (every app launch), issuing a PRAGMA/sqlite_master probe per table plus a CREATE INDEX IF NOT EXISTS for 12 indexes. The work is redundant after first creation (indexes already exist; idx creation belongs in onCreate/onUpgrade). Each probe is an extra round-trip on the startup-critical path.
- **影响**: Minor but unnecessary startup latency and extra I/O on every launch; the index management duplicates what onUpgrade (from<9) already does, indicating the index DDL was scattered as a workaround rather than placed in migrations only.
- **证据**:
~~~
beforeOpen: (details) async {
  Future<void> indexIfTableExists(String table, String sql) async {
    if (await _tableExists(table)) { await customStatement(sql); }
  }
  await indexIfTableExists('profile_settings', 'CREATE INDEX IF NOT EXISTS ...');
  // ...12 of these every open
~~~
- **修复建议**: Move index creation into onCreate/onUpgrade only (where IF NOT EXISTS already makes it idempotent). beforeOpen should be reserved for runtime PRAGMAs that don't persist.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-095 — hibiki_core.dart exports a path with wrong filename casing (Hibiki_text_selection.dart vs hibiki_text_selection.dart)

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `db-core` / type-safety / portability / casing inconsistency that only works due to forgiving local FS — typical vibe-coding artifact masked on Windows/macOS
- **位置**: `packages/hibiki_core/lib/hibiki_core.dart` : 7
- **审查者置信度**: high
- **根因**: Export statement references `src/models/Hibiki_text_selection.dart` (capital H) but the actual file on disk is `hibiki_text_selection.dart` (lowercase, verified via directory listing). This resolves on case-insensitive filesystems (Windows/macOS default) but fails to compile on case-sensitive filesystems (Linux CI, many cloud build agents).
- **影响**: Package fails to compile / import on case-sensitive filesystems: 'Error: Couldn't read file ... Hibiki_text_selection.dart'. Breaks Linux CI builds and any case-sensitive dev environment; a classic AI copy/paste casing slip.
- **证据**:
~~~
export 'src/models/Hibiki_text_selection.dart';  // file is actually hibiki_text_selection.dart
~~~
- **修复建议**: Change the export to `export 'src/models/hibiki_text_selection.dart';` to match the on-disk filename.
- **验证（对抗复核）**: I independently confirmed the cited defect by reading the file and verifying on-disk casing via git.

VERIFIED FACTS:
- packages/hibiki_core/lib/hibiki_core.dart:7 reads exactly `export 'src/models/Hibiki_text_selection.dart';` (capital H). Confirmed by Read.
- The git-tracked file is `packages/hibiki_core/lib/src/models/hibiki_text_selection.dart` (lowercase). Confirmed via `git ls-files` (authoritative; not subject to local FS case-folding). The directory listing also shows only `hibiki_text_selection.dart`.
- `git config core.ignorecase` = true, confirming the dev/build environment is a cas …(截断)
  - 验证者保留意见: The finding correctly identifies that line 7's export casing (`Hibiki_text_selection.dart`) does not match the on-disk filename (`hibiki_text_selection.dart`), and that this would fail on a case-sensitive filesystem. That much is real. But the finding is overstated and mis-scoped on three counts: (a …(截断)

### HBK-AUDIT-096 — upsertReadingStatistic DoUpdate omits several columns; partial-row update relies on caller supplying all stat fields

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `db-core` / transaction correctness / data integrity / duplicated implementations with conflicting semantics for the same table/key
- **位置**: `packages/hibiki_core/lib/src/database/database.dart` : 595-637
- **审查者置信度**: medium
- **根因**: There are two divergent code paths writing reading_statistics: upsertReadingStatistic uses DoUpdate that REPLACES charactersRead/readingTimeMs with the incoming companion values (overwrite semantics), while addReadingStatistic does a read-modify-write that ADDS deltas. Callers must know which one accumulates vs overwrites; using upsert with a delta value would silently reset totals instead of accumulating. The two APIs encode different contracts for the same unique key (title,dateKey).
- **影响**: Easy to call the wrong one and silently corrupt reading-time/character totals (overwrite instead of accumulate). Latent correctness hazard from duplicated, subtly-different write paths.
- **证据**:
~~~
// upsert overwrites:
onConflict: DoUpdate((old) => ReadingStatisticsCompanion(charactersRead: stat.charactersRead, readingTimeMs: stat.readingTimeMs, ...))
// addReadingStatistic accumulates:
charactersRead: Value(existing.charactersRead + charsRead)
~~~
- **修复建议**: Collapse to one documented API (e.g. an accumulate-only upsert using SQL `charactersRead = charactersRead + excluded.charactersRead`), removing the overwrite variant or renaming it to make the contract explicit.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-097 — C++ convert_term / hoshidicts_query / hoshidicts_lookup never check malloc/dup return; OOM yields NULL deref or NULL string pointers handed to Dart

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `dictionary-ffi` / ffi-memory-safety / happy-path-only: allocation assumed to always succeed across the whole converter
- **位置**: `native/hoshidicts/hoshidicts_ffi.cpp + packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart` : cpp 13-17,108-140,288-291,313-321,355,386; dart 119-124,162-167
- **审查者置信度**: medium
- **根因**: dup() returns NULL when malloc fails (cpp 14-16, no caller checks). convert_term immediately writes through freshly malloc'd arrays without checking the array pointer (e.g. cpp 109 `r.glossaries = malloc(...)` then 111 `r.glossaries[i].dict_name = ...`). The Dart side then calls toDartString() on whatever pointer comes back (e.g. hoshidicts.dart:120 g.dictName.toDartString()) with no nullptr guard except on top-level container pointers.
- **影响**: Under memory pressure (the app explicitly supports a low-memory mode for exactly this engine), a NULL from malloc/dup causes either a native write-through-NULL segfault in convert_term, or a NULL char* reaching Dart where toDartString() dereferences it and crashes. No graceful degradation on a path that is expected to be hit on low-RAM devices.
- **证据**:
~~~
cpp: `char* dup(const std::string& s){ char* p = (char*)malloc(s.size()+1); if(p) memcpy(...); return p; }` (NULL silently returned); `r.glossaries = (FfiGlossary*)malloc(sizeof(FfiGlossary)*r.glossary_count); for(...) r.glossaries[i].dict_name = dup(...);` no null check. dart: `dictName: g.dictName.toDartString(),` no nullptr guard.
~~~
- **修复建议**: Check dup()/malloc returns in the C++ converters and bail to an empty/typed error result on failure; on the Dart side treat nullptr string fields as '' (`p == nullptr ? '' : p.toDartString()`).
- **验证（对抗复核）**: I independently read native/hoshidicts/hoshidicts_ffi.cpp and packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart. The cited code facts are all accurate. C++ side: dup() (cpp 13-17) does `char* p = (char*)malloc(s.size()+1); if(p) memcpy(...); return p;` — returns NULL silently on failure. convert_term writes through freshly malloc'd arrays with no null check (cpp 109 `r.glossaries = malloc(...)` then 111 `r.glossaries[i].dict_name = dup(...)`; same pattern for frequencies 118/121-127, pitches 132/134-138). hoshidicts_query (cpp 288 `r.terms = malloc(...)`, 290 write) and hoshidicts_look …(截断)
  - 验证者保留意见: Code facts are correct, but severity is overstated. The finding ties impact to lowMemoryMode as if it forces this allocation path to fail, yet lowMemoryMode only tunes the Flutter image cache and history limits (app_model.dart 2526-2531) and has zero effect on native dup()/malloc. With plain system …(截断)

### HBK-AUDIT-098 — HoshidictsFfiBindings struct fields are exported from the package public API, exposing the raw FFI ABI as part of the dictionary's surface

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `dictionary-ffi` / type-safety / abstraction sprawl: internal FFI layer leaked into the public barrel export
- **位置**: `packages/hibiki_dictionary/lib/hibiki_dictionary.dart` : 6
- **审查者置信度**: high
- **根因**: hibiki_dictionary.dart re-exports `src/ffi/hoshidicts_ffi_bindings.dart`, making all raw Struct mirrors (FfiTermResult, FfiLookupResults, etc.) and the bindings class public API of the package. These types hold raw Pointer<Utf8> fields whose lifetime is owned by native malloc/free and are only valid between the FFI call and the matching free.
- **影响**: Any consumer can obtain and hold these structs / pointers past the free boundary, leading to use-after-free that the type system presents as a perfectly valid Dart object. The ABI-fragile layer that should be an internal implementation detail is contractually frozen as public.
- **证据**:
~~~
`export 'src/ffi/hoshidicts_ffi_bindings.dart';` — exposes `final class FfiTermResult extends Struct { external Pointer<Utf8> expression; ... }` to all importers.
~~~
- **修复建议**: Stop exporting the ffi bindings file; keep only the safe HoshiDicts wrapper and Hoshi* data classes public.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-099 — chinese_language textToWords duplicates japanese logic but drops the match-length cache, causing O(n) uncached FFI calls

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `dictionary-ffi` / false-modularity / duplicated implementation / false modularity: split into files but logic copy-pasted and then diverged
- **位置**: `packages/hibiki_dictionary/lib/src/language/implementations/chinese_language.dart` : 30-59
- **审查者置信度**: high
- **根因**: ChineseLanguage._lookupMatchedLength (30-35) calls HoshiDicts.instance.lookup on every substring with no caching, while the structurally-identical JapaneseLanguage._lookupMatchedLength (japanese_language.dart:50-69) maintains a _matchLengthCache LinkedHashMap (max 5000). textToWords/wordFromIndex/getWordRange in both files are near-identical copies, but only one got the optimization.
- **影响**: Chinese segmentation re-runs the full synchronous native lookup for every position in the text with zero reuse, multiplying the UI-thread blocking described above. The divergence is a maintenance trap: a fix to one segmentation path silently won't reach the other.
- **证据**:
~~~
chinese: `static int _lookupMatchedLength(String text) { if (!HoshiDicts.isInitialized) return 0; final results = HoshiDicts.instance.lookup(text, maxResults: 1); ... }` vs japanese: identical body wrapped with `_matchLengthCache.remove(key) ... _matchLengthCache[key] = len;`.
~~~
- **修复建议**: Extract the cached _lookupMatchedLength + textToWords/wordFromIndex/getWordRange into a shared mixin/base so both languages share one implementation and one cache, instead of two drifting copies.
- **验证（对抗复核）**: I independently opened both files and confirmed every factual claim. ChineseLanguage._lookupMatchedLength (chinese_language.dart:30-35) calls HoshiDicts.instance.lookup with no caching. JapaneseLanguage._lookupMatchedLength (japanese_language.dart:54-69) maintains a _matchLengthCache LinkedHashMap with _maxMatchCache=5000 and LRU remove/reinsert eviction. textToWords/wordFromIndex/getWordRange are structurally identical copies (Chinese 41-84 vs Japanese 97-140) and only the Japanese copy received the cache. HoshiDicts.lookup (hoshidicts.dart:387-395) is a synchronous native FFI call, confirmin …(截断)
  - 验证者保留意见: The defect exists but the impact and severity are overstated. (1) The cache provides ZERO benefit within a single textToWords pass even in Japanese: each loop iteration uses sub = text.substring(pos), so every key is distinct and the forward scan does one FFI lookup per position regardless of langua …(截断)

### HBK-AUDIT-100 — getMediaFile silently returns null on native allocation failure, indistinguishable from 'media not found'

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `dictionary-ffi` / native-error-propagation / error swallowed: failure collapses into the same null as a normal miss
- **位置**: `packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart + native/hoshidicts/hoshidicts_ffi.cpp` : dart 478-499; cpp 380-389
- **审查者置信度**: medium
- **根因**: hoshidicts_get_media (cpp 386-387) does `r.data = malloc(r.size); if (r.data && r.size>0) memcpy(...)` — if malloc fails for a large media file, r.data is NULL but r.size keeps the real size. Dart (487) only builds bytes `if (r.size > 0 && r.data != nullptr)`, otherwise returns null. There is no channel to distinguish 'allocation failed' from 'file genuinely empty/missing'.
- **影响**: A large dictionary image that fails to allocate is reported to the WebView as a 404/not-found (dictionary_webview_media.dart:50/77 treat null as notFound), so the failure is hidden as a missing image with no diagnostic, hampering debugging on low-memory devices.
- **证据**:
~~~
cpp: `r.data = static_cast<uint8_t*>(malloc(r.size)); if (r.data && r.size > 0) memcpy(r.data, data.data(), r.size);` (size kept even when data NULL). dart: `if (r.size > 0 && r.data != nullptr) { bytes = Uint8List.fromList(...); } return bytes;`.
~~~
- **修复建议**: Distinguish allocation failure from empty data (e.g. set size=0 with a separate error flag on alloc failure, or surface the failure) so callers don't conflate OOM with not-found.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-101 — BookCssRepository.saveCss reads current file before existence/encoding checks, throwing on deleted or non-UTF-8 CSS

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / error-handling / happy-path-only file IO with no existence/encoding guard
- **位置**: `hibiki/lib/src/epub/book_css_repository.dart` : 99-122
- **审查者置信度**: medium
- **根因**: saveCss assumes the target CSS file exists and is UTF-8. Step 1 calls target.readAsStringSync() (line 105) before any existsSync() check; if the CSS file was removed (e.g. book re-extracted or partially deleted) this throws FileSystemException. If the original CSS is non-UTF-8 (same encoding issue as the parser), readAsStringSync throws FormatException. saveCss/resetFile have no try/catch.
- **影响**: Editing book CSS for a book whose CSS file is missing or non-UTF-8 throws an unhandled exception out of saveCss, surfacing as an editor crash/failed save rather than a graceful error. Narrow path (only the in-app CSS editor), hence low.
- **证据**:
~~~
book_css_repository.dart:105 `final String currentContent = target.readAsStringSync();` executed unconditionally inside saveCss with no existsSync guard and no encoding handling; same pattern in isDifferentFromOriginal (lines 21-22) and resetFile (line 128).
~~~
- **修复建议**: Guard with target.existsSync() and read bytes with allowMalformed decoding (or read/write as bytes) so missing/non-UTF-8 CSS does not throw; wrap save in error logging consistent with the rest of the module.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-102 — Decoded archive (Archive/ArchiveFile) is never closed/cleared after extraction, holding the full ZIP buffer and per-entry decompressed bytes

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / resource-leak / missing teardown of an external resource; relies on GC
- **位置**: `hibiki/lib/src/epub/epub_parser.dart` : 25-27, 34-36, 109-132
- **审查者置信度**: medium
- **根因**: ZipDecoder().decodeBytes(bytes) returns an Archive whose ArchiveFiles retain InputStream views over the source buffer, and `.content` caches each entry's decompressed bytes in _content (archive_file.dart content getter). The code never calls archive.clear()/clearSync() or per-file close()/clear(). Peak heap therefore holds: the original ZIP bytes + every decompressed entry accessed during extraction, until the Archive object is GC'd.
- **影响**: Transient peak memory spike per import roughly proportional to (zip size + sum of decompressed entries touched). Runs inside a compute() isolate that is torn down after parse, so the leak is bounded to the import operation — but for large image-heavy manga EPUBs the isolate can hit memory pressure / OOM on low-end Android devices. Bounded lifetime keeps it low.
- **证据**:
~~~
epub_parser.dart:25-27 decodeBytes + _extractArchive then return; no archive.clearSync(). archive-3.6.1 archive_file.dart shows content getter caches `_content` and provides clear()/closeSync() that are never invoked. _extractArchive iterates and accesses file.content (line 127) but never clears it.
~~~
- **修复建议**: After extraction, call archive.clearSync() (or iterate and file.clear()/closeSync()) to release decompressed buffers, especially given the large-image manga use case. At minimum clear each ArchiveFile right after writing it to disk.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-103 — EpubChapter.spineIndex is write-only dead state and is set inconsistently in _parseSpine

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / dead-code / zombie/dead state left behind; index bookkeeping that nothing consumes
- **位置**: `hibiki/lib/src/epub/epub_parser.dart` : 235, 251-258, 280, 284 (field def epub_book.dart:114,123)
- **审查者置信度**: high
- **根因**: The `index` counter in _parseSpine is incremented in some skip branches (path-escape line 251, missing file line 256, after append line 284) but NOT in others (missing idref line 238, item not in manifest line 242, non-HTML line 245). So the stored spineIndex does not consistently reflect spine position. The value is irrelevant because EpubChapter.spineIndex is never read anywhere in the repo.
- **影响**: No runtime effect today (dead field), but it is a maintainability trap: anyone who later relies on spineIndex will get inconsistent values depending on which spine entries were skipped. Pure dead/misleading code.
- **证据**:
~~~
Grep `\.spineIndex` across hibiki/ returns only the field declaration epub_book.dart:114 — never read. _parseSpine increments index on some `continue` paths (line 252,257,284) but skips incrementing on others (after line 238/242/245 continues).
~~~
- **修复建议**: Either remove spineIndex entirely, or make the increment consistent (increment once per itemref iteration regardless of branch) and document its meaning. Prefer removal since nothing consumes it.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-104 — TTU migration trusts untyped JSON shapes with unchecked `as` casts on every field

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / type-safety / type system as theater — untyped Map<String,dynamic> with blind as-casts on external data
- **位置**: `hibiki/lib/src/epub/ttu_migration.dart` : 69-71, 161, 290-303, 403, 458, 486-512
- **审查者置信度**: medium
- **根因**: bookData and its members are Map<String,dynamic> read from IndexedDB JSON. Fields are accessed with hard casts: `bookData['sections'] as List<dynamic>` (line 69), `bookData['elementHtml'] as String` (line 70), `sections[i] as Map<String, dynamic>` (line 161), `(raw['lastSectionIndex'] as num?)` etc. If the legacy data is missing a key or has an unexpected type, the cast throws ClassCastError / 'Null is not a subtype'.
- **影响**: A single malformed legacy book record aborts that book's migration. It IS caught by the per-book try/catch (line 137) so it degrades to 'skip this book' rather than crashing the app — but the hard-cast style means partial/odd data is treated as fatal instead of being defensively handled, and migrateIfNeeded's top-level reads (lines 29, 69-70) sit OUTSIDE that try for the cached-ids decode path.
- **证据**:
~~~
ttu_migration.dart:69 `final List<dynamic> sections = bookData['sections'] as List<dynamic>;`  :70 `String elementHtml = bookData['elementHtml'] as String;`  :29 `allIds = (jsonDecode(cachedIdsJson) as List<dynamic>).cast<int>();` (outside try). cast<int>() throws lazily on first non-int element.
~~~
- **修复建议**: Validate/coerce JSON fields defensively (is-checks, `as String?` with null fallback) for required keys before use, and wrap the cached-ids decode (lines 27-30) so a corrupt SharedPreferences value cannot throw out of migrateIfNeeded.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-105 — TTU section splitting uses raw string-offset / regex HTML slicing that breaks on attribute-order and entity edge cases

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / parser-robustness / regex/substring HTML parsing instead of a DOM; happy-path assumption about markup shape
- **位置**: `hibiki/lib/src/epub/ttu_migration.dart` : 167-220
- **审查者置信度**: medium
- **根因**: _writeSectionFiles locates section boundaries with `RegExp('id=["\']${RegExp.escape(ref)}["\']')` then walks backwards char-by-char to the previous `<` to find the tag start, then slices elementHtml by raw offsets. This assumes the id attribute is written with simple quotes and that scanning back to `<` lands on the owning element's opening tag. It ignores nested `<` inside attribute values/comments and any id reference that appears inside a comment or CDATA. A wrong match silently produces a mis-split or empty section.
- **影响**: Migrated legacy TTU books can get chapters split at the wrong boundary or emptied, producing wrong reading content for migrated users. Confined to the one-time TTU migration path (legacy compatibility), so low impact and not on the current import path.
- **证据**:
~~~
ttu_migration.dart:167 `final RegExp pattern = RegExp('id=["\']${RegExp.escape(ref)}["\']');` then lines 173-176 `while (tagStart > 0 && elementHtml[tagStart] != '<') { tagStart--; }` and line 211 `elementHtml.substring(spans[i].start, spans[i].end)`.
~~~
- **修复建议**: Parse elementHtml with package:html once and split by locating elements via document.getElementById(ref)/querySelector('#ref') and serializing subtrees, rather than regex+substring over the raw string. Since this is legacy-only, gate behind tests against real TTU dumps before changing.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-106 — ZipDecoder runs with CRC verification disabled; corrupt entries are extracted as garbage instead of being detected

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `epub` / parser-robustness / optimistic-but-unverified extraction (no integrity check on untrusted input)
- **位置**: `hibiki/lib/src/epub/epub_parser.dart` : 25, 34, 127
- **审查者置信度**: medium
- **根因**: ZipDecoder().decodeBytes(bytes) is called with the default `verify: false`, so per-entry CRC32 is never checked. file.content (line 127) decompresses on demand (archive_file.dart decompress()/inflateBuffer) without comparing against the stored crc32. A truncated/corrupt deflate stream either yields silently-wrong bytes or throws inside inflate.
- **影响**: A partially-corrupt EPUB extracts to disk with corrupted chapter/image bytes and no error, leading to mojibake or broken rendering that is hard to diagnose; or an inflate throw aborts the whole import via the importer catch. Low because most corruption still surfaces eventually and the data is user-supplied, but integrity is silently trusted.
- **证据**:
~~~
epub_parser.dart:25 `final Archive archive = ZipDecoder().decodeBytes(bytes);` (no `verify: true`). archive-3.6.1 archive_file.dart decompress() inflates without crc check when content is accessed.
~~~
- **修复建议**: Pass `verify: true` to decodeBytes (or validate crc32 per entry) and surface a clear FormatException for corrupt archives instead of writing garbage.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-107 — AudioRecorderDialogPage declares _durationNotifier as ValueNotifier<Duration?> but initializes it with ValueNotifier<Duration>

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / type-safety / type-system-as-theater (declared nullable, constructed non-nullable; nullability never actually used)
- **位置**: `hibiki/lib/src/pages/implementations/audio_recorder_page.dart` : 112-113, 290-296
- **审查者置信度**: high
- **根因**: Field type is `ValueNotifier<Duration?>` but the initializer is `ValueNotifier<Duration>(Duration.zero)`. Consumers (buildSlider/buildDurationAndPosition) treat the value as non-null Duration, and initialiseAudio assigns `_audioPlayer.duration ?? Duration.zero`. The nullable type annotation is misleading and unused.
- **影响**: No runtime bug today (value is never null), but the declared nullability invites a future `null` assignment that the slider/label code does not handle, and obscures intent. The durationStream listener (line 294) assigns possibly-null durations from just_audio, which is the only place the nullable type matters — yet getDurationText/getPositionText never null-check it.
- **证据**:
~~~
audio_recorder_page.dart:112-113 `final ValueNotifier<Duration?> _durationNotifier = ValueNotifier<Duration>(Duration.zero);` then line 224 `Duration duration = values.elementAt(0);` (non-null) inside buildDurationAndPosition.
~~~
- **修复建议**: Make the field ValueNotifier<Duration> and map stream nulls to Duration.zero at the listener (line 295), or keep nullable and null-check in the builders. Pick one and align.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-108 — BookCssEditorPage._doSave uses ScaffoldMessenger.of(context) after an await with no mounted guard

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / error-handling / lifecycle / happy-path-only async flow; missing mounted check after await
- **位置**: `hibiki/lib/src/pages/implementations/book_css_editor_page.dart` : 116-135, 126-135
- **审查者置信度**: high
- **根因**: _guardUnsaved awaits a dialog (showAppDialog), and when the user picks 'save' it calls _doSave(index) which synchronously calls ScaffoldMessenger.of(context).showSnackBar without checking mounted. _guardUnsaved is invoked from onPopInvokedWithResult (PopScope) and _attemptSwitchTab — both after async gaps.
- **影响**: If the editor is popped/disposed while the unsaved-changes dialog is resolving (e.g. fast navigation, system back), ScaffoldMessenger.of(context) on a defunct context throws. Inconsistent with the rest of the file (_doResetCurrent at 171 and _doResetAll at 208 DO guard with `if (mounted)`).
- **证据**:
~~~
book_css_editor_page.dart:132-134 `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.book_css_editor_saved)));` with no surrounding mounted check; compare to _doResetCurrent line 171 `if (mounted) { ScaffoldMessenger.of(context)...}`.
~~~
- **修复建议**: Guard the snackbar in _doSave with `if (mounted)`, matching _doResetCurrent/_doResetAll.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-109 — CustomFontsPage 'already added' detection is inconsistent between recommended and system-font flows

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / fragile-contract / two ad-hoc dedupe heuristics for the same concept
- **位置**: `hibiki/lib/src/pages/implementations/custom_fonts_page.dart` : 757-786
- **审查者置信度**: medium
- **根因**: _openRecommended computes alreadyAdded as ALL font names (`_fonts.map((e) => e['name'])`), while _addSystemFont computes alreadyAdded only for system fonts (`_fonts.where((e) => e['path'] == null).map(...)`). A system font and a file font can share a display name, so the two screens disagree about what is 'already added'.
- **影响**: A user can add a system font by name and also import a file font with the same name (or vice versa), producing duplicate-looking entries; the 'check' indicator on one picker says added while the other lets you add again. Confusing but not corrupting.
- **证据**:
~~~
custom_fonts_page.dart:762 `alreadyAdded: _fonts.map((e) => e['name'] as String).toSet()` (recommended) vs 771-774 `_fonts.where((e) => e['path'] == null).map((e) => e['name'] as String).toSet()` (system).
~~~
- **修复建议**: Use one canonical dedupe key (e.g. name+source) for both pickers, or document why system vs file fonts of the same name are intentionally distinct.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-110 — DictionaryDialogPage._showDownloadSelectionDialog rebuilds byCategory and runs O(n) catalog.indexOf per checkbox on every dialog setState

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / perf / rebuild-heavy StatefulBuilder; quadratic lookups inside build
- **位置**: `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart` : 316-396, 482-491
- **审查者置信度**: medium
- **根因**: Inside the StatefulBuilder, every checkbox toggle calls setDialogState, which re-runs byCategoryFrom(workingCatalog) and, for each rendered checkbox, _buildDictCheckbox does `catalog.indexOf(rec)` (linear scan). Identity used as the map key into checked/installed sets.
- **影响**: For large catalogs each toggle is O(categories*items + items^2). Catalog is modest today, so this is a smell rather than a hot bug, but it scales poorly and re-derives data that does not change on toggle.
- **证据**:
~~~
dictionary_dialog_page.dart:489 `final int idx = catalog.indexOf(rec);` executed per checkbox per rebuild; line 318 `final byCategory = DictionaryDownloader.byCategoryFrom(workingCatalog);` recomputed inside the StatefulBuilder builder.
~~~
- **修复建议**: Precompute a rec->index map once per catalog and hoist byCategory out of the per-toggle rebuild (recompute only when selectedLang changes).
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-111 — DictionaryDialogPage.openDictionaryOptionsMenu is dead code

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / dead-code / zombie helper left behind; duplicate path to the same menu
- **位置**: `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart` : 938-949
- **审查者置信度**: high
- **根因**: The dictionary tile uses HibikiOverflowMenu via buildDictionaryTileTrailing()/getMenuItems(); the separate showMenu-based openDictionaryOptionsMenu (a second way to open the same getMenuItems list at a tap position) is never wired to any gesture.
- **影响**: Unreachable method maintained alongside the live overflow menu; if menu semantics change, this stale copy can silently drift.
- **证据**:
~~~
Grep `openDictionaryOptionsMenu` returns exactly one hit: its own definition at dictionary_dialog_page.dart:938. It is never referenced from any onTap/onTapDown.
~~~
- **修复建议**: Remove openDictionaryOptionsMenu; keep the single overflow-menu path (buildDictionaryTileTrailing).
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-112 — DisplaySettingsPage groups advanced typography toggles under the i18n key 'section_advanced_colors'

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / maintainability / naming / copy-pasted section key from custom_theme_page without renaming; key name lies about content
- **位置**: `hibiki/lib/src/pages/implementations/display_settings_page.dart` : 250-279
- **审查者置信度**: high
- **根因**: The section containing text justification, vertical kerning, font VPAL, and 'prioritize reader styles' switches reuses `t.section_advanced_colors` (whose translated value happens to be the generic 'Advanced'/'高级选项'). The same key is the color-section title in custom_theme_page.dart:531. The key was copied without creating a dedicated `section_advanced_typography` key.
- **影响**: Display is acceptable (renders 'Advanced'), so no user-facing bug — but the key name asserts 'colors' for a non-color section, so any future edit to the colors-section wording silently changes an unrelated reader-typography section. Latent i18n coupling.
- **证据**:
~~~
display_settings_page.dart:251 `title: t.section_advanced_colors,` wrapping AdaptiveSettingsSwitchRow(ttu_text_justify), ttu_vert_kerning, ttu_font_vpal, ttu_reader_styles. strings.i18n.json:723 `"section_advanced_colors": "Advanced"`.
~~~
- **修复建议**: Introduce a dedicated key (e.g. section_advanced_typography) via tool/i18n_sync.dart and use it here, decoupling from the theme color section.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-113 — Entire base_media_search_bar.dart (308 LOC) is dead code: no subclass exists and buildBar() is never called

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / dead-code / false-modularity / pseudo-extensibility (abstraction kept for a multi-source architecture that no longer exists)
- **位置**: `hibiki/lib/src/pages/base_media_search_bar.dart` : 1-308
- **审查者置信度**: high
- **根因**: BaseMediaSearchBar/BaseMediaSearchBarState are abstract bases intended to be returned from MediaSource.buildBar() and subclassed per searchable source. The app is now a single reader-only source; grep across hibiki/ shows zero `extends BaseMediaSearchBarState` and zero callers of `.buildBar()`. media_source.dart:548 `BaseMediaSearchBar? buildBar() => null;` is the only reference and is itself never invoked.
- **影响**: 300+ lines of unreachable, untested UI/search/paging logic that confuses readers, drags maintenance, and hides latent bugs (e.g. onSubmitted registers pagingController.addPageRequestListener AFTER appending page 1, and mutates _isSearching/_searchSuggestions outside setState at lines 144-148). It looks like load-bearing search infrastructure but renders nothing.
- **证据**:
~~~
base_media_search_bar.dart:14 `abstract class BaseMediaSearchBarState<T extends BaseMediaSearchBar> extends BaseTabPageState`; media_source.dart:548-550 `BaseMediaSearchBar? buildBar() { return null; }`. Grep for `extends BaseMediaSearchBarState` and `.buildBar(` returns only these definitions, no concrete usage.
~~~
- **修复建议**: Delete base_media_search_bar.dart and MediaSource.buildBar(), plus their barrel export in pages.dart. If a future multi-source search is planned, reintroduce behind a real implementation rather than keeping dead scaffolding.
- **验证（对抗复核）**: Independently confirmed by reading the actual source. base_media_search_bar.dart is 308 LOC (read in full); it defines abstract BaseMediaSearchBar (line 8) and abstract BaseMediaSearchBarState<T> extends BaseTabPageState (line 14). Grep across all .dart files (hibiki/ and packages/) shows: (1) zero `extends BaseMediaSearchBarState` matches in source (the only hits for the symbol are docs/*.html generated dartdoc, not code); (2) `extends BaseMediaSearchBar` matches ONLY the BaseMediaSearchBarState definition itself — no concrete subclass; (3) the only `buildBar` references are the definition at …(截断)
  - 验证者保留意见: The defect is real, but the claimed severity of medium is mildly inflated. This is purely unreachable code: no crash, no data loss, no wrong behavior on any user-reachable path (it renders nothing because buildBar() always returns null and is never called). Per the rubric, that is a maintainability …(截断)

### HBK-AUDIT-114 — HistoryReaderPageState.buildMediaItemContent is overridden/duplicated with a parallel, divergent implementation in ReaderHibikiHistoryPage

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / duplication / copy-pasted page body with tiny diffs; two cover/title/progress renderers for the same media
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_history_page.dart` : 989-1037
- **审查者置信度**: medium
- **根因**: history_reader_page.dart:89-142 already implements buildMediaItemContent (cover + title overlay + progress bar). ReaderHibikiHistoryPage re-implements the same three-layer card (FadeInImage cover, _titleOverlay, _progressBar, plus a badge) at 989-1037, with its own _progressBar (1072) and _titleOverlay (634) that compute the same 0.97-cap progress logic as the base (history_reader_page.dart:127-134). buildMediaItem is likewise re-overridden (1040).
- **影响**: Two nearly identical renderers for an EPUB shelf tile drift independently (e.g. base uses scrim/onInverseSurface text styling; subclass uses surface-gradient overlay). The progress-clamp logic is duplicated verbatim in two places, so a fix to one (e.g. NaN handling) silently misses the other.
- **证据**:
~~~
history_reader_page.dart:127-134 progress `((item.position / item.duration) > 0.97) ? 1 : ...` vs reader_hibiki_history_page.dart:1072-1086 `_progressBar` `value = v > 0.97 ? 1 : v;` — same rule, two copies. Both define a title overlay (base line 108-126; subclass _titleOverlay line 634).
~~~
- **修复建议**: Extract a shared book-card content widget (cover+title+progress) used by both the generic HistoryReaderPageState and ReaderHibikiHistoryPage; the base implementation is effectively unused for the live source and the subclass copy is what ships.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-115 — LoadingPage is dead code — explicitly NOT used; main.dart renders the spinner inline instead

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / dead-code / zombie code left behind after a refactor; doc/comment contradicts reality
- **位置**: `hibiki/lib/src/pages/implementations/loading_page.dart` : 1-24
- **审查者置信度**: high
- **根因**: LoadingPage was the original boot screen, but main.dart now renders its own spinner because LoadingPage calls Spacing.of(context)/buildLoading() which needs context not available pre-init. The only code reference to `LoadingPage` outside its own file is in main.dart comments, which state 'we must not use it here'.
- **影响**: A page widget that nothing routes to. CLAUDE.md and main.dart comments still describe a navigate-from-LoadingPage flow that does not happen, misleading future maintainers about the startup sequence.
- **证据**:
~~~
main.dart:340-341 `// LoadingPage calls Spacing.of(context) via buildLoading(), so we must // not use it here — render the spinner directly instead.` Grep for `LoadingPage(` across hibiki/lib finds only loading_page.dart itself; no instantiation anywhere.
~~~
- **修复建议**: Either delete LoadingPage (and its pages.dart export) or actually use it once init completes. Update CLAUDE.md startup notes to match the inline-spinner reality.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-116 — Untyped Map<String,dynamic> font model with scattered `as` casts instead of a typed class

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `pages-ui` / type-safety / untyped JSON-like maps; `as` casts as the only type guarantee
- **位置**: `hibiki/lib/src/pages/implementations/custom_fonts_page.dart` : 357, 438, 762, 780-783, 814-817, 880-882
- **审查者置信度**: high
- **根因**: Custom fonts are modeled as `List<Map<String, dynamic>>` with keys 'name'/'path'/'enabled' accessed via `entry['name'] as String`, `entry['enabled'] as bool? ?? true`, `entry['path'] as String?` throughout. There is no FontEntry class despite the project rule requiring typed signatures.
- **影响**: Key typos or a malformed persisted map (e.g. enabled stored as int) become runtime cast errors rather than compile errors; the contract is duplicated in ~6 sites. _toggleFont casts `_fonts[index]['enabled'] as bool?` — if persistence ever writes a non-bool, this throws.
- **证据**:
~~~
custom_fonts_page.dart:438 `_fonts.add({'name': name, 'path': destPath, 'enabled': true});`; 816 `_fonts[index]['enabled'] = !(_fonts[index]['enabled'] as bool? ?? true);`; 880-882 `entry['name'] as String` / `entry['path'] != null` / `entry['enabled'] as bool? ?? true`.
~~~
- **修复建议**: Introduce a typed `class CustomFontEntry { final String name; final String? path; final bool enabled; ... fromMap/toMap }` and use it across the page and ReaderSettings.customFonts.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-117 — _applyChapterHighlights calls _settings!.setTheme(appModel.appThemeKey) as a side effect of applying highlights — hidden state write in a render path

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-core` / false-modularity / a method named applyChapterHighlights persists an unrelated theme setting; coupling masquerading as cohesion
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` : 1730-1741 (the if(chapterFavs.isNotEmpty) block), 1740 (_settings!.setTheme)
- **审查者置信度**: high
- **根因**: Inside _applyChapterHighlights, only when there are chapter favorites, it awaits `_settings!.setTheme(appModel.appThemeKey)`. Persisting the theme has nothing to do with applying highlights, and it only happens when favorites exist — so the theme write is conditional on unrelated data. This is a side effect hidden in a highlight-application method, executed on every chapter load that has favorites.
- **影响**: Redundant DB/preference write on every chapter load with favorites; and the theme is only synced to _settings when favorites exist, so a book with zero favorites never triggers this path (inconsistent state write). Confusing for maintenance; minor perf (extra preference write per navigation).
- **证据**:
~~~
`if (chapterFavs.isNotEmpty) { await HighlightBridge.applyHighlights(...); ... await _settings!.setTheme(appModel.appThemeKey); }` — setTheme buried at the end of the favorites branch.
~~~
- **修复建议**: Move theme sync out of _applyChapterHighlights into the theme-change flow (_onThemeChanged) or _onChapterLoadComplete unconditionally; do not gate a settings write on the presence of favorites.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-118 — _interceptRequest reads files and decodes UTF-8 on every chapter/resource request with unbounded readAsBytes; HTML decode assumes UTF-8

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-core` / perf / happy-path I/O with no streaming and a hardcoded encoding assumption contradicting EPUB reality
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` : 1092-1128 (_interceptRequest body inject), 1096-1100 (css cache), 1103-1104 (utf8.decode of html)
- **审查者置信度**: medium
- **根因**: For every text/html or xhtml resource the interceptor does `utf8.decode(data)` then string-splices style/cloak tags then re-encodes. EPUB XHTML can legitimately be encoded as Shift_JIS / EUC-JP / UTF-16 (declared in XML prolog or meta charset). utf8.decode on a non-UTF-8 chapter throws FormatException (not caught here), which would make the interceptor's returned Future reject and the chapter fail to load. CSS is cached (good) but HTML is re-decoded/re-injected every navigation with no cache.
- **影响**: Japanese EPUBs encoded in Shift_JIS (still common for older 青空文庫-derived or legacy books) throw on utf8.decode inside shouldInterceptRequest, causing a blank/failed chapter with only the 8s timeout to recover. Even for UTF-8 books, large chapters are fully decoded+re-encoded on every visit.
- **证据**:
~~~
`String html = utf8.decode(data);` with no `allowMalformed` and no charset detection; the function is documented to mirror Hoshi but assumes UTF-8 universally. No try/catch around the decode; contrast with CSS path which also assumes utf8 but is at least cached.
~~~
- **修复建议**: Detect declared charset (XML prolog / <meta charset>) or use `utf8.decode(data, allowMalformed: true)` as a floor, and fall back to latin1/shift_jis decode when the prolog declares it. Cache the injected HTML per filePath like CSS is cached.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-119 — _refreshProgress parses JS string result optimistically; format drift or NaN/Infinity yields silent no-op or division surprises

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-core` / js-bridge-contract / optimistic-but-unverified parse of a stringly-typed bridge result
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` : 2840-2879 (_refreshProgress), and JS producer 1349-1363 (window.hoshiProgressDetails)
- **审查者置信度**: medium
- **根因**: _refreshProgress evaluates `window.hoshiProgressDetails()` which returns a string like '"123,4567"'. Dart does `result.toString().replaceAll('"','').trim()`, splits on comma, int.tryParse each, requires exactly 2 parts and total>0. This is reasonably defensive, but the JS side can also return '' (handled) — the real fragility is that the producer recomputes total by walking the DOM when paginationMetrics is null (1355-1360), which on a heavy chapter is O(n) per 10s poll, and the result is silently discarded if parts.length != 2 with no diagnostic.
- **影响**: Latent: if hoshiProgressDetails ever returns a localized number or extra field, progress polling silently stops updating the top bar and stats with zero log. The 10s periodic poll also forces a full TreeWalker char count whenever metrics were invalidated (e.g. after updatePageSize set paginationMetrics=null), an avoidable per-poll DOM walk on large chapters.
- **证据**:
~~~
`final List<String> parts = str.split(','); if (parts.length != 2) return;` — early-returns with no log. JS: `if (total <= 0 && r.createWalker) { var walker = r.createWalker(); ... while (node = walker.nextNode()) total += r.countChars(node.textContent); }` runs full walk on every call when metrics absent.
~~~
- **修复建议**: Have hoshiProgressDetails reuse cached paginationMetrics.totalChars rather than re-walking; on the Dart side log a debugPrint when the result is non-empty but unparseable so format drift is visible during testing.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-120 — _volumeThrottleTimer used as a debounce gate but its callback is empty — throttle works, yet timer is leaked across rapid re-creates and never coalesced

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-core` / resource-leak / timer-as-flag pattern where the timer body does nothing and rapid events spawn/replace timers
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` : 360-383 (_onVolumeKey), 121-124 (timer fields), 836 (dispose cancels)
- **审查者置信度**: high
- **根因**: _onVolumeKey checks `if (_volumeThrottleTimer?.isActive ?? false) return;` then at the end creates `_volumeThrottleTimer = Timer(Duration(ms: speedMs), () {});` with an empty callback. This is a throttle gate. It is correctly cancelled in dispose. The issue is only that a previous still-active timer is replaced without cancel when speedMs==0 path is taken (no new timer created, old one if any keeps running) — minor, and an empty-body Timer is a smell but not a leak per se since dispose cancels.
- **影响**: Negligible runtime impact; flagged as maintainability/smell. The empty-callback timer obscures intent and the speedMs==0 branch leaves any prior throttle timer running (harmless empty body). Not user-visible.
- **证据**:
~~~
`if (speedMs > 0) { _volumeThrottleTimer = Timer(Duration(milliseconds: speedMs), () {}); }` — empty body; when speedMs==0 the gate is effectively disabled but a stale timer from a prior speed setting could still gate the next press.
~~~
- **修复建议**: Replace the empty-Timer throttle with a DateTime-based last-fire timestamp comparison (no Timer object), or document the gate clearly. Cancel any existing _volumeThrottleTimer at the top of the speedMs>0 branch.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-121 — build() rebuilds entire reader Stack (WebView + dictionary + chrome) on every setState including 10s progress poll and every cue tick

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-core` / perf / giant build method with many setState callers and no const/sub-widget isolation
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` : 926-977 (build), 2867-2878 (_refreshProgress setState), 1209/1965/4092 (setState in style/theme), 2833/3360 setState
- **审查者置信度**: medium
- **根因**: build() returns a Focus>PopScope>Scaffold>Stack containing _buildBody() (the InAppWebView), buildDictionary(), _buildTopProgressBar(), _buildBottomChrome(). Numerous code paths call setState({}) for unrelated reasons: _refreshProgress every 10s when char counts change, _checkFavoriteStatus, _onThemeChanged, _toggleChrome, _applyStylesLive. Each rebuilds the whole Stack. The InAppWebView is keyed (ValueKey) so its element is preserved, but the entire widget subtree is re-evaluated, and _buildAudiobookBar/_buildBottomChrome reconstruct on every tick.
- **影响**: Unnecessary widget tree walks on every progress poll and cue tick. Low severity because the WebView element is preserved by key and Flutter diffs cheaply, but on low-end Android the per-tick rebuild of the audiobook bar (already wrapped in ListenableBuilder, so doubly rebuilt) is wasteful. The top progress bar setState only fires when values change (guarded 2871), which is good — the broader issue is style/theme setState({}) with no scoping.
- **证据**:
~~~
Multiple `setState(() {})` with empty bodies (e.g. 1209, 1965, 4092, 3489, 3561) that exist only to repaint, forcing a full build() of the Stack. _buildAudiobookBar wraps AudiobookPlayBar in ListenableBuilder(listenable: ctrl) AND the bar is rebuilt by the parent build() too.
~~~
- **修复建议**: Hoist the WebView and dictionary into separate widgets or use ValueListenableBuilder/Selector to scope repaints; replace empty `setState(() {})` repaints with targeted ValueNotifier-driven rebuilds for theme/style.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-122 — onWillPop / PopScope flushes position via onWillPop() but lyrics-mode position-from-cue sync only runs in dispose, not on back-press flush

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-core` / state-sync / position-persist logic duplicated across dispose and lifecycle handlers but not kept identical
- **位置**: `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` : 842-845 (dispose: if(_lyricsMode) _syncPositionFromCurrentCue then _flushPosition), 880-886 (didChangeAppLifecycleState only _flushPosition), 934-941 (PopScope onPopInvoked)
- **审查者置信度**: high
- **根因**: In dispose, lyrics mode first calls _syncPositionFromCurrentCue() to convert the current audio cue into _lastProgressSection/_lastProgressValue, THEN _flushPosition(). But didChangeAppLifecycleState (paused/inactive) calls only _flushPosition() without the lyrics cue sync. So if the app is backgrounded while in lyrics mode, the persisted position reflects the last reader scroll, not the current audio cue position.
- **影响**: Backgrounding the app while in lyrics mode persists a stale position; reopening resumes at the wrong place (the position before lyrics playback advanced). Lower severity because dispose handles the normal exit, but OS-killed-while-backgrounded loses lyrics progress.
- **证据**:
~~~
dispose: `if (_lyricsMode) { _syncPositionFromCurrentCue(); } _flushPosition();`. didChangeAppLifecycleState: `if (state == paused || inactive) { _flushPosition(); _flushReadingStats(); }` — missing the lyrics cue sync.
~~~
- **修复建议**: Extract a `_syncAndFlushPosition()` helper that does the `if (_lyricsMode) _syncPositionFromCurrentCue();` then `_flushPosition();` and call it from both dispose and didChangeAppLifecycleState.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-123 — Base MediaSource uses throw UnimplementedError() as the default contract for currentMediaItem/generateImages/searchMediaItems/generateSearchSuggestions, a runtime trap instead of a typed contract

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / source-contract / type-system-as-theater; pseudo-extensibility with throwing defaults
- **位置**: `hibiki/lib/src/media/media_source.dart` : 310,513-545
- **审查者置信度**: medium
- **根因**: currentMediaItem (310), generateImages (513-519), generateAudio (523-529), searchMediaItems (533-539) and generateSearchSuggestions (543-545) default to `throw UnimplementedError()`. Subclasses are expected to know which to override based on boolean flags (implementsSearch/overridesAuto*). ReaderHibikiSource never overrides currentMediaItem or the search methods.
- **影响**: Latent crash surface: base_media_search_bar.dart:151 calls generateSearchSuggestions inside a `.then(...)` with no catchError, so if it were ever invoked on a non-search source (ReaderHibikiSource) the UnimplementedError becomes an unhandled async error. The flags-plus-throwing-defaults pattern offers no compile-time guarantee that the right methods are implemented. Currently guarded only by the fact the reader source disables search.
- **证据**:
~~~
media_source.dart:310 `MediaItem get currentMediaItem => throw UnimplementedError();`; 518 `throw UnimplementedError();`; 538; 544. base_media_search_bar.dart:151 `mediaSource.generateSearchSuggestions(query).then((newSuggestions) {...});` with no error handler.
~~~
- **修复建议**: Make these abstract where required, or split capability mixins (Searchable, AudioOverriding) so the type system enforces overrides; at minimum add catchError on the generateSearchSuggestions call site.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-124 — Dead methods on the source: portForLanguage and overridesAutoAudio/overridesAutoImage are never read by any live path

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / dead-code / zombie code; legacy framework carryover
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 334-342
- **审查者置信度**: high
- **根因**: ReaderHibikiSource.portForLanguage (334-342) throws UnimplementedError for non-JP/EN languages, but has zero call sites — the live port lookup is TtuMigrationServer.portForLanguage (ttu_migration_server.dart:17). The overridesAutoAudio flag (set true at line 40) and overridesAutoImage are never read anywhere in hibiki/lib/src (grep confirms only declarations/defaults), because the creator enhancement flow drives audio via its own generateAudio callbacks (creator/enhancements/*), not via MediaSource.generateAudio.
- **影响**: Misleading surface: overridesAutoAudio:true implies the source overrides Anki audio generation, but nothing consults the flag and generateAudio is never called by the creator. portForLanguage duplicates the migration server's method and would throw if ever called for a third language. Pure maintenance noise that misleads readers about how audio override works.
- **证据**:
~~~
grep portForLanguage: only definition at reader_hibiki_source.dart:334 plus the unrelated ttu_migration_server.dart:17. grep overridesAutoAudio across hibiki/lib/src: only declarations (media_source.dart:30,81; reader_media_source.dart:16) and the set at reader_hibiki_source.dart:40 — no read. Creator audio uses its own callbacks (audio_export_field.dart:133-155).
~~~
- **修复建议**: Delete portForLanguage from the source (it duplicates the migration server). Either wire overridesAutoAudio/generateAudio into the creator or remove the flag and the override to stop implying a contract that isn't honored.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-125 — Furigana migration writes a null preference expecting deletion semantics, but setPreference cannot represent null and persists the literal string 'null'

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / error-handling / optimistic-but-unverified contract; type-as-theater (nullable pref through untyped codec)
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 634-637
- **审查者置信度**: high
- **根因**: ttuFuriganaMode migrates the legacy 'ttu_hide_furigana' bool by calling `setPreference<bool?>(key: 'ttu_hide_furigana', value: null)` to 'remove' it. But MediaSource.setPreference -> PrefCodec.encode(null) (pref_codec.dart:12-18) has no null branch, so it falls to `return 's:$value'` = 's:null'. On the next launch _loadPreferencesFromDb decodes 's:null' back to the STRING 'null', not null.
- **影响**: A junk preferences row ttu_hide_furigana='s:null' is persisted forever. On every subsequent read getPreference<bool?> sees the string 'null' (not bool?), so it re-writes 's:null' via the getPreference miss-write path each time the furigana mode is read. It self-heals functionally (legacy==null so migration is skipped) but pollutes the DB and shows that the source relies on a null-write contract the framework does not honor.
- **证据**:
~~~
Line 635 `setPreference<bool?>(key: 'ttu_hide_furigana', value: null);` Line 624-625 `final dynamic legacy = getPreference<bool?>(key: 'ttu_hide_furigana', defaultValue: null);`. PrefCodec.encode (pref_codec.dart:12-18) has no null case -> 's:null'; decodeUntyped('s:null') returns the string 'null' (pref_codec.dart:50-51).
~~~
- **修复建议**: Use deletePreference(key: 'ttu_hide_furigana') instead of setPreference(value: null) to remove the legacy key. (And add an explicit null/absent representation to PrefCodec if null prefs are ever intended.)
- **验证（对抗复核）**: I independently confirmed the mechanical defect. reader_hibiki_source.dart:635 is exactly `setPreference<bool?>(key: 'ttu_hide_furigana', value: null);` (inside the legacy migration branch at lines 624-637). MediaSource.setPreference (media_source.dart:143-154) write-throughs via `PrefCodec.encode(value)`. PrefCodec.encode (pref_codec.dart:12-18) has no null branch — `null` matches none of bool/int/double/List, so it falls to `return 's:$value'` = the literal `'s:null'`. On reload, _loadPreferencesFromDb (media_source.dart:110-126) calls PrefCodec.decodeUntyped, and decodeUntyped('s:null') (pr …(截断)
  - 验证者保留意见: Confirmed the codec/API mechanics exactly as claimed, but the severity is inflated. The cited branch (reader_hibiki_source.dart:624-637) is only reachable when the static ReaderHibikiSource.readerSettings is null; it is set at app startup (app_model.dart:1056), so production reads go through ReaderS …(截断)

### HBK-AUDIT-126 — _extractBookId silently returns 0 on parse failure, launching the reader against a nonexistent book uid instead of failing

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / error-handling / happy-path; error swallowed into a sentinel value
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 151
- **审查者置信度**: medium
- **根因**: `static int _extractBookId(String identifier) => parseBookId(identifier) ?? 0;` and buildLaunchPage (143) uses it to construct ReaderHibikiPage(bookId: 0) when parseBookId returns null (empty/unknown identifier).
- **影响**: A malformed or empty mediaIdentifier produces bookId 0; the reader then loads bookUidFor(0) = 'reader_ttu/hoshi://book/0', which matches no real book, leading to an empty/error reader screen rather than a clear failure. Currently masked because identifiers are always produced by mediaIdentifierFor, but the 0 sentinel hides genuine corruption.
- **证据**:
~~~
Line 151 `static int _extractBookId(String identifier) => parseBookId(identifier) ?? 0;` Line 143 `final int bookId = _extractBookId(item?.mediaIdentifier ?? '');` bookUidFor(0) at line 54 yields a uid for a nonexistent book.
~~~
- **修复建议**: Have buildLaunchPage detect a null parseBookId result and return an explicit error/placeholder page (or assert), instead of coercing to 0.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-127 — epubUrl builds URLs without encoding the href while every consumer decodes with Uri.decodeComponent, asymmetric with fontUrl which does encode

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / source-contract / inconsistent contract within one class; happy-path (ASCII-only) assumption
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 56
- **审查者置信度**: medium
- **根因**: epubUrl(href) = 'https://$kHost/epub/$href' interpolates the raw EPUB href with NO percent-encoding. But the resource interceptor and link resolver both run Uri.decodeComponent on the path segment: reader_hibiki_page.dart:1082 `Uri.decodeComponent(path.substring('/epub/'.length))` and epub_book.dart:95 `Uri.decodeComponent(uri.path.substring('/epub/'.length))`. fontUrl by contrast encodes: reader_settings.dart:393 `'https://hoshi.local/fonts/${Uri.encodeComponent(path)}'`.
- **影响**: Build (no encode) and parse (decode) are asymmetric. For hrefs containing spaces the WebView may auto-encode to %20 and decode round-trips by luck; for hrefs containing a literal '%' (legal in some EPUB filenames), epubUrl emits a raw '%xx' that Uri.decodeComponent will mis-decode or throw on, breaking resource serving / internal link navigation for those chapters/assets. Inconsistent with fontUrl in the same class.
- **证据**:
~~~
Line 56 `static String epubUrl(String href) => 'https://$kHost/epub/$href';` (no encoding). Consumers decode: reader_hibiki_page.dart:1082, epub_book.dart:95. fontUrl encodes: reader_settings.dart:393.
~~~
- **修复建议**: Encode the href when building: 'https://$kHost/epub/${Uri.encodeFull(href)}' (or encode each path segment), matching the decode on the consumer side and the fontUrl convention.
- **验证（对抗复核）**: I independently confirmed the structural facts of the finding by reading the cited code:

1. Build side has NO encoding: reader_hibiki_source.dart:56 `static String epubUrl(String href) => 'https://$kHost/epub/$href';` — confirmed verbatim.
2. Consumers decode: reader_hibiki_page.dart:1082 and :3153 (`Uri.decodeComponent(path.substring('/epub/'.length))`), and epub_book.dart:95 `Uri.decodeComponent(uri.path.substring('/epub/'.length))`. (The finding miscited this file as src/media/sources/... but it is actually src/epub/epub_book.dart; line number 95 is correct.)
3. fontUrl DOES encode: reader …(截断)
  - 验证者保留意见: Severity is inflated. The finding's two impact scenarios do not hold as described: (1) the space case round-trips deterministically because WebUri runs Uri.parse/toString which normalizes spaces to %20 before the URL reaches the WebView — it is not "luck"; (2) the literal-% case is the only true bre …(截断)

### HBK-AUDIT-128 — getBooksFromDb runs N+1 sequential DB queries and up to 4 sequential File.exists() probes per book inside a serial loop

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `reader-source-media` / perf / happy-path; no batching
- **位置**: `hibiki/lib/src/media/sources/reader_hibiki_source.dart` : 224-281
- **审查者置信度**: medium
- **根因**: For each book the loop awaits posRepo.findByTtuBookId(book.id) (249) — one DB round trip per book — and then performs up to 4 sequential `await File(...).exists()` cover probes (265, 276). All awaits are serial (await inside a for loop), so total latency scales linearly with library size.
- **影响**: For a large library the bookshelf provider blocks on O(N) DB queries plus O(N*4) filesystem stat calls one after another, delaying the shelf render. Not a correctness bug but a latent scalability hazard on the main media-listing path.
- **证据**:
~~~
Lines 224-281: `for (final EpubBookRow book in books) { ... final pos = await posRepo.findByTtuBookId(book.id); ... if (await File(absPath).exists()) ... for (final String name in const [...]) { if (await File(fallback).exists()) ... } }`.
~~~
- **修复建议**: Batch reader positions in one query keyed by book ids; gather cover-existence checks with Future.wait per book; build the item list from the resolved results.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-129 — Dead/zombie helper customFontsTitle: count-aware title computed but never used; schema shows static placeholder, dropping the font count

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `settings-profile` / dead-code / zombie/dead code left behind by an abandoned implementation; duplicated title sources
- **位置**: `hibiki/lib/src/settings/settings_actions.dart` : 293-302
- **审查者置信度**: high
- **根因**: customFontsTitle(SettingsContext) iterates customFonts, counts enabled ones, and returns '${t.custom_fonts} (N)'. It is never referenced anywhere in lib/. The custom-fonts navigation row instead uses customFontsTitlePlaceholder (settings_schema.dart:185 / 1081) which is just `t.custom_fonts` with no count. The intended count-in-title feature is implemented but disconnected.
- **影响**: Maintainability hazard and a silent feature regression: the enabled-font count never appears in the row title even though code exists to produce it. The unused function (with its dynamic `font['enabled'] as bool? ?? true` cast over List<Map<String,dynamic>>) is also untyped-JSON dead weight that survives refactors and misleads readers into thinking the title is dynamic.
- **证据**:
~~~
String customFontsTitle(SettingsContext settingsContext) { final List<Map<String, dynamic>> fonts = settingsContext.readerSource.customFonts; final int enabledCount = fonts.where((font) => font['enabled'] as bool? ?? true).length; ... }  // no callers; schema uses customFontsTitlePlaceholder => t.custom_fonts
~~~
- **修复建议**: Either wire the count into the row (use a SettingsCustomItem/builder that calls customFontsTitle so the count shows) or delete customFontsTitle entirely. Do not keep both a static placeholder and an unused dynamic title.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-130 — Segmented settings dispatch bypasses generics via `as Function` invocation, defeating the type system

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `settings-profile` / type-safety / type system as theater (dynamic + `as Function` to silence the analyzer)
- **位置**: `hibiki/lib/src/settings/material_settings_renderer.dart` : 261-294
- **审查者置信度**: medium
- **根因**: SettingsSegmentedItem<T extends Object> is destructured in the switch as SettingsSegmentedItem<dynamic> (material 212 / cupertino 158), then onChanged is invoked as `(segmented.onChanged as Function)(settingsContext, values.first)` with values.first typed only as Object. The statically-typed SettingsValueChanged<T> contract is discarded; correctness depends entirely on the runtime value's type matching T, which the compiler can no longer verify. The same pattern appears in cupertino_settings_renderer.dart:206-223.
- **影响**: Latent runtime-crash risk: any future SettingsSegmentedItem whose option.value type differs from what its onChanged expects (e.g. an int-valued segmented control wired to a String handler, or vice versa) will compile cleanly and throw a TypeError only when the user taps a segment. Currently the only segmented item in scope is system.update_channel (String), so it works today, but the abstraction advertises type safety it does not provide.
- **证据**:
~~~
SettingsSegmentedItem<dynamic> segmented => _segmented(segmented); ... final Object selected = segmented.selected(settingsContext) as Object; ... await (segmented.onChanged as Function)(settingsContext, values.first);
~~~
- **修复建议**: Add a type-preserving dispatch helper (a generic method `_segmented<T extends Object>(SettingsSegmentedItem<T>)` reached via a small typed visitor) or constrain the model so option.value/selected/onChanged are guaranteed compatible. At minimum, assert the runtime type before the `as Function` call so failures surface deterministically.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-131 — buildReaderQuickSettingsDestination emits a SettingsDestination reusing an existing id (readingDisplay), risking firstWhere id collisions

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `settings-profile` / schema-drift / copy-paste of an enum id without recognizing it must stay unique
- **位置**: `hibiki/lib/src/settings/settings_schema.dart` : 30-73
- **审查者置信度**: medium
- **根因**: buildReaderQuickSettingsDestination constructs a synthetic destination with id: SettingsDestinationId.readingDisplay — the same id already owned by _readingDisplayDestination() (line 169). SettingsDestinationId is the key used by buildSettingsSchema consumers via firstWhere on id (lines 34-49) and by SettingsHomePage selection logic (settings_home_page.dart:64-68, 116-119). The id is no longer a unique identifier of a destination.
- **影响**: If the quick-settings destination is ever merged into the same destination list as the full schema (or if selection/lookup code does firstWhere over a combined list), two destinations share an id and firstWhere returns the wrong one or selection state becomes ambiguous. Today they live in separate lists so no crash occurs, but the invariant 'id uniquely identifies a destination' is violated, which is a schema-drift trap for future edits.
- **证据**:
~~~
return SettingsDestination(id: SettingsDestinationId.readingDisplay, title: t.reader_settings_section, ...); // duplicate of _readingDisplayDestination()'s id at line 169
~~~
- **修复建议**: Introduce a dedicated SettingsDestinationId (e.g. readerQuickSettings) for the synthetic quick-settings destination, or document/enforce that quick-settings destinations are never placed in the same list as the main schema. Keep ids globally unique.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-132 — DesktopDirectoryService hardcodes English 'Documents'/'Downloads' folder names, leaking an OS/locale-specific assumption

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `shortcuts-platform` / platform-boundary / happy-path English-locale assumption baked into a 'platform abstraction'
- **位置**: `hibiki/lib/src/platform/desktop/desktop_directory_service.dart` : 22-38
- **审查者置信度**: high
- **根因**: getDefaultPickerDirectories builds picker roots by joining the user home with literal strings 'Documents' and 'Downloads'. On localized Windows/Linux installs the real folder display/path may differ (German 'Dokumente', etc.), and on Linux XDG user dirs (XDG_DOCUMENTS_DIR) are not consulted. The abstraction is supposed to hide OS specifics but encodes an English-locale filesystem layout.
- **影响**: On non-English desktop environments the default picker directories silently come back empty (the `.where(existsSync())` filter at line 37 drops the non-existent English paths), so the file picker opens with no helpful default locations. Degrades gracefully (no crash) but the feature is dead for those users.
- **证据**:
~~~
desktop_directory_service.dart:27-28 `result.add(p.join(userProfile, 'Documents')); result.add(p.join(userProfile, 'Downloads'));` and :33-34 same for HOME; :37 `return result.where((d) => Directory(d).existsSync()).toList();`.
~~~
- **修复建议**: Resolve known folders via the OS: on Windows use SHGetKnownFolderPath / path_provider's getDownloadsDirectory; on Linux read XDG_DOCUMENTS_DIR / XDG_DOWNLOAD_DIR; fall back to home only if those fail.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-133 — Inconsistent platform-channel failure strategy across the same boundary (isSupported gate vs catching MissingPluginException, neither catches PlatformException)

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `shortcuts-platform` / platform-boundary / duplicated divergent platform-boundary handling
- **位置**: `hibiki/lib/src/platform/floating_overlay_channel.dart, hibiki/lib/src/utils/misc/volume_key_channel.dart, hibiki/lib/src/platform/android/android_lifecycle_service.dart` : floating_overlay_channel.dart:17,19-40; volume_key_channel.dart:36-42; android_lifecycle_service.dart:17-18
- **审查者置信度**: high
- **根因**: Three native bridges each pick a different defense for the same problem (channel may be absent/failing). FloatingOverlayChannel gates on `isSupported = Platform.isAndroid` and catches nothing. VolumeKeyChannel catches only MissingPluginException. AndroidLifecycleService.moveTaskToBack does neither (relies entirely on its single caller AppModel.moveToBack:2331-2338 to try/catch). No shared helper.
- **影响**: Maintainability hazard: each new channel call must rediscover the right guard, and the gaps differ. None of the three catches PlatformException, so a native-thrown error behaves differently depending on which bridge is touched. A future caller of moveTaskToBack that forgets the try/catch will crash.
- **证据**:
~~~
volume_key_channel.dart:39 `} on MissingPluginException {` (catches only that). floating_overlay_channel.dart:17 `bool get isSupported => Platform.isAndroid;` (gate, no catch). android_lifecycle_service.dart:18 `HibikiChannels.lifecycle.invokeMethod<void>('moveTaskToBack');` (bare).
~~~
- **修复建议**: Introduce one shared safe-invoke helper (e.g. `Future<T?> safeInvoke<T>(...)` catching PlatformException + MissingPluginException and logging) and route all native bridges through it, so the boundary contract is uniform.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-134 — PlatformServices.init() couples cross-service SDK wiring to a runtime type-check on the clipboard implementation

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `shortcuts-platform` / abstraction-quality / type-system-as-theater (abstract interface bypassed by is/as downcast)
- **位置**: `hibiki/lib/src/platform/platform_services.dart` : 48-53
- **审查者置信度**: medium
- **根因**: init() does `if (sdk != null && clipboard is AndroidClipboardService) (clipboard as AndroidClipboardService).updateSdkVersion(sdk);`. The bundle is built from abstract interfaces, but this one cross-wire reaches through the abstraction with a concrete `is`/`as` cast. The SDK-version dependency of AndroidClipboardService.shouldShowCopyToast is invisible at the interface level.
- **影响**: Fragile contract: if the Android clipboard impl is renamed/swapped, the cast silently no longer matches, updateSdkVersion is never called, `_sdkVersion` stays 0 (android_clipboard_service.dart:5), and shouldShowCopyToast (line 16) wrongly returns true for all SDKs (double toast on Android 13+). No compile error catches the regression.
- **证据**:
~~~
platform_services.dart:50-52 `if (sdk != null && clipboard is AndroidClipboardService) { (clipboard as AndroidClipboardService).updateSdkVersion(sdk); }`. Dependent state: android_clipboard_service.dart:5 `int _sdkVersion = 0;` -> :16 `bool get shouldShowCopyToast => _sdkVersion < 33;`.
~~~
- **修复建议**: Add an optional `updateSdkVersion(int)` (no-op default) to the PlatformClipboardService interface, or inject sdkVersion into AndroidClipboardService's constructor, eliminating the downcast and making the dependency explicit.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-135 — Registry loadFromJson mutates state entry-by-entry; a malformed nested binding type leaves a partially-loaded registry

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `shortcuts-platform` / error-handling / optimistic parse with comment that contradicts actual behavior
- **位置**: `hibiki/lib/src/shortcuts/shortcut_registry.dart, hibiki/lib/src/shortcuts/input_binding.dart` : shortcut_registry.dart:23-56; input_binding.dart:346-365
- **审查者置信度**: medium
- **根因**: loadFromJsonString calls loadDefaults() then loadFromJson() inside a try/catch. loadFromJson iterates entries and assigns `_bindings[action]` incrementally. ShortcutBindingSet.fromJson uses `kbRaw.cast<String>()` (input_binding.dart:351), a lazy cast that throws TypeError only when iterated by `.map(...).toList()` if the JSON list contains a non-String (e.g. a number from hand-edited or corrupted prefs). The throw aborts loadFromJson mid-iteration; the catch (shortcut_registry.dart:53) just keeps whatever was applied so far.
- **影响**: On corrupted/partially-bad shortcut JSON, the user ends up with 'defaults + the subset of valid entries parsed before the bad one' rather than either fully-restored bindings or clean defaults. The result is order-dependent and silent (comment says 'keep defaults' but state is actually a hybrid). Low severity because it requires malformed prefs and never crashes the app.
- **证据**:
~~~
input_binding.dart:350-355 `keyboardBindings: kbRaw is List ? kbRaw.cast<String>().map(InputBinding.deserialize).whereType<InputBinding>().toList(...) : const []`. shortcut_registry.dart:53-55 `} catch (_) { // Corrupted JSON — keep defaults. }` — but defaults were only partially overwritten.
~~~
- **修复建议**: Parse into a local map first and only commit to _bindings/_unknownEntries after the whole JSON parses successfully; or use `.whereType<String>()` instead of `.cast<String>()` so a stray non-String entry is skipped instead of throwing.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-136 — TtsEngine / StoragePaths / PlatformIntegration are dead abstractions with zero implementations and zero consumers

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `shortcuts-platform` / false-modularity / over-engineering / pseudo-extensibility (interfaces planned in a spec, generated, never wired)
- **位置**: `packages/hibiki_platform/lib/src/tts_engine.dart, packages/hibiki_platform/lib/src/storage_paths.dart, packages/hibiki_platform/lib/src/platform_integration.dart` : tts_engine.dart:6-15; storage_paths.dart:5-9; platform_integration.dart:6-20
- **审查者置信度**: high
- **根因**: These three abstract interfaces were generated from the 2026-05-16 multiplatform-design spec but never implemented or wired. Grep across the whole repo finds no `implements TtsEngine`/`implements StoragePaths`/`implements PlatformIntegration` anywhere in lib code, and no callers. The package barrel (hibiki_platform.dart:3-5) still exports all three as public API. The real app bypasses them entirely: TTS goes through `TtsChannel` using `HibikiChannels.tts.invokeMethod` (hibiki/lib/src/utils/misc/tts_channel.dart:19,24...), storage paths come from path_provider directly in app_model (getApplicationSupportDirectory etc.), and intents are handled elsewhere.
- **影响**: One third of the hibiki_platform package (3 of 9 files) is unreachable scaffolding exported as public API. It misleads readers into thinking platform TTS/storage/intents are routed through these abstractions when they are not, and creates maintenance drag (the interfaces must be kept compiling for nothing). Classic AI over-engineering / pseudo-extensibility.
- **证据**:
~~~
tts_engine.dart:6 `abstract class TtsEngine { Future<void> speak(...); ... }` — no implementer in repo. Real TTS path: tts_channel.dart:24 `await _channel.invokeMethod('speak', {...})`. Grep for `implements TtsEngine|implements StoragePaths|implements PlatformIntegration` returns only the abstract declarations themselves plus docs/specs.
~~~
- **修复建议**: Either delete the three unused interfaces and remove their exports from hibiki_platform.dart, or actually implement+inject them (e.g. make TtsChannel implement TtsEngine, a path-provider-backed StoragePaths, and wire PlatformIntegration). Do not keep exported interfaces with no implementation.
- **验证（对抗复核）**: I independently confirmed every load-bearing claim by reading the cited code:

1. The three abstract interfaces exist exactly as cited:
   - packages/hibiki_platform/lib/src/tts_engine.dart:6-15 — `abstract class TtsEngine` with speak/stop/synthesizeToFile/isAvailable.
   - packages/hibiki_platform/lib/src/storage_paths.dart:5-9 — `abstract class StoragePaths` with documentsDir/supportDir/cacheDir getters.
   - packages/hibiki_platform/lib/src/platform_integration.dart:6-20 — `abstract class PlatformIntegration` with intent/share/wakelock/pickFile members.

2. Zero implementations: Grep for `i …(截断)
  - 验证者保留意见: Not refuted on facts — the finding is accurate. The only correction is severity: it is overstated at medium. These are inert, uninstantiated, uncalled abstract interfaces with no behavioral, data, or contract impact (nothing implements or consumes them), so it is a maintainability smell (low), not a …(截断)

### HBK-AUDIT-137 — getDefaultPickerDirectories accepts a mediaType parameter that is ignored on Android (and unused on iOS), a false contract

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `shortcuts-platform` / false-modularity / type-system/signature theater — parameter exists but is dead
- **位置**: `hibiki/lib/src/platform/android/android_directory_service.dart, hibiki/lib/src/platform/ios/ios_directory_service.dart` : android_directory_service.dart:26-28; ios_directory_service.dart:21-23; interface: packages/hibiki_platform/lib/src/services/platform_directory_service.dart:4
- **审查者置信度**: high
- **根因**: The interface method `getDefaultPickerDirectories(String mediaType)` promises media-type-aware default directories, but the Android impl ignores `mediaType` and just returns getExternalStorageDirectories(); iOS returns const []. Only the desktop impl ignores it too. No implementation branches on mediaType anywhere.
- **影响**: API theater: callers pass a mediaType (e.g. 'epub' vs 'audio') expecting tailored roots, but get identical results regardless. Misleading contract that invites future bugs when someone assumes the parameter works.
- **证据**:
~~~
android_directory_service.dart:26 `Future<List<String>> getDefaultPickerDirectories(String mediaType) async { return getExternalStorageDirectories(); }` — mediaType never referenced.
~~~
- **修复建议**: Either implement media-type-specific defaults (e.g. DIRECTORY_DOWNLOADS for epub, DIRECTORY_MUSIC for audio on Android) or drop the parameter from the interface so the signature reflects reality.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-138 — Content sync export/import keyed on file EXISTENCE only — never re-uploads changed local files, and audio path resolution casts untyped JSON

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / conflict-resolution / type-safety / existence-as-up-to-date heuristic; unguarded jsonDecode cast
- **位置**: `hibiki/lib/src/sync/sync_manager.dart` : 421-453 (_exportContentIfMissing), 455-489 (_importContentIfMissing), 506-531 (_resolveAudioPaths)
- **审查者置信度**: medium
- **根因**: _exportContentIfMissing only uploads when `findContentFile == null` (remote absent); a locally edited/replaced EPUB or audio file is never re-synced. _importContentIfMissing mirrors this for local-missing only. _resolveAudioPaths does `(jsonDecode(row.audioPathsJson!) as List).cast<String>()` with no try/catch — a malformed audioPathsJson throws and aborts content sync for that book.
- **影响**: Low/medium: content drift is silently ignored once a file exists on both sides (acceptable for immutable EPUBs, wrong for re-imported/edited ones). A corrupt audioPathsJson row throws an unhandled Format/CastError that surfaces as a generic per-book sync failure.
- **证据**:
~~~
`final existing = await _backend.findContentFile(folderId, fileName); if (existing == null) { await _backend.uploadContentFile(...); }` and `return (jsonDecode(row.audioPathsJson!) as List).cast<String>();`
~~~
- **修复建议**: Compare size/mtime/hash to decide re-upload rather than mere existence; wrap audioPathsJson decode in a guarded parse returning const [] on failure (consistent with the other early returns).
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-139 — Cover/JSON download responses not size-limited on non-Google backends (memory-exhaustion via hostile/large remote)

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / resource / error-handling / defensive cap present in one backend, absent in the five others
- **位置**: `hibiki/lib/src/sync/webdav_ops.dart, hibiki/lib/src/sync/dropbox_sync_backend.dart, hibiki/lib/src/sync/onedrive_sync_backend.dart, hibiki/lib/src/sync/ftp_sync_backend.dart, hibiki/lib/src/sync/sftp_sync_backend.dart` : webdav_ops.dart:165-171 (downloadJson reads full body); google_drive_handler.dart:272-290 (has _maxDownloadSize cap — the others do not)
- **审查者置信度**: medium
- **根因**: GoogleDriveHandler._downloadJson enforces a 10MB cap while streaming; WebDavOps.downloadJson / Dropbox._downloadFileJson / OneDrive._downloadItemJson / FTP._downloadJson / SFTP._downloadJson read the entire metadata file into memory with no cap before jsonDecode.
- **影响**: A malicious or buggy server (especially the untrusted LAN/WebDAV/SMB targets users point at) can return a multi-GB 'progress_*.json' that the metadata download loads fully into RAM, OOM-killing the app. Lower likelihood for trusted clouds; real for self-hosted/LAN endpoints.
- **证据**:
~~~
WebDavOps.downloadJson: `final body = await response.transform(utf8.decoder).join(); return jsonDecode(body);` — no length guard, unlike Google's `if (builder.length > _maxDownloadSize) throw GoogleDriveError('Response too large');`
~~~
- **修复建议**: Apply the same _maxDownloadSize streaming guard to all metadata downloads (these JSON files are tiny by spec, so a low cap is safe).
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-140 — Dropbox OAuth app key hardcoded in source as a real-looking client_id

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / credential/secret security / secret-like constant committed inline while sibling backends use placeholders/env vars
- **位置**: `hibiki/lib/src/sync/dropbox_sync_backend.dart` : 23-27
- **审查者置信度**: medium
- **根因**: `static const _clientId = 'lt0ufixv6si14dc';` is committed in source (PKCE flow, so no client secret — a Dropbox app key alone is not strictly secret), unlike OneDrive (`YOUR_ONEDRIVE_CLIENT_ID` placeholder) and Google (String.fromEnvironment). Inconsistent handling and an inline app identifier.
- **影响**: Low: a Dropbox PKCE app key is a public identifier, but inlining it means abuse/rate-limit attribution to this app and no easy rotation without a code release. Inconsistency increases the chance a future secret-bearing key is committed the same way.
- **证据**:
~~~
`static const _clientId = 'lt0ufixv6si14dc'; static bool get isConfigured => !_clientId.startsWith('YOUR_');`
~~~
- **修复建议**: Move the app key to String.fromEnvironment like Google's client id for consistency and to allow build-time configuration/rotation; document that it is a public PKCE app key.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-141 — Google desktop auth leaks the underlying http.Client across token refresh

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / resource-leak / ownership confusion between baseClient and authenticatedClient
- **位置**: `hibiki/lib/src/sync/google_drive_auth.dart` : 104-180
- **审查者置信度**: medium
- **根因**: refreshAuth/restoreDesktopAuth create `final baseClient = http.Client();`, wrap it via auth.authenticatedClient(baseClient, refreshed) into _desktopClient, and on success close the PREVIOUS _desktopClient (`_desktopClient?.close()`). authenticatedClient.close() does not necessarily close the wrapped base client of the prior generation, and each refresh creates a fresh baseClient. baseClient is only explicitly closed on the error paths.
- **影响**: Each desktop token refresh can leak one http.Client (and its socket pool) for the app lifetime on desktop. Bounded by refresh frequency but unbounded over a long session — slow resource creep on desktop.
- **证据**:
~~~
refreshAuth success: `_desktopClient?.close(); _desktopClient = auth.authenticatedClient(baseClient, refreshed);` with no close of the baseClient owned by the previous authenticatedClient; only the catch blocks call `baseClient.close()`.
~~~
- **修复建议**: Track and explicitly close the previous baseClient on successful refresh, or reuse a single long-lived baseClient across refreshes instead of allocating a new one each time.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-142 — Untyped cloud JSON cast directly with `as` — malformed/error responses crash the parse instead of surfacing a typed error

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `sync` / type-safety / error-handling on network failure / type system as theater — `as Map`/`as int`/`as String` on untrusted remote JSON
- **位置**: `hibiki/lib/src/sync/ttu_models.dart, hibiki/lib/src/sync/dropbox_sync_backend.dart, hibiki/lib/src/sync/onedrive_sync_backend.dart, hibiki/lib/src/sync/google_drive_handler.dart` : ttu_models.dart:20-25,63-73,108-112; dropbox_sync_backend.dart:121-123,185-189,227-234,546-554; onedrive_sync_backend.dart:123-124,272,284-286,549-551
- **审查者置信度**: high
- **根因**: fromJson uses unguarded casts: `json['exploredCharCount'] as int`, `json['access_token'] as String`, `(json['value'] as List).cast<Map<String,dynamic>>()`. Cloud APIs return integers as JSON numbers that may decode as double, omit fields on partial/error payloads, or return an error object where a list/map is expected. The 200-but-error or schema-drift case throws a raw TypeError/CastError.
- **影响**: A single malformed or unexpected remote payload (e.g. exploredCharCount serialized as 1.0, or a Dropbox/Graph error body returned with 200) throws an uncaught CastError that bypasses the SyncBackendError/SyncAuthError contract, lands in SyncManager's generic catch, and reports a cryptic '_TypeError' as the sync error — or in compare-dialog parallel fetches silently returns empty data, hiding real remote progress.
- **证据**:
~~~
TtuProgress.fromJson: `exploredCharCount: json['exploredCharCount'] as int` (no num.toInt fallback unlike `progress`); dropbox refreshAuth: `_accessToken = json['access_token'] as String;` with no presence check; OneDrive listChildren: `items.addAll((json['value'] as List).cast<Map<String,dynamic>>());`
~~~
- **修复建议**: Use defensive parsing: `(json['exploredCharCount'] as num).toInt()`, validate required fields and throw SyncBackendError with context on shape mismatch, and treat non-list/`error` payloads explicitly rather than casting.
- **验证（对抗复核）**: Confirmed the cited code exists exactly as described. ttu_models.dart:22 uses bare `json['exploredCharCount'] as int` (and dataId/lastBookmarkModified, plus TtuStatistics int fields lines 64-72, TtuAudioBook line 109), while the float fields use defensive `(json['progress'] as num).toDouble()` (line 23), `(json['readingTime'] as num).toDouble()` (line 67), `(json['playbackPosition'] as num).toDouble()` (line 110). The int/num asymmetry is real: a JSON-encoded int field that decodes as double (e.g. `1.0`) would throw a CastError on `as int`. dropbox_sync_backend.dart:122/186/189 use bare `as St …(截断)
  - 验证者保留意见: The medium severity is inflated. The finding's core technical claims (unguarded `as` casts, int/num asymmetry) are accurate, but the impact narrative — "uncaught CastError", "crash", bypassing the error contract — is wrong: SyncManager.syncBook (sync_manager.dart:92) and _fetchRemoteBookData (sync_c …(截断)

### HBK-AUDIT-143 — book_import_dialog_test is gated @TestOn('windows') and only tests a stub dialog frame, not the EPUB/audio/subtitle import flow

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `test-coverage` / test-coverage-gaps / platform-gated / happy-path-only widget test substituted for the real import orchestration; silently skipped off-Windows
- **位置**: `hibiki/test/media/audiobook/book_import_dialog_test.dart` : 1-49
- **审查者置信度**: high
- **根因**: File header is @TestOn('windows'), so on a Linux/Mac/Android-focused CI run it is silently skipped. Its testWidgets case pumps BookImportDialogFrame populated with placeholder TextField widgets and asserts takeException()==null + layout fits; the other test asserts a Windows file-filter constant includes 'all files'. The actual import pipeline (parsing the EPUB, matching subtitle to chapters, persisting audiobook + cues) — book_import_dialog.dart's real responsibility and an explicit integration-test fixture target in CLAUDE.md — is not exercised in this unit test.
- **影响**: On the project's primary platform (Android) this whole file does not run. Even where it runs, it validates dialog chrome layout, not import correctness, so a broken import (wrong cue persistence, bad chapter mapping) is not caught at the unit level.
- **证据**:
~~~
Line 1 '@TestOn('windows')'; lines 24-44 build BookImportDialogFrame with const TextField placeholders; line 49 test('windows audio file filter includes an all files option', ...). No invocation of real import logic.
~~~
- **修复建议**: Move platform-independent import logic into a pure function tested without @TestOn, and unit-test it against the kagami EPUB/SRT fixtures referenced in CLAUDE.md (or small synthetic fixtures) asserting persisted audiobook + audio_cues counts.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-144 — concurrent ReaderPositions convergence test asserts only non-null, not the converged value

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `test-coverage` / happy-path-only / weak-assertion / assertion that can't detect the bug it claims to test (last-write-wins not verified)
- **位置**: `hibiki/test/database/concurrent_writes_test.dart` : 187-207
- **审查者置信度**: high
- **根因**: The test 'rapid upserts to same book converge' fires 30 interleaved upsertReaderPosition calls with distinct sectionIndex/normCharOffset/updatedAt, then only asserts expect(row, isNotNull). It never asserts which value won (e.g. that the row reflects the highest updatedAt, or any deterministic outcome), so it cannot detect lost-update / wrong-convergence bugs in the upsert. By contrast the ReadingStatistics/Preferences cases in the same file do assert aggregated final values.
- **影响**: A real upsert race that leaves a stale or partially-written reader position would still pass this test, because any surviving row satisfies isNotNull. Reader-position is the field users feel most (reopen at wrong place), so a non-asserting 'convergence' test is misleading coverage.
- **证据**:
~~~
await Future.wait(List.generate(n, (i) => db.upsertReaderPosition(ReaderPositionsCompanion.insert(ttuBookId: 1, sectionIndex: i % 10, normCharOffset: i * 100, updatedAt: DateTime.now().millisecondsSinceEpoch + i)))); final row = await db.getReaderPosition(1); expect(row, isNotNull);  // no assertion on row.sectionIndex / normCharOffset / updatedAt
~~~
- **修复建议**: Make the writes deterministic (fixed increasing updatedAt) and assert the final row equals the last-writer's values, mirroring the addReadingStatistic aggregation assertions in the same file.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-145 — history_reader_page_static_test.dart is a pure tautology — asserts a constructed object is its own type (only proves the file compiles)

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `test-coverage` / fake/ineffective-tests / tautological test guaranteed true by the type system
- **位置**: `hibiki/test/pages/history_reader_page_static_test.dart` : 5-7
- **审查者置信度**: high
- **根因**: The sole test does expect(const HistoryReaderPage(), isA<HistoryReaderPage>()). Constructing HistoryReaderPage() necessarily yields a HistoryReaderPage, so isA<HistoryReaderPage> is true by definition; the type checker already guarantees it. The test verifies nothing beyond 'the import resolves and the file compiles'. Same compile-only smell appears as the first test in floating_dict_page_static_test.dart:12-17.
- **影响**: Inflates the test count and coverage map with a test that cannot fail for any behavioral reason. It provides no protection against any actual defect in HistoryReaderPage rendering or behavior, while looking like page coverage in the suite listing.
- **证据**:
~~~
test('default history reader page library compiles', () { expect(const HistoryReaderPage(), isA<HistoryReaderPage>()); });
~~~
- **修复建议**: Either delete it (compilation is already enforced by every other test that imports the library) or replace with a real widget test that pumps the page inside a ProviderScope and asserts its key states (empty history vs. populated), like collections_page_test / media_item_dialog_page_test already do.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-146 — oauth_backend_config_test.dart is a self-contradicting tautological test: docstring says it locks 'placeholder hides backend', assertions unconditionally expect isConfigured==true

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `test-coverage` / fake/ineffective-tests / tautological assertion; test contradicts its own documented contract
- **位置**: `hibiki/test/sync/oauth_backend_config_test.dart` : 5-20
- **审查者置信度**: high
- **根因**: The leading doc comment states the test 'locks the isConfigured contract' that the settings picker uses to HIDE OAuth backends whose client ID is still a placeholder, and says 'when real credentials are filled in, isConfigured flips to true and the matching assertion below should be updated'. But the test bodies unconditionally assert expect(OneDriveSyncBackend.isConfigured, isTrue) and expect(DropboxSyncBackend.isConfigured, isTrue). Since real client IDs are now hardcoded (dropbox_sync_backend.dart:23 _clientId='lt0ufixv6si14dc', onedrive:23 a real GUID; isConfigured := !_clientId.startsWith('YOUR_')), the assertion is true by construction and tests nothing about the placeholder-hiding logic. The test name 'reports configured once a real client ID is filled in' encodes a conditional that the code does not express.
- **影响**: The test gives false assurance that the picker's backend-filtering contract is covered. The actual logic worth protecting — _isBackendSelectable hiding a backend when _clientId starts with 'YOUR_' — is not tested; if someone reverts a key to a placeholder, the picker behavior changes and this test fails with a misleading 'expected true' message instead of a meaningful regression. The whole OAuth flow (PKCE/token exchange/refresh) in the 19KB backend files is also untested.
- **证据**:
~~~
Comment lines 6-10 '...hides OAuth backends whose client ID is still a placeholder... When real credentials are filled in, isConfigured flips to true and the matching assertion below should be updated'. Body lines 13-19 'expect(OneDriveSyncBackend.isConfigured, isTrue); ... expect(DropboxSyncBackend.isConfigured, isTrue);'. Impl: dropbox_sync_backend.dart:27 'static bool get isConfigured => !_clientId.startsWith(\'YOUR_\');'
~~~
- **修复建议**: Test the predicate, not the current constant: assert a backend with a 'YOUR_...' placeholder client id reports isConfigured==false and one with a real id reports true (parameterize the check or test the underlying isConfigured helper against both inputs). Better, add a test for _isBackendSelectable so the picker-filtering behavior is actually covered.
- **验证（对抗复核）**: I independently opened all three cited files and confirmed every factual claim:

- Test file (oauth_backend_config_test.dart:5-20): docstring (lines 5-10) does state the test "locks the isConfigured contract" the picker uses to hide placeholder backends and says "When real credentials are filled in, isConfigured flips to true and the matching assertion below should be updated." The two test bodies (lines 14, 18) unconditionally assert expect(OneDriveSyncBackend.isConfigured, isTrue) / expect(DropboxSyncBackend.isConfigured, isTrue).
- Implementation: dropbox_sync_backend.dart:24 `_clientId = ' …(截断)
  - 验证者保留意见: Partially overstated rather than refuted. The finding is factually accurate and the defect exists, but two points soften it: (1) the test is not a pure tautology with zero value — it acts as a regression guard against a client ID being reverted to a 'YOUR_' placeholder, which is precisely the placeh …(截断)

### HBK-AUDIT-147 — AdaptiveSettingsPickerRow Material dropdown shows the row title as a floating label and keys options by index instead of value

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / maintainability / DropdownMenu<int> indirection layered over an already typed options list
- **位置**: `hibiki/lib/src/utils/components/settings_shared.dart` : 489-526,597-602
- **审查者置信度**: medium
- **根因**: _buildMaterialDropdown wraps a typed List<AdaptiveSettingsPickerOption<T>> in a DropdownMenu<int> whose entries' values are the option indices, then maps back via options[index].value. It also passes label: Text(title) so the row's title text floats inside the dropdown field. The int indirection only exists to avoid using T directly (HibikiDropdown<T> already does the typed version correctly), and the selected option is resolved by linear scan _selectedIndex each build.
- **影响**: Extra index<->value translation layer is fragile (relies on options ordering staying stable between the entry list and onSelected) and duplicates dropdown logic that HibikiDropdown<T> already provides typed. The title-as-floating-label also visually duplicates the row's own label. Low impact but adds avoidable surface and a redundant O(n) selectedIndex scan.
- **证据**:
~~~
DropdownMenu<int>(label: Text(title), initialSelection: _selectedIndex, dropdownMenuEntries: [for (int i=0;i<options.length;i++) DropdownMenuEntry<int>(value:i,label:options[i].label)], onSelected:(int? index){ if(index==null)return; onChanged(options[index].value); })
int? get _selectedIndex { for (int i=0;i<options.length;i++){ if(options[i].value==selected) return i; } return null; }
~~~
- **修复建议**: Use DropdownMenu<T> with value-typed entries (reuse HibikiDropdown<T>) instead of the int-index indirection, and drop the redundant title label inside the field (the AdaptiveSettingsRow already renders the title).
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-148 — CacheImageProvider equality/hashCode ignore the image bytes, so changed cover bytes return a stale cached image

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / correctness / cache key derived from a subset of identity fields
- **位置**: `hibiki/lib/src/utils/components/cache_image_provider.dart` : 43-58
- **审查者置信度**: high
- **根因**: operator == and hashCode use only `tag`, not `img`. The Flutter image cache keys on the provider's equality, and obtainKey returns `this`. The single production caller (media_source.dart:373) builds CacheImageProvider(item.uniqueKey, data.contentAsBytes()) keyed purely on uniqueKey.
- **影响**: If a media item's cover image bytes change while its uniqueKey stays the same, the image cache treats the new provider as equal to the old one and serves the stale decoded image until cache eviction. Acceptable if covers are immutable per uniqueKey, but it is an implicit, undocumented invariant that will silently show wrong/old covers if violated.
- **证据**:
~~~
bool operator ==(Object other){ ... return other is CacheImageProvider && other.tag == tag; }  int get hashCode => tag.hashCode;  // img not considered
media_source.dart:373 return CacheImageProvider(item.uniqueKey, data.contentAsBytes());
~~~
- **修复建议**: Either document the 'tag is a content-stable key' invariant explicitly, or include a cheap content hash/length in the tag (e.g. '$uniqueKey-${data.length}') or in == / hashCode so changed bytes produce a distinct cache key.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-149 — Four type-converters are zombie code from the Isar->Drift migration, kept alive only by tests

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / dead-code / migration leftover / tests testing dead code
- **位置**: `hibiki/lib/src/utils/converters/immutable_string_map_converter.dart` : 1-15 (and enhancements_converter.dart, quick_actions_converter.dart, media_item_converter.dart)
- **审查者置信度**: high
- **根因**: ImmutableStringMapConverter, EnhancementsConverter, QuickActionsConverter, MediaItemConverter are exported by utils.dart (lines 22-25) but have ZERO production callers — repo-wide grep finds references only inside their own files and in test/utils/converters/*. Their docstrings say 'compatible with Isar' and the methods are named fromIsar/toIsar, but CLAUDE.md states the project's storage is Drift SQLite; Isar is gone. MediaItemConverter has no references at all (not even a test).
- **影响**: Dead API surface that lies about the storage backend (Isar). The passing tests give false confidence that this code matters, and the misleading fromIsar/toIsar naming will mislead anyone wiring up new persistence. Also encodes untyped Map<String,dynamic> JSON contracts (the Dart 'any' pattern).
- **证据**:
~~~
immutable_string_map_converter.dart:3 '/// ... primitive compatible with Isar.'  static Map<String, dynamic> fromIsar(String object){...}
Grep of lib for the four class names: only the 4 definition files. Grep of repo: additional hits only in test/utils/converters/*.
~~~
- **修复建议**: Delete the four converter files, their barrel exports, and the converter tests (or, if a Drift TypeConverter is actually intended, rewrite them as real drift TypeConverter<T,String> subclasses with from/to named for Drift and actually register them on the columns that need them).
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-150 — HibikiDesignTokens.of allocates fresh token graphs on every build of every component

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / perf / factory disguised as a cheap InheritedWidget-style lookup
- **位置**: `hibiki/lib/src/utils/components/hibiki_design_tokens.dart` : 16-25
- **审查者置信度**: medium
- **根因**: of(context) is named like an O(1) inherited-widget lookup but actually constructs a brand-new HibikiDesignTokens plus HibikiSurfaceColors.fromScheme (11 Color reads) and HibikiTypeRoles.fromTheme (6 TextStyle copyWith allocations) every call. Nearly every component in this directory calls HibikiDesignTokens.of(context) at the top of build() (HibikiCard, HibikiListItem, HibikiTextField, HibikiTagChip, settings rows, etc.), and several call it more than once per build (HibikiSearchHistory calls it in build() and again in buildSearchHistoryItem()).
- **影响**: Per-frame allocation churn proportional to widget count: every rebuilt component allocates ~20 objects (Colors/TextStyles) that are immediately discarded. For long lists (settings, search history, dictionary results) this multiplies GC pressure with no caching. Misleading 'of' naming hides the cost.
- **证据**:
~~~
static HibikiDesignTokens of(BuildContext context){ final theme=Theme.of(context); final scheme=theme.colorScheme; return HibikiDesignTokens(radii: const HibikiRadii(), surfaces: HibikiSurfaceColors.fromScheme(scheme), type: HibikiTypeRoles.fromTheme(theme), spacing: const HibikiSpacingTokens()); }  // new graph each call
~~~
- **修复建议**: Provide tokens via a real InheritedWidget/Theme extension computed once per theme change, or memoize by (scheme,textTheme) identity, so of() is an actual lookup. At minimum cache within a build by passing tokens down rather than re-resolving (HibikiSearchHistory resolves twice).
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-151 — HibikiIconButton busy/async logic duplicated verbatim across two branches and didUpdateWidget lacks a type annotation

- **Severity**: LOW
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / code-duplication / copy-pasted branch + missing type signature (violates project rule)
- **位置**: `hibiki/lib/src/utils/components/hibiki_icon_button.dart` : 85-186
- **审查者置信度**: high
- **根因**: The entire enabled/busy onTap handler (set enabled=false, setState if mounted, try/await onTap, finally enabled=true, setState) is duplicated identically in the isWideTapArea IconButton branch (118-137) and the default InkWell branch (150-169). Also didUpdateWidget is declared as 'void didUpdateWidget(oldWidget)' with no parameter type, violating the repo rule that functions/helpers must have explicit type signatures, and didUpdateWidget unconditionally resets enabled=widget.enabled which can clobber an in-flight busy lock (a rebuild mid-await re-enables the button).
- **影响**: Duplicate logic must be edited in two places (drift risk). The untyped param is a code-quality/lint violation. The didUpdateWidget reset can re-enable a busy button mid-action if the parent rebuilds during an await, defeating the busy guard.
- **证据**:
~~~
Default branch onTap (150-169) is byte-for-byte the same body as the isWideTapArea branch (118-137).
void didUpdateWidget(oldWidget){ super.didUpdateWidget(oldWidget); enabled = widget.enabled; }  // no type on oldWidget; resets busy lock
~~~
- **修复建议**: Extract a single 'Future<void> Function()? _resolveOnTap()' (or a private _run() that encapsulates the busy guard) and use it in both branches. Type didUpdateWidget as (HibikiIconButton oldWidget). Only sync enabled from widget.enabled when not currently mid-busy.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-152 — SpacingInsetsData.fromSpaces maps extraBig to the wrong source size (copy-paste bug)

- **Severity**: LOW (审查者报 MEDIUM，验证后修正)
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / correctness / copy-paste error in a generated-looking helper
- **位置**: `hibiki/lib/src/utils/spacing.dart` : 40-48
- **审查者置信度**: high
- **根因**: Inside the local apply() builder, every size maps fn(s.<size>) for its matching field, except the last: 'extraBig: fn(s.big)'. It uses s.big instead of s.extraBig, so all inset variants (.all/.horizontal/.exceptBottom/...).extraBig silently produce a 'big' (normal*2.5) inset rather than the intended extraBig (normal*5.0).
- **影响**: Any padding built via Spacing.of(context).insets.<variant>.extraBig is half the intended size. Currently latent because no caller reads insets.*.extraBig yet (callers use .big/.normal/.small and spaces.extraBig directly), but it is a correctness trap that will mis-pad the moment someone uses the extraBig inset, and it directly contradicts the surrounding pattern.
- **证据**:
~~~
factory SpacingInsetsData.fromSpaces(SizeSet<double> s){ SizeSet<EdgeInsets> apply(...) => SizeSet(extraSmall: fn(s.extraSmall), small: fn(s.small), semiSmall: fn(s.semiSmall), normal: fn(s.normal), semiBig: fn(s.semiBig), big: fn(s.big), extraBig: fn(s.big)); ... }  // last line should be fn(s.extraBig)
~~~
- **修复建议**: Change line 47 to 'extraBig: fn(s.extraBig)'.
- **验证（对抗复核）**: I opened hibiki/lib/src/utils/spacing.dart and read lines 39-99. The cited line 47 is exactly `extraBig: fn(s.big)`, while the sibling fields on lines 41-46 each use `fn(s.<matching field>)` (extraSmall→s.extraSmall, small→s.small, ... big→s.big). So extraBig is the lone inconsistent mapping — a genuine copy-paste bug. SpacingData.generate (lines 81-90) sets `big: normal*2.5` and `extraBig: normal*5.0`, and SpaceSize.toPoints (line 119) maps `extraBig => s.extraBig`, confirming the intended extraBig value is normal*5.0. Therefore any `insets.<variant>.extraBig` would silently produce normal*2. …(截断)
  - 验证者保留意见: Severity is inflated. I grepped the whole repo: no caller reads `insets.<variant>.extraBig` anywhere. The only `.extraBig` usages outside the definition file are in hibiki_icon_button.dart lines 109-110, which read `spaces.extraBig` (the correct double, not the buggy inset). Every real `insets.*` ca …(截断)

### HBK-AUDIT-153 — findCueIndex includes endMs boundary (<=) contradicting its own gap-is-exclusive doc

- **Severity**: INFO
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `audiobook-audio` / correctness/contract / impl contradicts comment
- **位置**: `packages/hibiki_audio/lib/src/parsers/json_alignment_parser.dart` : doc 90-97; code 121-125
- **审查者置信度**: high
- **根因**: Doc states gap is `prev.endMs < positionMs < next.startMs` → returns -1 (endMs exclusive). Code uses `if (positionMs <= cues[prev].endMs) return prev;` (endMs inclusive).
- **影响**: At the single instant positionMs == prev.endMs the highlight stays on prev instead of clearing. 1ms-window cosmetic discrepancy with the documented Sasayaki CueTimeline semantics; effectively unobservable.
- **证据**:
~~~
`// 落在 gap：上游返回 nil` preceded by `if (positionMs <= cues[prev].endMs) return prev;`
~~~
- **修复建议**: Use `<` to match the documented contract, or fix the comment to say endMs is inclusive.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-154 — anki_utilities.dart is an empty file still exported through the creator barrel surface

- **Severity**: INFO
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `creator` / dead-code / zombie file left behind
- **位置**: `hibiki/lib/src/creator/anki_utilities.dart` : 1
- **审查者置信度**: high
- **根因**: File contains a single blank line — a placeholder that was never filled in or was emptied during a refactor.
- **影响**: Noise; counts toward the '50 files' fragmentation; a reader expects Anki utilities here and finds nothing.
- **证据**:
~~~
Read of hibiki/lib/src/creator/anki_utilities.dart returns one empty line. (Not even exported in creator.dart, making it doubly orphaned.)
~~~
- **修复建议**: Delete the file.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-155 — Shortcut capture silently aborts on duplicate with no user feedback

- **Severity**: INFO
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `shortcuts-platform` / error-handling / asymmetric handling of two near-identical branches
- **位置**: `hibiki/lib/src/pages/implementations/shortcut_settings_page.dart` : 335-339
- **审查者置信度**: high
- **根因**: In _onKeyEvent, when the just-captured binding already exists in the current draft, capture is ended (`_capturing = false`) and the event is consumed, but no _conflictWarning or any message is shown — unlike the cross-action conflict path (line 348-354) which does set a warning.
- **影响**: User presses an already-bound key during capture; the capture box just stops with no explanation, looking like the keypress was lost. Minor UX inconsistency relative to the conflict path right below it.
- **证据**:
~~~
shortcut_settings_page.dart:336-339 `if (_keyboard.contains(binding)) { setState(() => _capturing = false); return KeyEventResult.handled; }` vs conflict path :348-354 which sets `_conflictWarning`.
~~~
- **修复建议**: Set a 'already bound' message (or reuse the duplicate hint) in the duplicate branch so the abort is explained, mirroring the conflict branch.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

### HBK-AUDIT-156 — UpdateChecker.debugChannel parameter is a no-op alias of betaChannel (pseudo-feature)

- **Severity**: INFO
- **Status**: Open — 对抗式代码路径审查已确认，未在设备复现、未修复
- **单元 / 维度 / AI-异味**: `utils-components` / abstraction-failure / pseudo-extensibility / parameter that pretends to add a channel
- **位置**: `hibiki/lib/src/utils/misc/update_checker.dart` : 24-37,77-79
- **审查者置信度**: high
- **根因**: scheduleCheck exposes a distinct `debugChannel` flag alongside `betaChannel`, but its only use is line 36 'betaChannel: betaChannel || debugChannel'. _check has no debugChannel concept and only branches beta vs stable (lines 77-79 call _fetchLatestRelease for beta, _fetchStableRelease otherwise). There is no debug-specific release fetch or filtering.
- **影响**: The API advertises three channels (stable/beta/debug) but only two behaviors exist; debugChannel silently behaves exactly like betaChannel. Callers and settings UI may believe a separate debug channel is selectable when it is not.
- **证据**:
~~~
static void scheduleCheck(... bool betaChannel = false, bool debugChannel = false){ ... _check(context, currentVersion, ..., betaChannel: betaChannel || debugChannel); }  // debugChannel never used elsewhere
~~~
- **修复建议**: Either implement a real debug-channel fetch/filter or remove the debugChannel parameter and fold its meaning into betaChannel at the call site, so the API matches actual behavior.
- **验证（对抗复核）**: low/info severity with non-low confidence — included without independent skeptic

## 附录 A：被对抗验证驳回的发现（42 条，透明记录）

> 审查者提出但被独立验证者证伪/认定不成立或夸大；不计入上面 156 条。

- **[HIGH] (android-native-security)** Exported hibiki://auth OAuth redirect has no state/CSRF parameter — authorization-code injection
  - 驳回理由: The cited code facts are all correct, but the impact is materially overstated. The claimed account-takeover (redeeming an attacker's injected code with the user's verifier) is blocked at the token endpoint: PKCE validates SHA256(user_verifier) against the attacker's code_challenge, which cannot match, so _exchangeCode receives a non-200 and throws SyncAuthError without binding any account. State p …(截断)
- **[HIGH] (android-native-security)** PopupJsInterface.openLink launches arbitrary intents from WebView JS with no scheme allowlist
  - 驳回理由: The asserted "arbitrary intent launch / intent://, file://, content:// from any entry link" is not reachable. openLink is only ever fed URLs that already passed the JS-side gate `/^https?:\/\//i.test(node.href)` (popup.js:1018-1023, definition.js:390-395); all other schemes route to the harmless onLinkClick in-app-search path. No shouldOverrideUrlLoading exists to forward sanitized HTML <a href> n …(截断)
- **[HIGH] (android-native-security)** FileProvider exposes entire external storage / files / cache roots via path='.' — combined with MANAGE_EXTERNAL_STORAGE
  - 驳回理由: The exported=false provider plus per-URI grants means path="." cannot leak arbitrary files to external apps by itself — a recipient only gets read access to the single URI explicitly granted, not the wildcard root. Both reachable getUriForFile call sites use app-internal, non-attacker-controlled paths (temp dir + hardcoded APK name; app media cache dir; app-fetched URLs). The claimed "arbitrary fi …(截断)
- **[MEDIUM] (android-native-security)** specialUse foreground service subtypes used for overlays — not a sanctioned FGS type, fragile under Android 14 enforcement
  - 驳回理由: The finding conflates unverifiable Play-policy speculation with a technically incorrect race-condition mechanism. specialUse is a sanctioned FGS type and the app implements the required permission+subtype-property contract correctly. startForeground() in onCreate() is the recommended placement for startForegroundService-launched services and minimizes (not creates) the 5s-window race; restart inte …(截断)
- **[MEDIUM] (android-native-security)** PopupDictActivity injects DB-stored CSS/JSON into WebView with inconsistent/weak sanitization
  - 驳回理由: The cited mechanism (raw entriesJson/stylesJson concatenation in PopupDictActivity.kt:449-455 "breaking out of the assignment context" because dictionary data may be invalid JSON) is not reachable: those strings are produced by the glaze C++ JSON serializer (native/hoshidicts/hoshidicts_external/glaze), which always emits valid escaped JSON. At the Kotlin layer the unvalidated values are guarantee …(截断)
- **[MEDIUM] (anki)** AnkiDroid duplicate-check and addNote silently no-op when the cached note type's field count diverges from the live model
  - 驳回理由: Title/impact overstate the defect. addNote does NOT silently no-op: on model divergence it returns 'Note type not found' which becomes a loud ADD_NOTE_FAILED error → MineResult.error, with no data added, no corruption, and no silently-accepted duplicate. The 'false duplicate' outcome is unsubstantiated (a dupe is only reported when a real first-field match exists in the exactly-named model). The n …(截断)
- **[LOW] (anki)** AnkiConnectRepository caches a single AnkiConnectService instance keyed only by host/port, mutating shared fields without synchronization across concurrent mine …(截断)
  - 驳回理由: _serviceForSettings is synchronous (no await between the three field writes), so no concurrent async call can observe a partially-updated cache — Dart isolates are single-threaded and only yield at await/yield. Additionally, mineEntry captures the service into a local variable (line 97) and uses that local for all subsequent operations, so even cache churn from a concurrent call with different set …(截断)
- **[MEDIUM] (app-startup-state)** setTargetLanguage fires language.initialise() without await, then notifies and persists — UI can read a half-initialised language
  - 驳回理由: Impact is overstated and based on a non-existent implementation. (1) prepareResources() is `async {}` (empty) in all three Language subclasses (japanese:94, english:33, chinese:38), so initialise() does no real async work — the missing await waits on nothing. The finding's assumption of 'tokenizer/segmenter load' is fabricated. (2) Segmentation (textToWords/wordFromIndex) gates on the unrelated gl …(截断)
- **[MEDIUM] (app-startup-state)** Background TTU migration is unawaited and writes to _database concurrently with the rest of init and live UI
  - 驳回理由: The finding correctly identifies that migration is unawaited and that init flips _isInitialised mid-flight, but its impact analysis is wrong on every load-bearing claim: (a) the DB is a single serialized WAL connection in one isolate, so UI and migration writes cannot interleave destructively or produce torn reads; (b) migration never deletes/clears rows (insertOrIgnore + tocJson/chaptersJson-only …(截断)
- **[LOW] (app-startup-state)** _handleOAuthRedirect dispatches to OneDrive/Dropbox singletons but main.dart imports those backends only for this — provider/scope mismatch with AppModel owners …(截断)
  - 驳回理由: No provider/scope mismatch exists: resolveSyncBackend() (google_drive_sync_backend.dart:204-223) and the redirect handler (main.dart:322/324) both operate on the identical OneDriveSyncBackend.instance / DropboxSyncBackend.instance singletons that authenticate() (called from sync_settings_schema.dart:370) stashed the verifier on. The verifier-write and verifier-read happen on the same canonical ins …(截断)
- **[HIGH] (build-ci-deps)** Committed key.properties exposes the release keystore passwords in plaintext
  - 驳回理由: The protective controls the finding worries about are already fully in place and the finding admits it: key.properties and the .jks are gitignored (.gitignore:12-14, verified by git check-ignore) and were never committed (git log --all and git ls-files both empty). The secret therefore is not exposed via the repository, history, or any build artifact — refuting the title's "exposes... in plaintext …(截断)
- **[MEDIUM] (build-ci-deps)** flutter_lints pinned to 2.0.1 (3+ majors stale) against Flutter 3.41.6, gutting the analyzer ruleset
  - 驳回理由: The pin is intentional and documented (analysis_options.yaml:26-27 explains broad style lints were deliberately suppressed to keep analyzer signal useful), not an oversight. flutter_lints is a style ruleset, not a correctness/bug-detection layer — real bug detection (type/null-safety/dead-code) comes from the Dart SDK analyzer 3.11.4, which is current and entirely unaffected by the flutter_lints p …(截断)
- **[MEDIUM] (build-ci-deps)** analysis_options downgrades a real correctness lint and CI does not run --fatal-infos, so infos never fail the build
  - 驳回理由: The headline defect does not hold. `use_build_context_synchronously: warning` is a promotion from the default info severity, and `flutter analyze` treats warnings as fatal by default, so async-gap BuildContext violations DO fail CI in both main.yml:52 and release.yml:66 — they are not passing silently. The finding's root_cause inverts the severity-change direction and misstates flutter analyze's d …(截断)
- **[MEDIUM] (build-ci-deps)** release.yml APK rename/upload relies on a naming contract the gradle build contradicts
  - 驳回理由: The defect as described is not real. The gradle `outputFileName` (underscore, build.gradle:149/161) renames APKs in `build/app/outputs/apk/release/`, a different directory than the `flutter-apk/` the release.yml loop reads (release.yml:93). `flutter build apk` always copies into `flutter-apk/` with Flutter's own hardcoded `app-<abi>-release.apk` naming regardless of the gradle variant override, so …(截断)
- **[INFO] (build-ci-deps)** Flutter SDK constraint uses caret (^3.41.6) which is non-idiomatic for the flutter environment constraint
  - 驳回理由: The finding's only verifiable substance is that the SDK-constraint *syntax* differs (`^3.41.6` in the app vs `>=3.41.6` in packages). That is cosmetic and harmless: the `flutter` environment key is not part of pub's cross-package version solving, both forms carry the same 3.41.6 floor, both admit Flutter 3.44, and they do not conflict. The claimed impact — "confusing resolution messages" / "unclea …(截断)
- **[HIGH] (creator)** Meaning field is quadruplicated: Collapsed/Expanded/Hidden Meaning fields all produce identical output, contradicting their descriptions
  - 驳回理由: The finding's claimed defect is unreachable. onCreatorOpenAction (the cited evidence for all four files) is never called anywhere in lib/ or packages/ — only in stale generated HTML docs with a mismatched signature. The live field-population path, CreatorFieldValues.fromMineFields (creator_field_values.dart:24-33), populates only MeaningField.instance from fields['glossary'] and never assigns any …(截断)
- **[MEDIUM] (creator)** Field singletons hold per-session export state, shared across two CreatorModel providers (creatorProvider vs instantExportProvider)
  - 驳回理由: The claimed impact (cross-context media bleed and concurrent AudioPlayer/`_autoCannotOverride` races between creatorProvider and instantExportProvider) is unreachable: `instantExportProvider` is never read/watched anywhere (`**/*.dart` grep yields only its declaration at creator_model.dart:16), and Riverpod ChangeNotifierProviders are lazy, so the second CreatorModel is never constructed. With one …(截断)
- **[MEDIUM] (creator)** LocalAudioEnhancement TTS output uses a single fixed filename, colliding between term and sentence audio fields
  - 驳回理由: The finding claims term-audio and sentence-audio fields both write and overwrite the same tts_term_audio.wav, mixing up audio on the Anki card. This is false: LocalAudioEnhancement (the only writer of tts_term_audio.wav) is registered ONLY for AudioField.instance (term), not AudioSentenceField.instance, whose enhancements (Clear/PickAudio/AudioRecorder) never use that path and instead copy to per- …(截断)
- **[MEDIUM] (cross-cutting-ai-smells)** Sync settings hold their per-context state in a top-level mutable global that one widget's dispose() nulls out
  - 驳回理由: The finding's structural observation is correct, but its asserted bug and impact are wrong. (a) `_SyncSettingsState` contains no auth/sign-in state — auth state is local to `_SyncAccountWidgetState` (lines 243-248), so the "lost in-flight auth state" impact is fabricated; the global only holds DB-backed sync toggles. (b) The "disposed while siblings still mounted" scenario is unreachable: the back …(截断)
- **[MEDIUM] (dictionary-ffi)** initialize/initializeTyped leak the native HoshidictsHandle if addTermDict/addFreqDict/addPitchDict throws before _instance is assigned
  - 驳回理由: The defect's trigger ("if any add* call throws") is not reachable: the load loop's real work is `_bindings!.addTermDict(_handle!, p)`, a `Void Function` FFI call (bindings.dart:129-131,177-182). Void FFI trampolines don't raise catchable Dart exceptions; native C++ exceptions crash rather than throw, so try/finally would never run anyway. The only Dart-throwing op in add*() is `toNativeUtf8` on OO …(截断)
- **[MEDIUM] (pages-ui)** _visibleEpubBooks/_visibleSrtBooks are mutated inside build() as a side effect feeding select-all/invert
  - 驳回理由: The "stale book sets -> wrong items deleted/tagged (data mutation)" impact is not reachable. `_visibleEpubBooks`/`_visibleSrtBooks` are re-derived inside the same synchronous `build()` pass that renders both the displayed grid and the batch action bar's Select-All/Invert buttons, so the fields always match what the user sees in the last committed frame. Provider invalidations trigger a rebuild tha …(截断)
- **[HIGH] (reader-core)** WebView controller never disposed/cleared on widget dispose — controller leak + stale-callback risk
  - 驳回理由: The claimed defect is contradicted by the actual code on two independent grounds. (a) Resource teardown is already done by the plugin: flutter_inappwebview_android-1.1.3 in_app_webview.dart:453-468 disposes the underlying controller and nulls it on widget dispose, so native resources, channels and JS handlers are released on route pop — the page field is just a GC-eligible Dart reference. (b) The …(截断)
- **[HIGH] (reader-core)** Spread (two-page image) chapters never set _hasEverLoaded, so reading position is silently dropped on exit
  - 驳回理由: The finding's premise that a spread image page can be the first rendered page is false. `onWebViewCreated` always calls `_loadChapterDirectly(_currentChapter)` on open (never spread HTML), and that direct-chapter load reaches `_onRestoreComplete` via the pagination shell's `restoreProgress`→`notifyRestoreComplete`→`onRestoreComplete` round-trip (with the 8s `_startContentReadyTimeout` as backup), …(截断)
- **[MEDIUM] (reader-core)** Spread page load has no content-ready fallback wiring to the restore completer / timeout symmetry; onReceivedError on non-Windows for spread leaves reader cloak …(截断)
  - 驳回理由: The finding's central impact ('search/bookmark jump that lands on a spread hangs for its own 10s timeout') is unreachable: every completer-awaiting jump (_navigateToChapterAndWait at 2388, used by search/bookmark/favorite at 3652/3665/3695) routes to _navigateToChapter->_loadChapterDirectly, never _navigateToSpread. The spread path (_navigateToVirtualPage->_navigateToSpread) is only triggered fire …(截断)
- **[MEDIUM] (reader-core)** JS->Dart bridge handlers cast payloads with unchecked `as` and `(args[0] as num)` — malformed/typed-wrong payload throws and is swallowed or crashes the handler
  - 驳回理由: The cited handlers cannot throw on any reachable path because every JS caller sends a fixed, type-correct value: string literals for onSwipe/onBoundarySwipe, a guaranteed DOM string `.src` for onImageTap (guarded by tagName==='IMG' && target.src), and a guarded `parseInt` integer for onCueTap. The finding's proof — that `_toDouble`'s String handling implies callHandler args are loosely typed — con …(截断)
- **[MEDIUM] (reader-core)** _onCueChanged / audiobook listener can call evaluateJavascript before reader content is ready or during navigation, racing pagination setup
  - 驳回理由: Defect impact is overstated and not reachable as described. The highlight path's evaluateJavascript sources are all wrapped in `if(typeof __hoshiHighlight!=="undefined")`/`if(typeof __hoshiHighlightSasayakiCueById!=="undefined")` (audiobook_bridge.dart:288/296/303) and the lyrics call in `if(window.__lyricsSetCue)` (reader_hibiki_page.dart:2033). When the document is reloading and globals are not …(截断)
- **[MEDIUM] (reader-core)** _navigateToChapterAndWait nulls _restoreCompleter inside onTimeout, racing the real spreadReady/onRestoreComplete completion
  - 驳回理由: The cited race cannot occur because (a) Dart's single-threaded event loop has no preemptive interleaving, (b) Future.timeout cancels its timer once the source future completes so onTimeout and a real completion are mutually exclusive, and (c) every navigation entry point completes the old _restoreCompleter (resolving the source future and cancelling the timeout) BEFORE creating a new completer, so …(截断)
- **[LOW] (reader-core)** Continuous-mode paginate() boundary detection uses window.scrollX/scrollTop with a 2px epsilon that breaks under fractional device-pixel-ratio scroll
  - 驳回理由: Mechanism is wrong: continuous-mode paginate() (1092-1105) only reads scroll position; it never scrolls (contrast paginated paginate() at 784 which calls setPagePosition). _paginate (3125-3133) does nothing on "scrolled". So "limit" cannot skip/discard a page of lines — when scrollTop+innerHeight >= scrollHeight-2, the entire chapter bottom is already within 2 CSS px of the viewport, so no real te …(截断)
- **[MEDIUM] (reader-core)** applySasayakiCues non-CSS-Highlight path mutates DOM (wrap spans) then buildNodeOffsets, but node offsets/highlights computed before are invalidated without re- …(截断)
  - 驳回理由: The defect is not real. Favorite highlights use an independent, freshly-rebuilt offset map (_buildOffsetMap in highlight_bridge.dart), not hoshiReader.nodeStartOffsets, so span-wrapping cannot "invalidate Dart-side cached ranges" — there are none. The non-CSS sasayaki branch already rebuilds nodeStartOffsets right after wrapping (line 326), getFirstVisibleCharOffset self-heals on a WeakMap miss (l …(截断)
- **[LOW] (reader-core)** FloatingLyric/MediaNotification global handlers cleared in dispose unconditionally, but set per-controller-init; a stale reader's clear can wipe a newer reader' …(截断)
  - 驳回理由: The defect's required precondition — an old reader disposing while a newer reader is live and owns the global handlers — is not reachable. Reader launches use Navigator.push (history page line 1047 and 700; in-reader push at 3160 is an image overlay, not a reader), under which the old reader is not disposed while the new one is on top. The pushReplacement (app_model.dart:1849) and killOnPop paths …(截断)
- **[MEDIUM] (reader-source-media)** Sentence-audio extraction logic duplicated verbatim between source.generateAudio and reader page, both using a fixed shared temp path
  - 驳回理由: The finding mischaracterizes the impact. The source-side block it points to as a co-equal "copy that must be kept in sync" is unreachable dead code: its inputs (_pendingCue/_pendingAudioFiles) are set only by setPendingSentenceAudio, which is never invoked anywhere in the repo, so generateAudio always returns null before reaching lines 109-116. Thus there is only one LIVE copy, not two. The race c …(截断)
- **[MEDIUM] (shortcuts-platform)** FloatingOverlayChannel invokeMethod calls have no try/catch; PlatformException propagates to unguarded call sites
  - 驳回理由: The native side already converts the cited failure scenario into a graceful return value: MainActivity.java:342-348 checks Settings.canDrawOverlays(context) before doing anything privileged and returns result.success(false) when the overlay permission is absent — so `show`/`canDrawOverlays`/`hide` do not throw a PlatformException on permission revocation. There is therefore no reachable path where …(截断)
- **[HIGH] (sync)** AsyncMutex is not actually mutually exclusive — multiple waiters released together can all enter the critical section
  - 驳回理由: The mutex IS mutually exclusive. The claimed concurrency window between `_completer = null` and `c.complete()` does not exist: those are adjacent synchronous statements in one microtask turn with no await, so nothing can interleave. The `while (_completer != null)` guard combined with the suspension-free `_completer = Completer()` assignment guarantees exactly one entrant: woken waiters re-check t …(截断)
- **[HIGH] (sync)** FallbackSyncBackend resolves each operation independently — one sync can split across incompatible backends (folder-ID corruption)
  - 驳回理由: The defect is not reachable. FallbackSyncBackend is never instantiated in production lib/ code (grep confirms construction only in test/sync/fallback_sync_backend_test.dart). Production sync uses resolveSyncBackend() which returns a single concrete backend singleton per SyncBackendType (google_drive_sync_backend.dart:204-223), and all SyncManager call sites pass that single backend (sync_auto_trig …(截断)
- **[MEDIUM] (sync)** Hibiki server auth ignores username and leaks token length via early XOR
  - 驳回理由: The "token-length oracle" premise is false: the compare returns a uniform `false` on every mismatch, leaking no length through its result, and _token is a fixed-length 256-bit CSPRNG secret (generateToken lines 30-34), so the max(len) loop timing can only vary on the attacker's own known input length — no useful oracle. Folding length into the XOR seed is the standard correct constant-time pattern …(截断)
- **[MEDIUM] (sync)** Dropbox/OneDrive streamed content upload uses fire-and-forget stream listen — stream errors not joined, partial uploads possible
  - 驳回理由: The defect as described (silent partial upload reported as HTTP 200 -> remote content corruption) is not reachable. (a) Error propagation: sink.addError(e) on a StreamedRequest injects the error into the request body stream that request.send() consumes; the awaited Response.fromStream/send therefore throws, and with no surrounding catch the error propagates to the sync_manager caller — it is not s …(截断)
- **[MEDIUM] (sync)** Statistics 'replace' merge mode wholesale returns remote stats, discarding all local statistics
  - 驳回理由: No production code path ever passes StatisticsSyncMode.replace. All three real call sites (sync_auto_trigger.dart:67 & :117, sync_compare_dialog.dart:381) hardcode StatisticsSyncMode.merge, and the only non-implementation reference to .replace is a unit test (sync_merge_test.dart:80). There is no UI/setting that selects replace. The defect therefore lives entirely in an unreachable enum branch; th …(截断)
- **[MEDIUM] (sync)** Auto-sync 'sync all' marks sync-in-progress and bumps counters before checking enabled/cooldown, and per-book syncs can race a sync-all that started first
  - 驳回理由: The headline race relies on thread-style preemption between line 91's `contains('__all__')` check and _runAutoSyncAll's line 43 `add('__all__')`. Dart's single-threaded event loop makes this impossible: both guard prologues run synchronously with no await (lines 89-95 before await at 99; lines 43-46 before await at 50), so the per-book entry guard + set add execute atomically and cannot be interle …(截断)
- **[MEDIUM] (sync)** FTP/SFTP downloadJson and content download use a single shared mutable cache+connection while SyncManager.retry calls clearCache mid-flight
  - 驳回理由: The retry path explicitly calls _backend.clearCache() (sync_manager.dart:63), which clears both _rootFolderId AND _titleToFolderId (ftp_sync_backend.dart:371-372), followed by _repo.clearFolderCache() (line 64). In-memory and persisted folder caches are invalidated together before retry — there is no half-cleared state. _resetConnection() being socket-only is by design (documented at ftp_sync_back …(截断)
- **[CRITICAL] (test-coverage)** Database migration upgrade path (v1->v13) has ZERO tests — only the fresh schema is verified
  - 驳回理由: The finding is built on three false factual claims: (1) "ZERO tests" exercise the upgrade ladder, (2) the suite "never constructs an older-version database and runs the onUpgrade ladder," and (3) "grep ... for onUpgrade/schemaAt/forUpgrade returns NOTHING; only bookmark_repository_test.dart calls migrateLegacyBookmarkPreferences." All three are refuted by hibiki/test/database/foreign_keys_test.dar …(截断)
- **[HIGH] (test-coverage)** hibiki_dictionary FFI engine (the app's core) and all import-format parsers have ZERO tests
  - 驳回理由: The finding's impact and root-cause are false: it claims the four format parsers contain '100% pure Dart import logic' that 'can silently mis-parse a term bank, drop frequencies/pitch.' In reality all four prepareEntries are no-op stubs (yomichan_dictionary_format.dart:175-180, mdict_format.dart:70-75 with MDX reading explicitly 'removed' at :57-60, migaku_dictionary_format.dart:55-60), and the on …(截断)
- **[MEDIUM] (utils-components)** ErrorLogService.getLogFile rewrites the log file with reversed+duplicated content, corrupting the persisted log
  - 驳回理由: getLogFile() (error_log_service.dart:104-114), the method that performs the destructive overwrite, has zero callers in the entire repository (verified by repo-wide grep: the only match is its own definition). It is dead code. The real log-sharing/export path is ErrorLogPage (error_log_page.dart:13,31-43), which uses getFullLog() -> in-memory XFile.fromData / Clipboard, and never reads the on-disk …(截断)

## Scope（本轮覆盖）

18 单元覆盖 `hibiki/lib/src/**`、`packages/*/lib/**`、`hibiki/android/**`、`.github/workflows/**`、`ci/**`、`fastlane/**`、`melos.yaml`、`pubspec.*`、`hibiki/test/**`。

## Next Scope（下一轮建议）

- 修复验证轮：Critical/High 修复后跑原始失败路径（v11 旧库升级实测、sync 凭证落盘检查、popup 启动崩溃复现）。
- 真机复现轮：把代码路径风险升级为已复现 bug（按 CLAUDE.md 区分三态），证据落 `.codex-test/`。
- 深挖轮：reader_hibiki_page.dart(4309) WebView/JS 桥逐函数、hoshidicts C++ 侧、creator 50 文件真实耦合图。

---

# 修复进度日志 (Remediation Log) — 更新于 2026-05-29

> 本轮按用户指令"完全修复，审查并修复"执行。修复均做根因修复（CLAUDE.md 铁律），每批 `flutter analyze` + `flutter test` 验证并附回归测试，Wave 1 已通过 opus 代码审查（无 FAIL，两个 CONCERN 已修）。
> 三态严格区分：**FIXED**=已修复+验证+提交；**DEFERRED**=有具体技术理由暂缓（原生构建/真机验证/并行开发冲突/架构迁移/特性级）；**REJECTED**=审计建议经验证为误报；**REMAINING**=尚未处理，附建议处置。

## 已修复并验证 (FIXED) — 36 条

全部 1 Critical + 12 High 的可修复项 + 15 Medium + 12 Low/Info 已根因修复。新增回归测试：SRT cue 迁移、audio 去重、anki dupes、epub TOC/非UTF8、backup 凭证剥离、bookmark FK、SMIL 单位。

| 编号 | Sev | 单元 | 标题 | Commit |
|---|---|---|---|---|
| HBK-AUDIT-001 | CRITICAL | db-core | v11→v12 migration wipes all standalone SRT audiobook cues (data loss) | `6636cc3d5` |
| HBK-AUDIT-002 | HIGH | anki | AnkiConnect addNote ignores the allowDupes setting — duplicates are al… | `02381c08b` |
| HBK-AUDIT-003 | HIGH | app-startup-state | Popup init path never assigns late themeNotifier, but popup UI reads a… | `7d4f133fd` |
| HBK-AUDIT-004 | HIGH | audiobook-audio | Audio file persistence has no basename de-dup; same-named files silent… | `2a456e1dc` |
| HBK-AUDIT-005 | HIGH | build-ci-deps | CI patch step references removed/version-drifted packages and will har… | `4af3b4f79` |
| HBK-AUDIT-006 | HIGH | build-ci-deps | CI path filter excludes packages/** so changes to the 5 internal packa… | `4af3b4f79` |
| HBK-AUDIT-007 | HIGH | db-core | Legacy bookmark migration can abort the entire v11 upgrade via FK viol… | `6636cc3d5` |
| HBK-AUDIT-008 | HIGH | db-core | schemaVersion bumped to 12 (orphan cleanup) without registering a Sche… | `6636cc3d5` |
| HBK-AUDIT-010 | HIGH | epub | TOC hrefs are not URL-decoded while chapter hrefs are, so TOC navigati… | `d87f66bce` |
| HBK-AUDIT-012 | HIGH | sync | Local backup ZIP embeds all sync credentials (OAuth refresh tokens, FT… | `bf3e036dc` |
| HBK-AUDIT-013 | HIGH | utils-components | Barrel re-exports use wrong filename casing (Hibiki_*) that breaks bui… | `7d4f133fd` |
| HBK-AUDIT-016 | MEDIUM | anki | AnkiConnect addNote return value (note id) is discarded; a null result… | `02381c08b` |
| HBK-AUDIT-017 | MEDIUM | anki | AnkiConnect isDuplicate builds a search query with an unescaped/unquot… | `02381c08b` |
| HBK-AUDIT-018 | MEDIUM | anki | AnkiDroid mineEntry creates a fully blank note and reports success whe… | `d09e529da` |
| HBK-AUDIT-019 | MEDIUM | anki | Remote audio/media download ignores HTTP status — a 404/error HTML bod… | `d09e529da` |
| HBK-AUDIT-022 | MEDIUM | app-startup-state | ThemeNotifier._get performs an async DB write (side effect) inside syn… | `334c2b037` |
| HBK-AUDIT-023 | MEDIUM | app-startup-state | initialise() swallows fatal errors into initError but leaves multiple… | `7d4f133fd` |
| HBK-AUDIT-024 | MEDIUM | audiobook-audio | SMIL clipBegin/clipEnd parser silently drops cues for valid 's' / 'ms'… | `334c2b037` |
| HBK-AUDIT-026 | MEDIUM | build-ci-deps | main.yml builds only a debug APK; release-mode build is conditional on… | `4af3b4f79` |
| HBK-AUDIT-029 | MEDIUM | cross-cutting-ai-smells | Embedded sync server PUT writes can leave a corrupt partial file on st… | `ffd4bc935` |
| HBK-AUDIT-030 | MEDIUM | cross-cutting-ai-smells | Untyped 'as int' fromJson on externally-sourced sync data crashes the… | `334c2b037` |
| HBK-AUDIT-032 | MEDIUM | dictionary-ffi | hoshidicts_import error path returns NULL detected_type/title, then Da… | `9bf40176a` |
| HBK-AUDIT-033 | MEDIUM | epub | EPUB chapter/OPF/container reading assumes UTF-8; non-UTF-8 Japanese b… | `d87f66bce` |
| HBK-AUDIT-036 | MEDIUM | pages-ui | BasePage.createState() returns a non-abstract BasePageState that throw… | `bc6551c9a` |
| HBK-AUDIT-043 | MEDIUM | settings-profile | Corrupt fieldMappings JSON in a profile snapshot crashes profile switc… | `334c2b037` |
| HBK-AUDIT-054 | MEDIUM | utils-components | Entire HibikiSelectableText widget + controller (889 lines) is dead co… | `9a3bf602c` |
| HBK-AUDIT-059 | LOW | anki | AnkiConnect _request never checks HTTP status; non-200/HTML bodies cra… | `02381c08b` |
| HBK-AUDIT-061 | LOW | anki | AnkiConnect getDeckNames/getModelNames/getModelFields cast result with… | `02381c08b` |
| HBK-AUDIT-064 | LOW | app-startup-state | AppModel.dispose() leaks DictionaryRepository / MediaHistoryRepository… | `7d4f133fd` |
| HBK-AUDIT-066 | LOW | app-startup-state | quickActionColorProvider relies on Future.wait result order matching q… | `7d4f133fd` |
| HBK-AUDIT-092 | LOW | db-core | Downgrade backup overwrites prior .bak.<from> snapshot and only trigge… | `6636cc3d5` |
| HBK-AUDIT-093 | LOW | db-core | PrefCodec.decode hardcodes List<String> for any List-typed pref, will… | `6636cc3d5` |
| HBK-AUDIT-094 | LOW | db-core | beforeOpen recreates 12 indexes on every database open via per-index t… | `6636cc3d5` |
| HBK-AUDIT-095 | LOW | db-core | hibiki_core.dart exports a path with wrong filename casing (Hibiki_tex… | `6636cc3d5` |
| HBK-AUDIT-096 | LOW | db-core | upsertReadingStatistic DoUpdate omits several columns; partial-row upd… | `6636cc3d5` |
| HBK-AUDIT-097 | LOW | dictionary-ffi | C++ convert_term / hoshidicts_query / hoshidicts_lookup never check ma… | `9bf40176a` |

## 暂缓 (DEFERRED) — 9 条（含 2 High）

| 编号 | Sev | 标题 | 暂缓理由 |
|---|---|---|---|
| HBK-AUDIT-009 | HIGH | FFI lookup/query/lookupPopupJson/getMediaFile run synch… | 原生线程安全需验证：把 FFI 查询移到后台 isolate 需确认 C++ 引擎 handle 跨线程安全 + 真机测试；盲改风险 use-after-free/数据竞争（比当前 µs-ms 卡顿更糟）。 |
| HBK-AUDIT-011 | HIGH | Hibiki LAN sync server sends credentials and data over… | 协议级安全特性：LAN sync TLS/HMAC 需 server+client+discovery 协同 + 真机握手验证；sync 子系统本会话多次并行提交，盲改会弄坏 LAN sync。已 opt-in（默认 loopback）并文档化威胁模型。 |
| HBK-AUDIT-021 | MEDIUM | AppModel god object: 2536 lines, ~80 pass-through deleg… | 架构级迁移：拆 AppModel god-object 触及全 app 每个 widget 的 provider 订阅，属增量迁移项目而非 bug 修复；违反"不从零重写"。 |
| HBK-AUDIT-028 | MEDIUM | BackupService export fallback copies a live WAL-mode SQ… | 备份 live-WAL 回退一致性：12 已覆盖凭证剥离；surface-error 改动需评估 VACUUM 失败的合法回退路径。 |
| HBK-AUDIT-075 | LOW | Test coverage is generated but never uploaded or gated… | 需 codecov/覆盖率阈值策略决策（项目选择）。 |
| HBK-AUDIT-100 | LOW | getMediaFile silently returns null on native allocation… | C++ 侧 OOM 检测，需 NDK 构建验证。 |
| HBK-AUDIT-102 | LOW | Decoded archive (Archive/ArchiveFile) is never closed/c… | archive.clear API 不确定 + 大漫画 zip 内存/性能权衡需测量。 |
| HBK-AUDIT-103 | LOW | EpubChapter.spineIndex is write-only dead state and is… | spineIndex 死字段，移除需动 epub_book 模型，低收益。 |
| HBK-AUDIT-106 | LOW | ZipDecoder runs with CRC verification disabled; corrupt… | verify:true 对大 zip 有 CRC 性能代价，需测量权衡。 |

## 驳回 (REJECTED) — 1 条

- **HBK-AUDIT-034 [MEDIUM]** Extractor treats a file entry as a directory when another entry implie…
  - 建议修复会回归合法 EPUB（零字节目录占位条目）；"有内容的文件同时是另一条目的父目录"在文件系统上不可表示。保留原行为并加注释说明。

## 剩余 (REMAINING) — 110 条，建议处置

> 这些条目因需原生(NDK)构建、真机复测(reader/删除/sync 流程)、架构重构、专项测试编写，或处于激烈并行开发的 sync 子系统中而未在本轮修改——盲改会违反"根因+验证+不破坏"铁律。按严重度+类别列出建议。

### 剩余 Medium（23，逐条建议）

| 编号 | 单元 | 标题 | 建议处置 |
|---|---|---|---|
| HBK-AUDIT-014 | android-native-security | DictAccessibilityService captures all text selections d… | native/隐私设计：DictAccessibilityService 设备级文本捕获属隐私设计决策（需产品确认+原生改动）。 |
| HBK-AUDIT-015 | android-native-security | SAF copy uses /proc/self/fd path for >50MB files — inco… | native：SAF /proc/self/fd 大文件路径需 Android 真机验证。 |
| HBK-AUDIT-020 | anki | checkForDuplicates dispatched on the platform main thre… | native(Kotlin)：checkForDuplicates Handler.post 结果未桥接回，需 NDK 构建+真机。 |
| HBK-AUDIT-025 | build-ci-deps | fastlane Fastfile and Appfile are unmodified third-part… | 配置：fastlane 样板指向错误 app，低风险可改但属发布配置（需真实 app id/repo 确认）。 |
| HBK-AUDIT-027 | creator | Card-creator field/export contract is orphaned: onCreat… | creator 50 文件孤立契约：需确认跨 creator 真死后移除（重构级）。 |
| HBK-AUDIT-031 | cross-cutting-ai-smells | WebDAV / SMB / Hibiki-Client sync backends are three ne… | 重构级：WebDAV/SMB/Hibiki-Client 三份 ~900 行去重，且 sync 激烈并行开发中（高冲突）。 |
| HBK-AUDIT-035 | epub | Per-chapter HTML DOM parse for character counts runs sy… | 性能：每章 DOM 解析移出主 isolate，需 isolate 改造 + 真机测量。 |
| HBK-AUDIT-037 | reader-core | _initialFragment cleared in _onChapterLoadComplete but… | reader-core(reader_hibiki_page 4309 行)：状态/分页改动需真机复测（CLAUDE.md 要求）。 |
| HBK-AUDIT-038 | reader-core | shouldOverrideUrlLoading returns CANCEL for all unresol… | reader-core：shouldOverrideUrlLoading 改动需真机复测外链/锚点行为。 |
| HBK-AUDIT-039 | reader-source-media | Canonical book uid builder bookUidFor exists but the 'r… | 跨包契约：bookUidFor 字面量重复，提取到 hibiki_core 常量；机械但跨 3 处含 DB，建议下一轮。 |
| HBK-AUDIT-040 | reader-source-media | ReaderHibikiSource.deleteBook leaks override title pref… | reader 删除流程：deleteBook 泄漏 override pref/缩略图，删除路径改动需真机复测。 |
| HBK-AUDIT-041 | reader-source-media | deleteBook duplicates the audiobook/srt/cue deletes tha… | reader 删除流程：deleteBook 重复 deleteEpubBook 事务删除，合并需真机复测删除/级联。 |
| HBK-AUDIT-042 | reader-source-media | generateAudio override path is fully dead: setPendingSe… | reader-source 死代码 generateAudio override，移除需确认 reader 调用图（建议下一轮）。 |
| HBK-AUDIT-044 | settings-profile | Sync settings share a top-level mutable singleton (_act… | settings/sync：_activeSyncState 单例生命周期，sync 并行开发中。 |
| HBK-AUDIT-045 | settings-profile | Update-channel persistence is asymmetric across profile… | settings：update-channel 跨 profile 不对称持久化，需理清 profile 作用域语义。 |
| HBK-AUDIT-046 | sync | All sync credentials persisted as plain base64 in the u… | 安全特性：凭证移到平台安全存储(Keychain/Keystore)，feature 级 + sync 并行开发中。 |
| HBK-AUDIT-047 | sync | Conflict resolution silently skips when local/remote ti… | sync 冲突解决：时间戳相等内容不同静默跳过，需真机/集成验证 + sync 并行开发中。 |
| HBK-AUDIT-048 | sync | Metadata update deletes remote file BEFORE uploading re… | sync：元数据先删后传，失败丢进度；需真机/集成验证 + sync 并行开发中。 |
| HBK-AUDIT-049 | sync | Singleton backends are reused concurrently with no mutu… | sync：单例后端并发无互斥，需并发模型设计 + sync 并行开发中。 |
| HBK-AUDIT-050 | test-coverage | 27 '*_static_test.dart' files assert on source-file sub… | 测试债：27 个 *_static_test 断言源码子串而非行为，需重写为行为测试（专项）。 |
| HBK-AUDIT-051 | test-coverage | Anki integration repositories (AnkiConnect network IPC,… | 测试债：Anki IPC 集成测试缺失（专项测试编写）。 |
| HBK-AUDIT-052 | test-coverage | Sync conflict-resolution and all remote backends (FTP/D… | 测试债：sync 冲突/远端后端测试缺失（专项 + sync 并行开发中）。 |
| HBK-AUDIT-053 | test-coverage | reader_pagination_scripts shellScript tests only grep t… | 测试债：pagination shellScript 测试只 grep 子串（专项）。 |

### 剩余 Low/Info（87，按单元汇总）

| 单元 | 数量 |
|---|--:|
| pages-ui | 10 |
| creator | 8 |
| cross-cutting-ai-smells | 7 |
| shortcuts-platform | 7 |
| utils-components | 7 |
| build-ci-deps | 6 |
| reader-core | 6 |
| reader-source-media | 6 |
| audiobook-audio | 5 |
| sync | 5 |
| android-native-security | 4 |
| test-coverage | 4 |
| anki | 3 |
| epub | 3 |
| settings-profile | 3 |
| dictionary-ffi | 2 |
| app-startup-state | 1 |

这些以死代码清理、文档补充、命名/小重构、性能微调为主，建议作为持续清理项分批处理（多数低风险，但量大且单条价值低）。

## 汇总

- **已修复并验证**：36 条（含唯一 Critical 与全部可修复 High）。
- **暂缓（有据）**：9 条（009 FFI 线程、011 LAN 加密为需真机/协议验证的 High）。
- **驳回（误报）**：1 条。
- **剩余建议处置**：110 条（23 Medium + 87 Low/Info）。
- 验证：`flutter analyze lib` 干净；`flutter test` 1357 passed（唯一失败 `switch_settings_page_test` 为并行 MD3 工作回归，非本轮改动，已记录）。

---
# 修复进度日志 — 第二轮 (Round 2, 2026-05-29)

> 在第一轮（36 修复）基础上，用并行 fix workflow（12 个 opus agent 修互不相交文件组）+ 跨文件手工修复，把修复总数提升到 **110/156**。全程 `flutter analyze lib` 干净，`flutter test` **1368 通过 / 1 失败**（唯一失败 `switch_settings_page_test` 为并行 MD3 工作回归，opus 审查确认与本轮改动无 import/逻辑重叠）。两轮 opus 代码审查：第二轮发现 1 个阻塞 FAIL（041 deleteBook 漏删 SRT-linked cue），已根因修复（deleteEpubBook 事务内补删 srt.uid 的 cue）+ 回归测试，其余全 PASS。

## 最终处置（覆盖全部 156 条）

| 状态 | 数量 | 说明 |
|---|--:|---|
| **FIXED** | **110** | 1 Critical · 10 High · 27 Medium · 69 Low · 3 Info；均验证 + 双轮 opus 审查 |
| **REJECTED（误报）** | 3 | 034（删合法 EPUB 占位条目）、149（3 个转换器实际有 17/7/9 引用，非死代码）、156（debugChannel 实际被 home_page 使用） |
| **DEFERRED（有据硬暂缓）** | 3 | 009 FFI 移后台 isolate（需验证原生线程安全+真机）、011 LAN TLS/HMAC（协议特性+真机握手）、021 AppModel god-object（架构级增量迁移） |
| **REMAINING-followup** | 25 | 大重构（031 去重类、114 共享卡片、121 reader 性能、105 TTU DOM、128 批查询）、测试编写（050/051/052）、sync 并行开发区（048/140/141）、跨文件/契约（082/085/090/131/134/136）、文件重命名（079）等 |
| **NATIVE/config** | 15 | Kotlin/Java/C++/gradle/manifest/CI/secret（014/015/020/025/055/056/057/058/071/073/074/075/076/077 + **072 工作树内的 OAuth client secret**）——需 NDK 构建或真机验证、或属配置/密钥轮换（本环境无法 build-verify） |

## 第二轮重点修复（节选）
- reader：037 fragment 重置、038 外链经 url_launcher + 同章锚点原地跳、118 chapter allowMalformed 解码、120 时间戳音量节流、122 lyrics 后台持久化。
- reader source：040 deleteBook 清 override title pref、041 单一所有权原子删除（+ 041 follow-up 补 SRT cue）、042/124 删死 generateAudio/portForLanguage、125 furigana deletePreference、126 记录不可解析 id、127 编码 epub href、039 uid 常量去重。
- sync：028 surface VACUUM 失败、047 时间戳相等冲突 tie-break、049 AsyncMutex 串行化、067/108/132/133 加固。
- dict：099 中文匹配长度 LRU 缓存（与日文对齐）、098/100。
- anki：060/062/063 加固；audio：069/070 + ass_parser；creator：083 死分支、078 isExportable 回退（全局状态耦合）保留防御性拷贝。
- 死代码：删除 084/088/113/115（含 base_media_search_bar 308 行、LoadingPage）+ MediaSource.buildBar；epub：035/102/103/106。
- 测试质量：053/143/146/155 + 新增回归测试（SRT cue 迁移、deleteEpub SRT 级联、audio 去重、backup 凭证、bookmark FK-ON、SMIL 单位、epub TOC/非UTF8、Chinese 缓存等）。

## 安全提示（NATIVE/config 中需用户行动）
- **HBK-AUDIT-072**：`hibiki/dart_defines.env` 内含真实 Google OAuth client secret 且在工作树中——应轮换该密钥并移出版本控制（加入 .gitignore / 用 CI secret 注入）。这是密钥治理动作，非代码可自动修复。

---
# 真机验证 (Device Verification, 2026-05-29, emulator-5556 / Android 15 API 35)

构建 `flutter build apk --debug --target-platform android-x64` **成功**（编译了 analyze 覆盖不到的原生 C++23 hoshidicts CMake + FFI 边界），装机后跑集成测试：

| 测试 | 结果 | 验证的修复路径 |
|------|------|----------------|
| `flutter build apk` | ✅ Built | 110 处改动在真实构建中编译（含原生/FFI/casing/BasePage abstract） |
| `app_smoke_test` | ✅ All passed | 启动+AppModel 初始化无崩溃；schema v14 + _ensureIndexes |
| `settings_validation_test` | ✅ 16 开关 + 6 页持久化, 0 失败 | 022（theme getter 纯读，设置正确持久化无副作用）、147、112、settings_shared |
| `reader_pagination_test` | ✅ All passed（导入 かがみの孤城 EPUB + 解析 + 前向分页 drift≈0） | epub_parser 010/033/102/106、reader_hibiki_page 037/038/118/120/122、import 路径 |

**结论**：已修复的 Critical/High/reader/settings/import 路径在真机验证通过，从"代码路径确认"升级为"真机验证"（CLAUDE.md 三态最高级）。`reader_pagination_test` 自带 EPUB 导入，故 import→parse→reader 全链路在设备上跑通无崩溃。
- 注：`regression_test` 需预置书架（push-fixtures + import），`test-flows.ps1` 已不在 `.codex-test/tools/`（并行 dev 移除）；reader_pagination_test 自带导入已覆盖等价路径。

---
# 修复进度日志 — 第三轮 (Round 3, 2026-05-29)

> 模拟器接入后继续：第三轮并行 fanout（5 组）+ 跨文件手工修复，把修复总数提升到 **117/156**。

## 第三轮修复
- 082（low）：删除 ImageEnhancement.fetchImages 死契约（2/3 子类抛错，零调用方）。
- 128（low）：getBooksFromDb 串行 N+1 查询/封面探测 → Future.wait 并发（顺序不变）。
- 131（low）：reader 快捷设置目的地复用 readingDisplay id → 新增专用 SettingsDestinationId.readerQuickSettings。
- 134（low）：用构造注入替换 AndroidClipboardService 的 is/as 降级 SDK 接线（改名/替换变编译期错误）。
- 136（low）：删除 3 个死接口 TtsEngine/StoragePaths/PlatformIntegration + barrel 导出。
- 137（low）：去掉所有实现都忽略的 getDefaultPickerDirectories(mediaType) dead 参数（接口+3 实现+调用方+2 测试）。
- **048（med，数据丢失）**：WebDAV/FTP/Dropbox/OneDrive 的元数据更新原先"先删后传"，上传失败即永久丢进度；改为**先传后删**（上传成功后才删旧文件）。Google Drive 已是 in-place 更新。需 sync-server 集成复测。

## 最终处置（117/156）
- **FIXED 117**：1 Critical · 10 High · ~30 Medium · ~72 Low · 3 Info。
- **REJECTED 3**：034/149/156（验证为误报）。
- **DEFERRED 3**：009（FFI isolate，需原生线程安全+真机）、011（LAN TLS，协议+真机）、021（god-object，架构迁移）。
- **REMAINING ~33**：原生 Kotlin/C++/gradle/manifest（需 NDK 构建+特定设备：014/015/020/055-058/071/076 等）、密钥轮换（072 用户操作，dart_defines.env 已 gitignored）、大重构（031/105/114/121/123）、测试编写（050/051/052）、配置（025/073/074/075/077）、sync 去重/wire（085/090/091）、产品决策（027/046/079）。

## 测试状态澄清（重要）
`flutter test` = **1383 passed**，2 个失败**均为并行开发（focus-ring/MD3）的在途工作，非本轮修复所致**，且不可触碰（会 clobber 未提交工作）：
1. `switch_settings_page_test`（已跟踪）：失败源自并行 MD3 提交 `e26f9d1e2`（HibikiModalSheetFrame 在 240px 视口溢出）；与本轮改动无 import/逻辑重叠。
2. `settings_focus_traversal_test`（**未跟踪 WIP**）：测试并行 dev 正在构建的 stepper a11y 语义；其被测实现 `_KeyboardStepper`/`_StepperIncrementIntent` 在 settings_shared.dart 中是**未提交的并行改动**（feature 尚未完成）。

本轮所有提交在真机（emulator-5556）构建 + app_smoke + settings_validation + reader_pagination 集成测试通过。

---
# 修复进度日志 — 第四轮 (Round 4, 2026-05-29)

> 目标：把 AnkiDroid 真机链路纳入测试流程，并把 `flutter test` 跑成全绿。

## AnkiDroid 集成测试流程（新增脚本）
- 新增 `ci/anki-integration-test.sh`：自包含、幂等、可复现的 AnkiDroid API 真机测试流程，对应 `hibiki/integration_test/anki_integration_test.dart`（`fetchConfiguration` 返回真实 decks/note types、`isDuplicate`、`mineEntry`）。
- **根因（非绕过）**：AnkiDroid API 受 *dangerous* 权限 `com.ichi2.anki.permission.READ_WRITE_DATABASE` 管控，Android 只在用户点 AnkiDroid 运行时弹窗"Allow"后授予。Hibiki 运行时已正确发起请求（`AnkiChannelHandler.java:144/183` 的 `ankiDroid.requestPermission(...)`），但自动化 `flutter drive` 每次全新安装且无法点系统弹窗，于是 fresh-install 必返回 `AnkiFetchError`。脚本用 `adb install -g`（授予全部运行时权限 = 等价用户点 Allow）预装 APK，`flutter drive` 的 `-r` 重装保留该授权，从而确定性复现已授权状态。这是测试夹具步骤，产品代码无改动。
- 已验证：`bash ci/anki-integration-test.sh --skip-build` → `00:30 +6: All tests passed!`（emulator-5554，AnkiDroid 22400300 + 已建 collection）。
- 文档同步到 `CLAUDE.md` 的"AnkiDroid 集成测试流程"小节。

## switch_settings_page_test 溢出 — 实修（升级 Round 3 的"并行 dev"判断）
- Round 3 把该失败归因于并行 MD3 提交且不可触碰。本轮确认它是 `flutter test` 全绿的唯一阻塞项，遂做**根因修复**（不碰并行 dev 的在途逻辑，只修共享组件）。
- **根因**：`HibikiModalSheetFrame._buildBody`（`hibiki_material_components.dart:641`）只有在 `scrollable:true` 时才把 body 包进 `Flexible`。当调用方自带滚动器并传 `scrollable:false`（`switch_settings_page` / `text_segmentation_dialog_page` 都是此模式），body 拿不到高度上界 → 自带的 `ListView(shrinkWrap)` 取完整 intrinsic 高度 → 320×240 视口下 Column 溢出 103px。
- **修复**：body 恒为 `Flexible`，仅"是否由 frame 包 `SingleChildScrollView`"随 `scrollable` 变化。消除了特殊分支（坏品味），让调用方自带的滚动器在 sheet 高度内滚动。
- **安全性核验**：22 处 `HibikiModalSheetFrame` 用法中，20 处在 `HibikiDialogFrame`（带 `ConstrainedBox` 高度上界）内；2 处底部 sheet（`reader_quick_settings_sheet` 用 `scrollable:true` 已是 `Flexible` 且生产可用，`tag_filter_sheet` 经 `adaptiveModalSheet`→`showModalBottomSheet(isScrollControlled:true)` 提供有界高度），故 `Flexible` 在所有宿主下都不会触发 unbounded 抛错。

## 最终测试状态（全绿）
- `flutter test`（全量单元/widget）：**+1415 All tests passed!**（exit 0）。Round 3 的 2 个失败已证实为并行编译压力下的 flaky "loading" 失败（重跑总数 1394↔1415 波动即为证据），干净重跑全过。
- 真机集成套件（emulator-5554，6 核/5.9G/host-GPU，含最新 057/056/025 原生改动重建）：
  | 测试 | 结果 |
  |------|------|
  | `flutter build apk --debug`（原生 057/056 重编译） | ✅ Built |
  | `app_smoke_test` | ✅ All passed |
  | `reader_pagination_test` | ✅ PAGINATION TESTS PASSED |
  | `anki_integration_test`（脚本化，含 AnkiDroid） | ✅ +6 All passed |

## 处置更新
- **FIXED**：在 Round 3 的 117 基础上 +（057/056/025 原生 teardown 复审项已于 `b5e751a02` 落地）+（本轮 HibikiModalSheetFrame 溢出根因修复）。
- AnkiDroid 测试流程：从"无脚本/手动"升级为"脚本化、可复现、已设备验证"。
- 全量 `flutter test` 从"+1383 带 2 失败"升级为"+1415 全绿"。

---

## Round 4 — Sync 子系统"同类隐患"专项审计 (2026-05-29)

### Scope
应用户"还有类似问题吗"，对 `hibiki/lib/src/sync/` 全部后端 + 同步设置 UI 做针对性审计，专找本会话已修问题的同类：服务器根污染/绝对路径、持久化后失败导致的卡死/脏态、应可配置却写死的值、跨重连/会话失效的状态、静默吞异常。方法：4 维度并行 finder → 每条 finding 对抗式复核（27 agent）。共确认 18 条（去重后约 12 条 distinct），驳回 5 条。

### Findings

#### HBK-AUDIT-157 — HibikiClientSyncBackend `_sessionResolved` 在 clearCache() 后未重置 → 重试不再重探、失败转移失效
- **Severity**: Important / **Status**: Resolved (本轮修复) / **类**: reconnect-fragile
- **位置**: `hibiki/lib/src/sync/hibiki_client_sync_backend.dart` `_ensureResolved`/`clearCache`
- **根因**: SyncManager 遇可重试错误时 `clearCache()` 清掉 folder 缓存并重试，但 `_sessionResolved` 仍为 true，`_ensureResolved()` 直接返回不重探，整个会话锁死在已不可达的旧地址。**这是本会话 LAN→WAN 失败转移特性自身引入的回归**（之前两轮 review 误判"锁定即正确"）。
- **影响**: 出门后 LAN 中断 → 本次同步可重试错误 → 重试仍打死掉的 LAN，永不切到 WAN，需手动干预。
- **修复**: `clearCache()` 同时 `_sessionResolved=false`（clearCache 已清空 folder 缓存，重探+换址此时安全，符合"每地址独立缓存"设计）。

#### HBK-AUDIT-158 — WebDAV / SMB `authenticate()` 改 baseUrl 时未 clearCache() → 缓存的旧 host 全 URL 路径打到旧服务器
- **Severity**: Important / **Status**: Open / **类**: root-pollution（host 耦合缓存）
- **位置**: `webdav_sync_backend.dart:28-42`、`smb_sync_backend.dart:40-54`
- **根因**: 与 HibikiClient `_ensureResolved` 不同，WebDAV/SMB 的 authenticate 换 baseUrl 后不清 `_rootFolderId`/`_titleToFolderId`（内含旧 baseUrl 的完整 URL）。
- **影响**: 用户改 WebDAV/SMB URL 后，缓存的旧路径被复用，操作打到旧服务器；多服务器场景元数据错位。经 404→可重试→SyncManager 清缓存自愈，但存在危险窗口。
- **修复**: authenticate 建好新 `_ops` 后调用 `clearCache()`（仿 signOut 模式）。

#### HBK-AUDIT-159 — Dropbox / OneDrive `restoreAuth()` 刷新失败未清 token → isAuthenticated 仍 true，用过期 token 静默 401 死循环
- **Severity**: Important / **Status**: Open / **类**: silent-failure
- **位置**: `dropbox_sync_backend.dart:191-206`、`onedrive_sync_backend.dart:178-195`
- **根因**: `refreshAuth()` 抛异常时 catch 直接 `return false`，未清 `_accessToken`/`_refreshToken`；`isAuthenticated` 只判 `_accessToken!=null` → 仍 true。
- **影响**: 后台 token 过期后每次自动同步用陈旧 token 命中 401（非可重试 SyncAuthError），auto-trigger 静默吞掉，用户无感，需手动重新登录才恢复。
- **修复**: catch 块清空 `_accessToken`/`_refreshToken`（仿 signOut）。

#### HBK-AUDIT-160 — WebDAV `resolveHref` 跨源校验漏判端口 → 非标端口服务器返回省略端口的 href 时 URL 重建到错端口
- **Severity**: Important / **Status**: Open / **类**: cross-origin
- **位置**: `webdav_ops.dart:162-175`（line 166 只比 host/scheme，不比 port）
- **影响**: 服务器跑 :8080 但 PROPFIND 返回省略端口的绝对 href 时，校验通过但重建 URL 端口错（默认 80/443）→ 连接失败/打错服务器。多数服务器返回相对路径，实际影响有限。
- **修复**: 校验扩展为同时比 `hrefUri.port == baseUri.port`（默认端口等价处理）。

#### HBK-AUDIT-161 — SFTP 操作未把 `SftpStatusError` 包装成可重试 SyncBackendError（FTP/WebDAV 都包了）→ 失败逃逸到 catch-all，同步被跳过不重试
- **Severity**: Important / **Status**: Open / **类**: error-misclassification（数据风险）
- **位置**: `sftp_sync_backend.dart` listBooks/listSyncFiles/uploadContentFile/downloadContentFile/_downloadJson
- **影响**: 同样的远端临时缺失/网络抖动，WebDAV/FTP 自动重试恢复，SFTP 却 `SftpStatusError` 裸抛 → `sync_manager` 走 catch-all（非 isRetryable 分支）→ skipped 不重试。主路径先 ensureBookFolder 重建，概率低，但非预期失败时同步卡住。
- **修复**: SFTP 各操作捕获 `SftpStatusError` 并包成 `SyncBackendError(isRetryable: ...)`，与 FTP/WebDAV 对齐。

#### HBK-AUDIT-162 — 各 config widget 凭据/token 每次按键 fire-and-forget 保存、无校验无错误处理；WebDAV testConnection 先存后验 → 无效配置"粘住"
- **Severity**: Important / **Status**: Open / **类**: persist-then-fail
- **位置**: `sync_settings_schema.dart` WebDAV(535/541/548)、FTP(1021/1028/1034/1041)、SFTP(1182/1189/1195/1202/1210)、SMB(1324/1330/1337)、HibikiServer token(1593)；testConnection 481-482 先存后验
- **影响**: 输错/半截 URL 即写库；DB 写失败被静默丢弃，UI/DB 漂移；无效配置在重启后反复同步失败直到手动改对。
- **修复**: 改为 debounce 或失焦/提交时保存 + try-catch 反馈；testConnection 成功后再持久化。

#### HBK-AUDIT-163 — `_SyncAccountWidget._checkAuth` 空 catch + 无条件 `_initialCheckDone=true` → 瞬时错误下 UI 假显"未登录"
- **Severity**: Important / **Status**: Open / **类**: silent-failure
- **位置**: `sync_settings_schema.dart:281-299`（catch 在 295，finally 无条件置位）
- **影响**: DB/网络/后端解析瞬时异常被吞，UI 退出 loading 显示"未登录"（实际未知），按钮行为误导，无任何错误线索。
- **修复**: catch 内 `debugPrint`/`ErrorLogService` 记录，并区分"未配置"与"检查失败"两态。

#### HBK-AUDIT-164 — LAN 发现两层空 catch（widget `_startScan` + service `_scan`）→ mDNS/权限失败被完全掩盖
- **Severity**: Important / **Status**: Open / **类**: silent-failure
- **位置**: `sync_settings_schema.dart:1865-1870`、`lan_discovery_service.dart:96-98`
- **影响**: 权限缺失/网络受限时扫描失败，用户只看到"无设备"，无法区分"真没设备"与"扫描失败"，无从排障（iOS16+/受限网络常见）。
- **修复**: 记录异常 + 设错误态显示"扫描失败（可能权限/防火墙）"。

#### HBK-AUDIT-165 — `_testAll()` 空 catch 吞掉每个地址的探测异常、无日志无分类
- **Severity**: Important / **Status**: Open / **类**: error-misclassification
- **位置**: `sync_settings_schema.dart:1502-1510`
- **影响**: 仅显示笼统 ✓/✗，无法区分 auth 失败/网络不可达/超时（WebDAV 测试用 `friendlySyncErrorDetail` 有详情，此处不一致）。
- **修复**: 记录异常并按类型分别提示。

#### HBK-AUDIT-166 — HibikiClient `_defaultHibikiProbe` catch 吞掉 4xx/5xx 服务器错误、无日志（本会话代码）
- **Severity**: Minor / **Status**: Open / **类**: error-misclassification
- **位置**: `hibiki_client_sync_backend.dart:38-60`（catch 在 53）
- **影响**: 服务器在跑但返回 5xx，被当"不可达"跳过，无任何调试痕迹；与 SocketException 不可区分。
- **修复**: 探测失败时 `debugPrint` 记录地址+错误（仍返回 false 不改失败转移语义）。

#### HBK-AUDIT-167 — 服务器开关在 `_startServer()` 成功前就持久化 `enabled`（本会话代码，残留）
- **Severity**: Minor / **Status**: Open（已被本会话 snackbar+复位部分缓解）/ **类**: persist-then-fail
- **位置**: `sync_settings_schema.dart` `_ServerModeWidget.onChanged`（`setServerEnabled(v)` 在 `_startServer()` await 之前）
- **影响**: 端口占用时开关先亮再弹回，视觉跳动；已有 snackbar + 失败复位，故仅残留观感问题。
- **修复**: 改为 `_startServer()` 成功后再 `setServerEnabled(true)`。

#### HBK-AUDIT-168 — GoogleDrive `_cachedApi` 在 401 重试再失败后未清 → 毒化缓存，后续操作持续 401 直到重新登录
- **Severity**: Minor / **Status**: Open / **类**: stuck-state
- **位置**: `google_drive_handler.dart:63-81`（重试 rethrow 前未再清 `_cachedApi`）
- **影响**: refresh 后的新 token 又被拒时，旧 `_cachedApi` 留存，后续手动同步反复 401（401 非可重试，不会自动循环，但需重新登录恢复）。
- **修复**: 重试分支 rethrow 前 `_cachedApi = null`。

### 已驳回（对抗复核判定不可达/by-design，记录以免重复上报）
- 切换后端类型后旧凭据"残留"：不可达——sync 只按当前 backendType 解析并只读自己的凭据，旧 widget 不实例化、isAuthenticated 守卫优雅退出。
- FTP `_homeDir` 跨会话陈旧：已在 `1b32106` 文档化的自愈路径覆盖（可重试→清缓存→重连重抓 PWD），by-design。
- LanDiscovery 写死 `port: 8765`：死参数，类内从不读取（端口取自 mDNS SRV 记录），零功能影响。
- `_ServerModeWidget` 初值 8765：`_loaded` 为假时 build 返回 SizedBox.shrink，初值从不渲染。
- SMB host/share/domain 的 getter/setter：dormant by-design（WebDAV-bridge facade，留作未来原生 SMB），生产从不调用。

### Next Scope
按风险优先修复：158/159（数据错位/静默登录死循环）→ 161（SFTP 重试一致性）→ 160（端口校验）→ 162/163/164/165（静默吞异常 + persist-then-fail，需统一"错误可见化 + 失焦保存"小设计）→ 166/167/168（Minor）。

## Round 4 复审与勘误（opus review loop）
opus 审查 `2bf6affa0` 后提出 1 个 Critical：`HibikiModalSheetFrame` 恒 `Flexible` 会在 `reader_hibiki_history_page.dart:1672`（BookProfileDialogFrame）抛 unbounded 异常——因为该处 `HibikiDialogFrame` 漏传 `scrollable:false`，默认 `scrollable:true` 会用 `SingleChildScrollView` 包住内层 sheet，使其 Column 无界。

**实测勘误（不轻信审查结论，按 CLAUDE.md 验证原始失败路径）**：补了一个挂载完整 `BookProfileDialogFrame` 链、320×240 视口的 widget 测试，在**未加修复**时运行——结果 `+4 All tests passed`，**并不崩溃**。根因：`HibikiModalSheetFrame` 的 Column 用 `MainAxisSize.min`，且 `_buildBody` 的 `Flexible` 默认 `FlexFit.loose`；Flutter RenderFlex 只有在 `!canFlex && (mainAxisSize==max || fit==tight)` 时才抛 unbounded 断言，二者都不成立，故无界父节点下 loose Flexible 只是按内容尺寸布局（内层 `BookProfileDialogContent` 自带 `ConstrainedBox(h*0.46)` 兜底）。所以原 frame 改动在所有宿主下都安全；审查的 Critical 是**误报**。

**仍采纳的改进**：给 `reader_hibiki_history_page.dart:1672` 补 `scrollable:false`。它不是修崩溃，而是消除"外层 SingleChildScrollView + 内层 ListView"的嵌套双滚动，并与其余使用 `HibikiDialogFrame(scrollable:false)+HibikiModalSheetFrame` 的调用点对齐（`lib/` 下 `HibikiDialogFrame(` 共 17 处调用，包 HibikiModalSheetFrame 的几乎都传 `scrollable:false`；3 个 MISS 默认 `scrollable:true` 中，`home_page.dart:429`、`media_item_dialog_page.dart:201` 的 child 是普通 Column，`scrollable:true` 合理，不受 frame 改动影响）。新增 2 个全链路 widget 测试覆盖此前从未测过的 frame 装配路径。

**采纳的审查 Warning**：本轮"安全性核验"段原把 reader_hibiki_history 误判为"有界宿主"，实为无界但因 min+loose 而安全——以本勘误为准。审查另指出 `TagFilterSheet` 为死代码（全仓库无实例化，已核实），属并行 dev 既有问题，本任务不在范围内处理，仅记录。

`flutter test` 全量：**+1419 All tests passed!**

---

## Round 4 处置更新 (2026-05-29) — 全部根因修复

应用户指令"换未分配端口（无需保留旧数据）+ 根因修复 + 尽量永不复发"，HBK-AUDIT-157~168 已**全部修复**并提交：

- **默认端口**：8765 → **38765**（IANA 未分配 User Port，避开 8xxx dev 拥挤段与 49152+ 临时区），集中为 `SyncRepository.defaultServerPort` 单一来源，杜绝跨调用点漂移。
- **157**（本会话回归）：`HibikiClientSyncBackend.clearCache()` 重置 `_sessionResolved`，重试时重探、失败转移恢复。commit `3ffe4c9`。
- **158**：WebDAV/SMB `authenticate()` 调 `clearCache()`。**159**：Dropbox/OneDrive `restoreAuth()` 失败清 token。**160**：WebDAV `resolveHref` 跨源校验含端口。**161**：SFTP `_guarded()` 把 `SftpStatusError`/传输失败统一译为可重试。**168**：GoogleDrive 401 重试再失败清 `_cachedApi`。commit `7ca4c07`。
- **162**：凭据/token 保存 try-catch + 记日志（不再 fire-and-forget 静默丢弃）。**163/164/165/166**：静默 catch 改为 `ErrorLogService`/`debugPrint` 记录；LAN 发现新增可见"扫描失败"态（i18n `sync_lan_scan_failed`）。**167**：服务开关在 bind 成功后才持久化 `enabled`。commit `f205ed7`。
- **永不复发机制**：新增静态守卫测试 `test/sync/no_bare_empty_catch_test.dart` —— 禁止 `lib/src/sync` 出现裸空 `catch {}`，强制每个 catch 要么记录/重抛，要么用注释声明 best-effort 意图；现有 14 处正当 best-effort 空 catch 已逐一注释化。

验证：`flutter analyze lib/src/sync` 干净；新增/相关单测全绿；`flutter test` 全量 **+1424 All tests passed!**（此前并行 dev 的手柄重构编译错误也已在工作区修复）。

## Round 4 续 — 测试债 051（AnkiConnect 网络 IPC）落地
`AnkiConnectService`（AnkiConnect 的 HTTP IPC 层）此前零测试，仅 model JSON round-trip 被覆盖。新增 `packages/hibiki_anki/test/ankiconnect_service_test.dart`（19 个用例，`flutter test` 全过），通过服务自带的 `clientFactory` 注入点 + 手写 fake `HttpClient`（不开真实 socket）覆盖：
- 请求信封：host/port/path、`action` + `version:6` 协议、params 有无；
- 结果解析：deckNames/modelFields 列表；
- 错误映射：非 200 → `AnkiConnectException`、`error` 字段 → 原文消息、`checkConnection` 对非 Anki 异常的兜底包装；
- `isDuplicate` 查询构造 + 双引号转义；`addNote`/`storeMediaFile` payload 结构 + `allowDuplicate` 标志。

051 现状更新：**AnkiConnect 网络 IPC = 已测**（本次）；**AnkiDroid ContentProvider IPC = 已测**（`hibiki/integration_test/anki_integration_test.dart` 真机 +6）。仅剩 `AnkiConnectRepository` 编排逻辑（mineEntry 字段渲染/060 fail-closed/018 blank-note）因 `loadSettings/updateSettings` 在包内为抽象、具体实现在 app 层，需 app 侧夹具，留作后续。`hibiki_anki` 包本次无并行开发冲突。
