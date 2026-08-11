## BUG-1577 · 有声书资产包缺资源被两侧静默 fail-open 掩盖（导出跳过 + 导入编 basename 路径）
- **报告**：2026-08-12（用户：）
- **真实性**：✅ 真 bug（沿 `.fushiaudio` 打包/解包真实代码路径确认）。三处根因：
  1. 导出跳过：`fushi/lib/src/sync/sync_asset_package_service.dart:141`（旧行为
     `if (!await file.exists()) continue;`）——源文件不在磁盘就静默不进包、不进
     manifest `resources`，包不完整这件事没有任何痕迹。
  2. 导入编路径：`fushi/lib/src/sync/sync_asset_package_service.dart:533`（旧
     `_resourceName` 在 `resources` 里查不到时 `return p.basename(sourcePath)`）——
     算出 `<targetDir>/<basename>` 这个「看着像样但不存在」的路径，照样
     `upsertAudiobook` / `upsertSrtBook` 写进 DB 并报导入成功。
     两者互相掩盖：用户跨设备下载/恢复得到一本「有字幕没声音」的书，零报错。
  3. folder 模式零音频：`fushi/lib/src/sync/sync_asset_package_service.dart:509`
     （旧 `_audioPackageFiles` 只读 `audioPathsJson`，从不读 `audioRoot`）——而播放端
     `fushi/lib/src/media/audiobook/audiobook_session_launcher.dart:193-217` 明确支持
     folder 模式（`audioPaths` 空时枚举 `audioRoot`）。这类书导出时**零个音频文件**，
     导入端拿到空音频列表，同样报成功。
- **[x] ① 已修复** — `fushi/lib/src/sync/sync_asset_package_service.dart`
  - 导出侧：不再静默跳过，缺失的源文件写进 manifest 新键 `missingResources`（只在
    非空时出现，健康包与旧包同形）；**部分缺失不整包失败**（一本书缺 1 个文件不该
    中断整个备份/同步），拒绝落库的判断交给导入端。
  - 导出侧：音频按「播放端真正会播的那一份」解析（`_resolveEffectiveAudio`，与
    `AudiobookSessionLauncher._resolveAudioFiles` 同序、同 `compareAudioFilePath` 排序），
    folder 模式展开成真实音频清单写进 manifest `audioPaths` → 下游不再有 folder 特例；
    目录不存在/无音频时把 `audioRoot` 记进 `missingResources`。
  - 导入侧：`_resourceName` 返回 `String?`，**不再回退 basename**；必需资源（音频/
    字幕/对齐文件）走 `_requiredResourcePath`，缺则抛 `SyncAssetPackageIncompleteException`，
    且抛在解压与写 DB **之前**（不留半截行、不写不存在的路径）。封面是装饰性资源，
    缺了降级为 null。不「跳过缺的音频继续导入」是因为 cue 的 `audioFileIndex` 是位置
    索引，少一个元素会让缺口之后每条 cue 都对到错误音轨。
  - 向后兼容：旧包没有 `missingResources` 键 → `_missingAtExport` 返回空列表，缺键
    绝不导致整包失败；健康包的 manifest 逐键与旧格式一致。
- **[x] ② 已加自动化测试** — `fushi/test/sync/sync_asset_package_missing_resource_test.dart`
  （8 条：导出记缺失 / 导入抛且零写库 / 纯 SRT 分支同律 / 封面降级 / 旧格式健康包仍成功 /
  旧格式坏包仍被拒 / folder 模式带上音频且与播放端同序 / folder 空目录留痕）。
  4 次变异实测各自杀掉对应用例（导入回退 basename → 3 红；导出静默 continue → 1 红；
  忽略 audioRoot → 2 红；封面回退 basename → 1 红）。
- **备注**：`test/sync` 全量 2028 条绿。提交哈希由集成方补。
