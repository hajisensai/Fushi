## BUG-293 · 删卡后再制同词闪退（mineEntry/updateEntry 桥接处理器异常逃逸到原生 JS-handler 边界）
- **报告**：2026-06-15（用户：如果我删掉了刚制的卡，然后再制同一个单词的卡，会闪退。TODO-392）
- **真实性**：✅ 真 bug（边界契约缺陷）。沿真实代码路径逐层验真伪：
  - **制卡/再制卡完整路径**：`hibiki/assets/popup/popup.js` mine button onclick（`createEntryHeader`，~1690）
    → 三态分支：①绿 ✓↩「最新可改」(`lastMinedNoteId` 非空) 走 `updateEntry()`→桥 `updateEntry`；
    ②普通 ✓（查词时检测已制卡）点击先 `duplicateCheck` 复查，删了就 fall-through 重制；
    ③`+` 走 `mineEntry()`→桥 `mineEntry`。
    → 桥接 `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:761/785`
      （`addJavaScriptHandler('mineEntry'/'updateEntry')`）
    → 各表面 override：reader `reader_hibiki_page.dart:3571/3622`、视频 `video_hibiki_page.dart:2685/2723`
      （→`_mineVideoCard:2764`）、词典/有声书 `dictionary_page_mixin.dart:124/162`
    → repo `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart:304`（`mineEntry`）/`:516`
      （`updateMinedNote`）、`ankidroid/anki_repository.dart:163/344`。
  - **逐层验伪结论**：repo 层（两后端）`mineEntry`/`updateMinedNote` 全部 try/catch 兜底，删卡后再制/覆盖
    一律返回 `MineOutcome.failure`（AnkiConnect `updateNoteFields` 命中已删 note→`AnkiConnectException`→failure；
    AnkiDroid native `getNote(deletedId)==null`→`UPDATE_NOTE_FAILED`→`PlatformException`→failure）；
    各表面 override 的成功/失败分支只弹 toast/OSD。**纯 Anki 逻辑链不会崩**，会优雅降级。
  - **真正根因 = 边界契约缺陷**：桥接 `mineEntry`/`updateEntry` 两个 `addJavaScriptHandler` callback
    **没有 try/catch**（对比同文件 `duplicateCheck`/`favoriteCheck` 也未包，但它们 override 不做重活）。
    再制同词时必然**重跑媒体捕获**（视频 `_mineVideoCard` 的 `extractClipGifViaFfmpeg`/`controller.screenshot()`
    /`extractAudioSegmentViaFfmpeg`、reader `_prepareMiningContext` 的 `TtsChannel.extractAudioSegment`），
    这些是**原生**调用（Windows GraphicsCapture / WebView2 抓帧 / ffmpeg 进程），可能**抛出**而非返回 null。
    `_mineVideoCard` 整段无 try/catch（reader `onMineFromPopup` 有 try/finally 但 `_prepareMiningContext` 内
    `extractAudioSegment` 抛出仍逃逸）。一旦 override 抛出，异常逐层逃逸到桥接 callback，再**跨 Dart→原生
    inappwebview JS-handler 边界**——未捕获异常穿过 FFI/原生回调边界会把整个进程带崩（闪退），与已修
    BUG-233（制卡路径 ffmpeg/GraphicsCapture 原生崩）、BUG-077（mine handler 必须返回而非抛出）同类。
    「删卡→再制同词」是稳定触发器：它逼用户在同一会话对同一词二次走完整媒体捕获链。
- **[x] ① 已修复** — `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart`：
  把 `mineEntry`/`updateEntry` 两个桥接 callback 的整段 body 包进 try/catch，任何逃逸异常（override 抛出、
  `writeDictionaryMediaCache` 抛出、媒体捕获原生异常）都经 `ErrorLogService` 记录后**返回
  `MinePopupResult()`（失败态）**，绝不让异常跨原生 JS-handler 边界。这是把 BUG-077 为 repo 层确立、
  BUG-089 为错误可见性确立的「handler 必须返回、绝不抛出」契约落到**真正拥有该边界的单一注册点**——
  全 app 仅此一处 `addJavaScriptHandler('mineEntry'/'updateEntry')`，所有表面（reader/视频/词典/有声书）
  共用，一处加固即覆盖全部 override（消除 N 个 override 各自兜底的特例，Linus：让边界拥有契约）。
  不动 repo/native/JS 既有降级语义、不吞 Anki 业务失败（业务失败本就返回 failure 弹 toast）。
- **[x] ② 已加自动化测试** —
  - 行为（widget）：`hibiki/test/pages/dictionary_popup_mine_bridge_crash_test.dart` —— 用真实
    `DictionaryPopupWebView` 注入会抛异常的 `onMineEntry`/`onUpdateEntry`，断言桥接 callback 不把异常
    抛出边界、仍返回有效 `MinePopupResult`（撤修复则红）。
  - 源码守卫：同文件内静态扫描，锁定两个 callback body 含 try/catch + `ErrorLogService.instance.log`，
    防回归（再有人去掉 try/catch 立刻红）。
- **备注**：根因层（边界契约）已根治——再制同词任何媒体捕获原生异常都不再崩进程，转为可见失败 + 错误日志。
  **真实「再制同词原生崩溃签名是否消失」需用户真机/真 Anki 复测**（host 跑不到 GraphicsCapture/ffmpeg/
  WebView2 原生路径，与 BUG-233 同）：用户用「ひびき anki 卡组」，**桌面走 AnkiConnect、Android 走 AnkiDroid
  均覆盖**（边界修复后端无关）；建议优先复测原报告设备 + 视频/有声书制卡（媒体捕获最重的两个表面）。
  本修复不替代后续对具体原生崩（若 GraphicsCapture/ffmpeg 仍在底层崩）的根治，但保证异常不再升级成闪退。
