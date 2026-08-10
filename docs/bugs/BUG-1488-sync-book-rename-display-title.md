## BUG-1488 · 母设备重命名的书同步到子设备仍显示原书名
- **报告**：2026-08-10（用户：「在母设备已经改过名字的书，同步到子设备后，在子设备上显示的依然是原始的书名」）
- **真实性**：✅ 真 bug。根因不是同步链路某一处漏字段，而是**书的「改名」这个数据从设计上就不出境**：

  1. 书改名**不写** `epub_books.title` 列——那一列派生主键 `bookKey = sanitizeTtuFilename(title)`，
     改列 = 换跨端身份 + 十来张子表连坐改键（`packages/fushi_core/lib/src/database/database_content_misc.part.dart:389-393`
     写明了这个取舍，全仓**没有** `updateEpubBookTitle`）。改名写的是一行覆盖偏好：
     `MediaSource.setOverrideTitleFromMediaItem`（`fushi/lib/src/media/media_source.dart:648-667`），
     key = `src:reader_fushi:override_title://fushi://book/<bookKey>`（`media_source.dart:478-479`
     + `dbSourcePrefKey` `media_source.dart:25` + `ReaderFushiSource.mediaIdentifierFor`
     `fushi/lib/src/media/sources/reader_fushi_source.dart:201-202`）。读侧门面
     `fushi/lib/src/media/display_title.dart:54-73`。
  2. **互联清单不带它**：host 的 `AppModelLibraryHostService.listBooks` 填的是 raw 列值
     `RemoteBookInfo(title: r.title, …)`（`fushi/lib/src/sync/app_model_library_host_service.dart:344`），
     wire DTO `RemoteBookInfo`（`fushi/lib/src/sync/fushi_library_host_service.dart:229-311`）
     **没有任何显示名字段**。→ 子设备远端占位卡、首页「继续」、删除确认全是原书名。
  3. **下载落地也不带它**：peer 下载后走 `EpubImporter.importFromPath`，本地 title 来自 EPUB 元数据
     （同名还会加 `(2)` 后缀，`fushi/lib/src/epub/epub_importer.dart:131-141`），且下载后回填链
     （标签 LWW / 阅读进度，`fushi/lib/src/pages/implementations/reader_history/remote.part.dart:416-435`）
     **没有 override 这一项**。→ 下载完变成本地书，仍是原书名。
  4. **备份/合并通道也不带它**：`BackupMergeEngine` 明写「preferences 是设备设置 → 不合并」，
     点名例外只有 `audiobook_pos_%` 与音频来源两处（`fushi/lib/src/sync/backup_merge_engine.dart:1211-1222`）。
     更糟的是备份导出的 settings 谓词**把它当 app 设置**（`fushi/lib/src/sync/backup_service.dart:623-636`），
     与 `ProfileKeys.isExcludedPref`（`fushi/lib/src/profile/profile_keys.dart:101-114`，判它是**内容**）
     互相打架 → 不勾 `settings` 导出时，用户所有书的改名被一并 strip 掉。
     （视频改名直写 `video_books.title` 列，天然跟着行走，所以这条不对称只砸书。）

- **[x] ① 已修复** — `5f55247696`。三条出境通道全部按「只搬显示名、绝不搬身份」打通：
  - wire：`RemoteBookInfo` 新增 additive 字段 `displayTitle` + 消费入口 `displayName`
    （`fushi/lib/src/sync/fushi_library_host_service.dart`）。**与 raw title 相同时不写 wire 键**，
    旧 host 不发 / 旧 peer 忽略，清单字节零变化。`downloadId` / `bookKey` / 去重键仍恒用 raw `title`。
  - host：`AppModelLibraryHostService._overrideTitleByBookKey()` 一趟 prefs 读，把 override 填进清单。
  - peer 上屏：远端卡 / 长按面板 / 信息弹窗 / 删除确认（`reader_history/remote.part.dart`）+
    首页「继续」（`fushi/lib/src/utils/misc/dashboard_remote_merge.dart`）改用 `displayName`。
  - peer 落地：`_adoptRemoteBookDisplayTitle()` 在导入成功后把 host 显示名写成本机 override
    （本机已有 override 则保留本机的）。
  - 备份：`override_title://` 行改归「内容」——`settingsPrefPredicate` /
    `_keepDeviceSettingsPrefPredicate` 不再 strip 它，`BackupMergeEngine._mergeOverrideTitlePrefs()`
    按 insert-if-absent 并入（与 `audiobook_pos_%` 同律）。
  - 前缀字面量收敛到新叶子文件 `fushi/lib/src/media/override_title_key.dart` 的
    `kOverrideTitleKeyMarker`（原本 `media_source.dart` / `profile_keys.dart` 各写一份，
    现在四处消费）。**未改 Drift schema**（仍 v83，无迁移）。

- **[x] ② 已加自动化测试** — `fushi/test/sync/book_rename_cross_device_test.dart`（7 例，全绿）：
  DTO 三例（改名写 wire 键 / 同名与 null 都不写键 / 旧 host JSON 缺键时 `displayName` 回落
  raw）、host 清单两例（override 下发 + 身份键仍是 raw / 无 override 时 wire 不带该键）、
  备份谓词一例（settings 谓词不再 strip override 行，仍 strip 普通设置行）、合并引擎一例
  （母设备 override 并入子设备 + 子设备自己的 override 不被 clobber）。
  **变异实测**（逐条破坏 lib → 确认转红 → 反向替换还原，零残留）：
  ① host `displayTitle: overrideTitles[r.bookKey]` → `null`；
  ② `backup_service._notOverrideTitleSql` → `'1=1'`；
  ③ `backup_merge_engine._mergeOverrideTitlePrefs` 的 `instr(...) > 0` → `< 0`（恒假）；
  ④ `RemoteBookInfo.toJson` 的 wire 键 `'displayTitle'` → `'displayTitleXX'`。四条各自转红。

- **备注**：**已知能力缺口（不是遗漏）**——override 偏好落在 `preferences` 表，该表只有
  `key`/`value` 两列、**没有时刻列**，所以跨端合并做不了 LWW：母设备**第二次**改名传不到
  「本机已有 override」的子设备上（只有第一次、以及子设备没自己改过名的情况会生效）。
  要补必须给 override 一个 `updatedAt` 载体（对照 `BookCustomCss` 的 `updatedAt` + `deleted`
  墓碑），那是独立的 schema 变更，本轮刻意不做。
  另：`_overrideTitleByBookKey` 只认 BUG-1317 后的**规范** key 形态；BUG-1317 之前改的名若此后
  从未在 host 本机显示过（读取期回退尚未把它就地重写成规范键），不会随清单下发。
  **未做真机双设备验证**（母/子两台真设备互联对拉）——只有单测覆盖。
