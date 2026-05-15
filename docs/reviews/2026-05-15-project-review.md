# Hibiki 项目全面审查报告

**日期**: 2026-05-15
**审查范围**: 全项目深度审查（数据库/迁移 → 启动初始化 → 阅读器状态 → 字典/FFI → 音频/字幕 → WebView/安全）
**状态**: 仅审查和建议，未修改业务代码

---

## 审查结论

本轮审查覆盖 hibiki 全栈，按风险排序深入 6 个子系统，共发现 **44 个问题**：

| 严重度 | 数量 | 说明 |
|--------|------|------|
| CRITICAL | 1 | FFI 内存泄漏 |
| HIGH | 7 | SQL 注入、竞态、持久化断裂、异步未等待 |
| MEDIUM | 24 | 安全、状态管理、解析器健壮性、生命周期 |
| LOW | 12 | 日志、防御性编码、小优化 |

所有问题均为「代码路径审查发现的风险」，未经运行时复现验证。

---

## 一、数据库 / 迁移层

### Scope
`hibiki/lib/src/database/database.dart`, `tables.dart`, `media_source.dart`, `bookmark_repository.dart`, `epub_importer.dart`, `ttu_migration.dart`

### Findings

#### HBK-AUDIT-DB-001: SQL 注入 — `getBookIdsForAllTags()` 字符串拼接
- **Severity**: HIGH
- **Status**: 代码路径审查
- **File**: [database.dart:600-611](hibiki/lib/src/database/database.dart#L600-L611)
- **根因**: `tagIds.join(",")` 直接拼入 SQL，绕过参数化查询
- **影响**: 虽然 `tagIds` 是 `Set<int>` 类型，当前不可直接注入，但违反参数化原则；如果上游输入源变化则成为真实漏洞
- **修复**: 用 `?` 占位符替换字符串拼接，`variables` 列表动态生成
- **验证**: 改完后用包含特殊字符的测试输入跑查询

#### HBK-AUDIT-DB-002: PRAGMA 注入 — `_columnExists()` 未校验表名
- **Severity**: MEDIUM
- **Status**: 代码路径审查
- **File**: [database.dart:139](hibiki/lib/src/database/database.dart#L139)
- **根因**: `tableName` 直接拼入 `PRAGMA table_info($tableName)`
- **影响**: 当前所有调用方传字面量字符串，不可利用；但 API 签名不安全
- **修复**: 加正则校验 `^[a-zA-Z_][a-zA-Z0-9_]*$`

#### HBK-AUDIT-DB-003: 竞态 — `trimMediaHistory()` / `trimSearchHistory()` 无事务
- **Severity**: HIGH
- **Status**: 代码路径审查
- **File**: [database.dart:210-227, 266-279](hibiki/lib/src/database/database.dart#L210-L227)
- **根因**: count → fetch → loop delete 三步不在 transaction 里，中间可被并发写入打断
- **影响**: trim 可能删多删少，历史记录数据库缓慢膨胀
- **修复**: 用 `transaction(() async { ... })` 包裹，改 loop delete 为单条 batch `WHERE id IN (...)`

#### HBK-AUDIT-DB-004: `deletePreference()` 只删内存不删数据库
- **Severity**: HIGH
- **Status**: 代码路径审查（与 CODE_QUALITY_REVIEW 致命问题 2 重复确认）
- **File**: [media_source.dart:168-171](hibiki/lib/src/media/media_source.dart#L168-L171)
- **根因**: `setPreference()` 双写（内存 + Drift），`deletePreference()` 只写内存
- **影响**: 清除 override title 后重启 app，旧值从数据库复活
- **修复**: 加 `await db.deletePref(_dbPrefKey(key))` 对称调用

#### HBK-AUDIT-DB-005: v10 Orphan Cleanup 可接受
- **Severity**: MEDIUM
- **Status**: 一次性迁移，已评估安全
- **File**: [database.dart:113-134](hibiki/lib/src/database/database.dart#L113-L134)
- **说明**: 单次迁移清理，外键已启用 cascade，后续依赖 cascade 即可

#### HBK-AUDIT-DB-006: 批量插入用单条循环，性能浪费
- **Severity**: MEDIUM
- **Status**: 代码路径审查
- **File**: [database.dart:322-329, 468-475, 616-622, 678-687](hibiki/lib/src/database/database.dart#L322-L329)
- **根因**: `for + await into().insert()` 逐条写入
- **修复**: 改用 `into().insertAll(cues)` 或 batch API

#### HBK-AUDIT-DB-007: EPUB 导入回滚不完整
- **Severity**: MEDIUM
- **Status**: 代码路径审查
- **File**: [epub_importer.dart:104-118](hibiki/lib/src/epub/epub_importer.dart#L104-L118)
- **根因**: DB delete 和 file delete 各自 try-catch，DB 删除失败后文件仍被删 → 孤 DB 记录
- **修复**: 用 transaction 包裹 DB 操作，失败时一起回滚

#### HBK-AUDIT-DB-008: TTU 迁移无原子事务
- **Severity**: MEDIUM
- **Status**: 一次性迁移，可接受
- **File**: [ttu_migration.dart:22-146](hibiki/lib/src/epub/ttu_migration.dart#L22-L146)

#### HBK-AUDIT-DB-009: Bookmark JSON blob 存偏好表，抗腐败能力差
- **Severity**: MEDIUM
- **Status**: 代码路径审查
- **File**: [bookmark_repository.dart:57-84](hibiki/lib/src/media/audiobook/bookmark_repository.dart#L57-L84)
- **根因**: 整个书签列表序列化成 JSON 存入 preferences 单条记录
- **影响**: 单字节损坏 → 全书签丢失；read-modify-write 无原子性
- **修复**: 应迁移到 Drift 表 `Bookmarks`，外键关联 `EpubBooks`

#### HBK-AUDIT-DB-010: `MediaTypeProfiles.mediaType` 缺显式 NOT NULL
- **Severity**: LOW
- **File**: [tables.dart:245-253](hibiki/lib/src/database/tables.dart#L245-L253)

---

## 二、启动初始化 / 状态管理

### Scope
`main.dart`, `popup_main.dart`, `app_model.dart`, `profile_repository.dart`

### Findings

#### HBK-AUDIT-INIT-001: populate 方法标 async 但调用处不 await
- **Severity**: HIGH
- **Status**: 代码路径审查
- **File**: [app_model.dart:793-1037（定义）, 1226-1233（调用）](hibiki/lib/src/models/app_model.dart#L1226-L1233)
- **根因**: `populateLanguages()`, `populateLocales()` 等 7 个 populate 方法标记 `async`，但 `initialise()` 中不 await
- **影响**: 后续代码 `targetLanguage.initialise()` (line 1242) 和 media source 初始化 (line 1264) 假设 map 已填充，实际可能读到空 map
- **修复**: 若方法体无 await，去掉 `async`（让它同步执行）；若未来加 await，调用处加 `await`

#### HBK-AUDIT-INIT-002: AppModel 的 5 个 ChangeNotifier 从不 dispose
- **Severity**: MEDIUM
- **Status**: 代码路径审查
- **File**: [app_model.dart:246-267](hibiki/lib/src/models/app_model.dart#L246-L267)
- **根因**: `dictionaryEntriesNotifier`, `dictionaryMenuNotifier` 等 5 个 ChangeNotifier 没有 dispose
- **影响**: 热重载后 listener 堆积，长期运行内存泄漏

#### HBK-AUDIT-INIT-003: 搜索预加载用 `.then()` 链，无错误处理
- **Severity**: MEDIUM
- **Status**: 代码路径审查
- **File**: [app_model.dart:1308-1326](hibiki/lib/src/models/app_model.dart#L1308-L1326)
- **根因**: 三层嵌套 `.then()` 无 `.catchError()`；`_isInitialised = true` 在预加载完成前设置
- **影响**: 预加载失败静默吞掉，用户首次搜索卡顿

#### HBK-AUDIT-INIT-004: 待处理 intent lookup 可能在子系统未就绪时触发
- **Severity**: MEDIUM
- **Status**: 代码路径审查
- **File**: [main.dart:238-279, 356-362](hibiki/lib/main.dart#L356-L362)
- **根因**: `_pendingLookupText` 在 `addPostFrameCallback` 中消费，但只检查 `isInitialised`，不检查具体子系统
- **影响**: 词典搜索启动时 handler 可能未就绪

#### HBK-AUDIT-INIT-005: TTU 迁移服务器 15 秒超时不隔离
- **Severity**: MEDIUM
- **Status**: 代码路径审查
- **File**: [app_model.dart:1270-1304](hibiki/lib/src/models/app_model.dart#L1270-L1304)
- **根因**: 超时异常被 catch 吞掉，但后续用 `migServer.boundPort!` 可能 NPE

#### HBK-AUDIT-INIT-006: WebView warmup 异常只 debugPrint
- **Severity**: LOW
- **Status**: 设计如此（非致命），建议改用 ErrorLogService

#### HBK-AUDIT-INIT-007: Popup 进程不 await 初始化
- **Severity**: LOW
- **Status**: 代码路径审查
- **File**: [popup_main.dart:48](hibiki/lib/popup_main.dart#L48)
- **说明**: UI 有 loading/error 状态处理，风险低

---

## 三、阅读器 / WebView 层

### Scope
`reader_settings.dart`, `reader_hoshi_page.dart`, `reader_hoshi_source.dart`, `reader_pagination_scripts.dart`

### Findings

#### HBK-AUDIT-RDR-001: 设置同步竞态 — 19 个 `setTtu*()` 不 await
- **Severity**: MEDIUM
- **Status**: 代码路径审查（与 CODE_QUALITY_REVIEW 致命问题 3 重复确认）
- **File**: [reader_hoshi_page.dart:2633-2653](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L2633-L2653)
- **根因**: `_syncSettingsToHive()` 连续调用 19 个返回 `Future<void>` 的 setter 但不 await
- **影响**: 紧接着 snapshot 对比可能读到旧缓存值，设置偶发不生效

#### HBK-AUDIT-RDR-002: `_progressPollTimer` 快速翻章时可累积
- **Severity**: MEDIUM
- **File**: [reader_hoshi_page.dart:99-101, 1297-1303, 1659, 1708](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L1297-L1303)
- **根因**: 新 timer 创建前未验证旧 timer 已释放
- **影响**: 阅读统计可能计入错误章节的字数

#### HBK-AUDIT-RDR-003: `_restoreCompleter` 在 dispose 时未完成
- **Severity**: MEDIUM
- **File**: [reader_hoshi_page.dart:1256, 1662-1665](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L1256)
- **根因**: dispose 方法不 complete 挂起的 completer
- **影响**: 待处理 Future 永远挂起，内存泄漏

#### HBK-AUDIT-RDR-004: `_jsStringLiteral()` 转义不完整 — XSS 风险
- **Severity**: HIGH
- **Status**: 代码路径审查
- **File**: [reader_pagination_scripts.dart:899-920](hibiki/lib/src/reader/reader_pagination_scripts.dart#L899-L920)
- **根因**: 只转义 `\ " \n \r \t`，不转义 Unicode 控制字符（`‮` 等）和 null byte
- **影响**: 当前 fragment 来自内部数据，可利用性低；但如果 EPUB TOC 包含恶意 Unicode 可造成 JS 行为异常
- **修复**: 改用 `jsonEncode()` 或手动转义非 ASCII 为 `\uXXXX`

#### HBK-AUDIT-RDR-005: 音频 cue 缓存跨章节未失效
- **Severity**: MEDIUM
- **File**: [reader_hoshi_page.dart:1562-1599, 1608-1635](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L1562-L1599)
- **根因**: `_cachedAllCues` 换章时未清空，新章可能注入旧章 cue
- **影响**: 高亮错位

#### HBK-AUDIT-RDR-006: WebView reload 时 JS handler 不重注册
- **Severity**: LOW-MEDIUM
- **File**: [reader_hoshi_page.dart:1060-1163](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L1060-L1163)

#### HBK-AUDIT-RDR-007: Stream 订阅回调不 await
- **Severity**: LOW
- **File**: [reader_hoshi_page.dart:2133-2150](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L2133-L2150)

#### HBK-AUDIT-RDR-008: `MIXED_CONTENT_ALWAYS_ALLOW`
- **Severity**: MEDIUM
- **File**: [reader_hoshi_page.dart:1057](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L1057)
- **根因**: 允许混合内容加载，削弱 MITM 防御
- **修复**: 改 `MIXED_CONTENT_NEVER_ALLOW`，确保本地 scheme 一致

#### HBK-AUDIT-RDR-009: 自定义字体路径未做目录白名单校验
- **Severity**: MEDIUM
- **File**: [reader_hoshi_page.dart:789-820](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L789-L820)
- **根因**: 只检查偏好表中是否存在路径，不验证路径是否在安全目录内
- **修复**: 解析 symlink 后验证在 app 的 cache/documents 目录内

#### HBK-AUDIT-RDR-010: `_onCueChanged()` 无 null check on `_controller`
- **Severity**: LOW-MEDIUM
- **File**: [reader_hoshi_page.dart:1398-1437](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L1398-L1437)

#### HBK-AUDIT-RDR-011: 阅读统计 flush 时序不准
- **Severity**: LOW
- **File**: [reader_hoshi_page.dart:2020-2038](hibiki/lib/src/pages/implementations/reader_hoshi_page.dart#L2020-L2038)
- **根因**: `_sessionStartTime` 在 restore 完成时重置，不在导航开始时重置

#### HBK-AUDIT-RDR-012: 双重状态源 — ReaderSettings vs ReaderHoshiSource
- **Severity**: MEDIUM（架构债务）
- **说明**: 两个对象各自持有阅读设置，双写同步是多个 bug 的根因。应统一到 `ReaderSettings` 单一所有者

---

## 四、字典 / FFI 层

### Scope
`hoshidicts.dart`, `hoshidicts_ffi_bindings.dart`, `dictionary_format.dart`, `dictionary_dialog_page.dart`, `app_model.dart` 导入流程

### Findings

#### HBK-AUDIT-DICT-001: FFI 内存泄漏 — `getMediaFile()` null 路径不释放
- **Severity**: CRITICAL
- **Status**: 代码路径审查
- **File**: [hoshidicts.dart:423-441](hibiki/lib/src/dictionary/hoshidicts.dart#L423-L441)
- **根因**: 当 `r.data == nullptr` 时直接 `return null`，跳过 `freeMedia()` 调用
- **影响**: 每次查找不存在的词典媒体文件 → C++ 堆内存泄漏 → 长期使用 OOM
- **修复**: null 路径也必须调用 `freeMedia()` 后再 return

#### HBK-AUDIT-DICT-002: FFI 异常路径 — query/lookup/getStyles 的 free 和 calloc.free 之间可被异常打断
- **Severity**: HIGH
- **File**: [hoshidicts.dart:350-420](hibiki/lib/src/dictionary/hoshidicts.dart#L350-L420)
- **根因**: `freeQueryResult(rPtr)` 和 `calloc.free(rPtr)` 之间无 try-finally
- **修复**: 用 try-finally 保证 `calloc.free(rPtr)` 一定执行

#### HBK-AUDIT-DICT-003: FFI 数组访问无 null 指针校验
- **Severity**: MEDIUM
- **File**: [hoshidicts.dart:116-165](hibiki/lib/src/dictionary/hoshidicts.dart#L116-L165)
- **根因**: `ffi.glossaries[i]` 未检查 `ffi.glossaries != nullptr`
- **影响**: C++ 返回 count > 0 但 pointer 为空时段错误崩溃

#### HBK-AUDIT-DICT-004: 字典导入格式 UI 是死代码
- **Severity**: HIGH
- **Status**: 代码路径审查（与 CODE_QUALITY_REVIEW 致命问题 1 重复确认）
- **File**: [dictionary_dialog_page.dart:696-705, app_model.dart:2219-2222, 2285-2289](hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart#L696-L705)
- **根因**: 用户选择的 `DictionaryFormat` 不传入导入路径，`formatKey` 固定写 `'yomichan'`
- **修复**: 删除假 UI 或把选择传入导入路径

#### HBK-AUDIT-DICT-005: 字典标题未做路径遍历校验
- **Severity**: MEDIUM
- **File**: [app_model.dart:2228-2232](hibiki/lib/src/models/app_model.dart#L2228-L2232)
- **根因**: `result.title` 来自 C++ FFI，可包含 `../`、null byte
- **修复**: 校验 title 不含路径分隔符和特殊字符

---

## 五、音频 / 字幕解析层

### Scope
`srt_parser.dart`, `lrc_parser.dart`, `vtt_parser.dart`, `ass_parser.dart`, `smil_parser.dart`, `json_alignment_parser.dart`, `audiobook_bridge.dart`, `audiobook_model.dart`

### Findings

#### HBK-AUDIT-AUD-001: SRT 时间码溢出 — 无边界检查
- **Severity**: MEDIUM
- **File**: [srt_parser.dart:151-168](hibiki/lib/src/media/audiobook/srt_parser.dart#L151-L168)
- **根因**: `h * 3600000` 在 h > 596523 时溢出；m, s, ms 不校验范围
- **影响**: 畸形 SRT 文件导致 cue 时间错位

#### HBK-AUDIT-AUD-002: LRC/VTT/ASS 解析器有相同溢出风险
- **Severity**: MEDIUM
- **File**: lrc_parser.dart:152-179, vtt_parser.dart:156-179, ass_parser.dart:155-165
- **修复**: 四个解析器统一加 bounds check

#### HBK-AUDIT-AUD-003: SMIL `_parseTimeToMs()` 部分用 `double.parse()` 可抛异常
- **Severity**: MEDIUM
- **File**: [smil_parser.dart:101-118](hibiki/lib/src/media/audiobook/smil_parser.dart#L101-L118)
- **根因**: 前两个 branch 用 `double.parse()`（抛异常），第三个用 `double.tryParse()`（防御性）
- **修复**: 全部改 `double.tryParse() ?? 0`

#### HBK-AUDIT-AUD-004: JSON 对齐解析器不验证 `fileIndex` 范围
- **Severity**: MEDIUM
- **File**: [json_alignment_parser.dart:42-78](hibiki/lib/src/media/audiobook/json_alignment_parser.dart#L42-L78)
- **根因**: 不检查 `fileIndex` 是否在实际音频文件数量范围内
- **影响**: 播放时索引越界

#### HBK-AUDIT-AUD-005: AudiobookBridge 注入的 JS 可被 EPUB 覆盖
- **Severity**: MEDIUM
- **File**: [audiobook_bridge.dart:245-270](hibiki/lib/src/media/audiobook/audiobook_bridge.dart#L245-L270)
- **根因**: 全局函数 `__hoshiHighlight` 等无 freeze 保护
- **影响**: 恶意 EPUB 可覆盖函数拦截查词数据（当前信任用户提供的 EPUB，风险低）

#### HBK-AUDIT-AUD-006: AnkiRepository 错误消息过于笼统
- **Severity**: LOW
- **File**: [anki_repository.dart:100-105](hibiki/lib/src/anki/anki_repository.dart#L100-L105)

#### HBK-AUDIT-AUD-007: 文本文件编码 fallback 不记日志
- **Severity**: LOW
- **File**: [text_file_io.dart:12-20](hibiki/lib/src/media/audiobook/text_file_io.dart#L12-L20)

---

## 六、仓库级问题（延续上一轮审查）

#### HBK-AUDIT-REPO-001: `flutter analyze` 2278 issues，门禁失效
- **Severity**: HIGH（与 CODE_QUALITY_REVIEW 致命问题 4 重复确认）
- **修复**: 砍掉 `public_member_api_docs` 等高噪 lint，目标归零 error/warning

#### HBK-AUDIT-REPO-002: 仓库含 7735+ 非业务文件（生成 docs + 第三方测试）
- **Severity**: MEDIUM（与 CODE_QUALITY_REVIEW 致命问题 5 重复确认）
- **修复**: 第三方 native 依赖改 submodule 或最小化快照

---

## 建议修复优先级

### 立即修复（P0）
1. **HBK-AUDIT-DICT-001** — FFI `getMediaFile()` 内存泄漏（CRITICAL，每次查词累积）
2. **HBK-AUDIT-DB-004** — `deletePreference()` 持久化断裂（HIGH，用户可感知 bug）
3. **HBK-AUDIT-DICT-002** — FFI free/calloc.free 异常安全（HIGH）

### 尽快修复（P1）
4. **HBK-AUDIT-DB-001** — SQL 注入（HIGH，安全债务）
5. **HBK-AUDIT-INIT-001** — populate 不 await（HIGH，启动竞态）
6. **HBK-AUDIT-DICT-004** — 字典格式假 UI（HIGH，用户被骗）
7. **HBK-AUDIT-RDR-004** — JS 字符串转义不完整（HIGH，XSS 风险）

### 版本内修复（P2）
8. **HBK-AUDIT-DB-003** — trim 竞态
9. **HBK-AUDIT-RDR-001** — 设置同步竞态
10. **HBK-AUDIT-RDR-012** — 双状态源架构债务
11. **HBK-AUDIT-AUD-001/002** — 解析器溢出
12. **HBK-AUDIT-DB-009** — Bookmark JSON blob 迁移到表
13. **HBK-AUDIT-REPO-001** — analyzer 降噪

### 后续优化（P3）
14. 其余 MEDIUM/LOW 问题

---

## Next Scope

下一轮审查建议覆盖：
- Isar 模型和 `.g.dart` 手写文件的一致性
- WebView 缓存和离线行为
- 多 profile 切换的状态隔离
- CI/CD 门禁搭建
- 11 个 pub cache patch 的长期维护策略
