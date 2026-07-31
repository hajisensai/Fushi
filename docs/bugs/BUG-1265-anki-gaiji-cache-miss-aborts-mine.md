## BUG-1265 · AnkiConnect 制卡：词典外字缓存缺失导致整张卡建不出来
- **报告**：2026-07-31（用户：报错日志 `2026-07-30 23:29:45` `Anki.mineEntry`）
- **真实性**：✅ 真 bug。根因两层：
  - **① 读取方硬失败（真正杀掉整张卡的）**：`packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart:1635`（修前）在缓存文件缺失时 `throw FileSystemException`，经 `_renderMinedFields` 的 `Future.wait` 抛穿 `mineEntry`，整次制卡失败、`addNote` 从未被调用。
    但共享契约 `BaseAnkiRepository.buildDictionaryMediaTags`（`packages/hibiki_anki/lib/src/base_anki_repository.dart:386`）收的是 `Future<String?>`——**返回 null = 跳过这条媒体**；AnkiDroid `packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart:704`（`if (!file.existsSync()) return null;`）与 AnkiMobile `hibiki/lib/src/anki/ankimobile_repository.dart:449` 一直是优雅降级。只有 AnkiConnect 破契约。
    回溯：commit `35e8c96b5 fix(anki): require media before adding cards` 把封面/句子音频的「缺媒体就别建卡」策略**误扫**到了装饰性的词典外字上（同一个 commit 把 `return null` 改成了 `throw`）。
  - **② 写入方静默跳过（为什么缓存里会没有这个文件）**：`hibiki/lib/src/pages/implementations/dictionary_webview_media.dart:29` 的 `writeDictionaryMediaCache` 按设计尽力而为——`HoshiDicts` 未初始化、`getMediaFile` 取不到字节（分卷 MDD 未挂载 / 词典里本就没这个资源 / 词典删除重导）、写盘失败，三条路径全部静默跳过（前两条连 `debugPrint` 都没有），文档写明契约是「该条媒体退回 alt 文本，不阻断制卡」。
    于是「缓存里没有这个文件」在用户上传的日志里毫无前因，只剩下游一句 `Dictionary media file is missing`。

  用户侧栈（Windows / AnkiConnect / 视频页沉浸制卡）：
  ```
  Anki.mineEntry  FileSystemException: Dictionary media file is missing,
    path = 'C:\Users\…\Temp/anki-media/hibiki_dict_aea8ccb2….svg'
  #0 AnkiConnectRepository._storeDictionaryMedia (…:1635)
  #1 AnkiConnectRepository._renderMinedFields.<anonymous closure> (…:795)
  #2 BaseAnkiRepository.buildDictionaryMediaTags (…:386)
  #4 AnkiConnectRepository._renderMinedFields (…:799)
  #5 AnkiConnectRepository._mineEntryInner (…:662)
  #7 ImmersionMiningEngine._mineNow (…:296)
  ```

- **[x] ① 已修复** — commit 见下。两处：
  - `ankiconnect_repository.dart` `_storeDictionaryMedia` 改回 `Future<String?>`，缺失时带上下文 `debugPrint` 后 `return null`，与另两个 backend 同契约。封面/句子音频仍由 `_storeLocalMedia` 抛异常拦住（缺了卡片没价值），**两套策略故意不同，不要再合并**。
  - `dictionary_webview_media.dart` 的三条跳过路径全部改为带原因留痕（`debugPrint` + `ErrorLogService.log('DictionaryMedia.cache', …)`），下次用户报错时能直接判断是「词典取不到字节」还是「根本没走到写入方」。另把 `HoshiDicts.isInitialized` 判断挪到「确实有媒体要写」之后，无媒体时不产生噪音日志。
- **[x] ② 已加自动化测试** — `packages/hibiki_anki/test/dictionary_media_missing_degrades_test.dart`（3 条，走完整 `mineEntry` 落卡链）：
  1. 缓存缺失 → `MineResult.success` + `addNote` 真被调用 + 占位符保持原样（降级）+ 封面照常上传；
  2. 混排（一条有缓存 / 一条没有）→ 有的正常替换成 `hibiki_dict_<sha1>.svg`，没有的单独降级，不拖累邻居；
  3. 对比组：封面缺失**仍然** `MineResult.error`，锁死两套策略的差异。

  变异实测：把 `return null` 改回 `throw FileSystemException` 后，第 1、2 条立刻转红（`Expected: MineResult.success / Actual: MineResult.error`），第 3 条保持绿——测试确实咬住了根因，不是假绿。
- **备注**：降级后卡片里留的是未替换的 `<img src="hoshi_dict_N.ext">` 占位符（等价于 alt 文本），与 AnkiDroid/AnkiMobile 行为一致，属既有契约。若要进一步把无法解析的占位符从字段里剥掉，是**三个 backend 共同**的独立改动，不在本 bug 范围内。
