## BUG-1493 · 词典下载不走系统代理、无超时，且下载/导入阶段无可归因进度
- **报告**：2026-08-10（用户：词典管理页遮罩 + 「正在更新 Pixiv Light [2026-02-01]…」，进度条几乎贴在最左端长时间不动，问「更新这么慢，是网络原因吗」）
- **真实性**：✅ 真 bug（两条独立缺陷：出站装配 + 进度归因）

### 慢在哪一段——先定性再回答

**证据链（纯代码结构，不靠猜）**：

1. 进度条是 `fushi/lib/src/pages/implementations/dictionary_dialog_page.dart:1990` `LinearProgressIndicator(value: progress > 0 ? progress : null)`。用户看到的是**贴左端的定值**而不是不定态来回滚动的动画 → `progress > 0` 且很小 → **下载已开始、字节在进但极慢**。
2. 文案仍是 `dict_update_updating`。而只要进到导入，`fushi/lib/src/models/dictionary_import_manager.dart:338` 第一句就会把它改写成 `import_extract` → **那一刻还没进导入**。

两个信号一致指向**下载阶段**。所以：慢在网络下载，不在 C++ 建索引。

### 根因 ①：词典链路根本不走代理，也没有任何超时

- 出站是裸 `Dio()`（修前 `packages/fushi_dictionary/lib/src/formats/dictionary_downloader.dart:784` 与 `dictionary_update_service.dart:155`）。Dio 默认 `IOHttpClientAdapter` 建出来的 `HttpClient` 其 `findProxy` 为 null，**既不读 `HTTP_PROXY`/`HTTPS_PROXY` 环境变量，也不读 Windows 注册表里的系统代理**。
- 全应用唯一的代理解析层 `fushi/lib/src/utils/net/app_proxy.dart:145` `applyAppProxy`（`env > GUI 系统代理 > DIRECT`）此前只有 4 个调用点（更新检查/更新包下载、云同步 OAuth、下载发现），该文件 `:24-28` 白纸黑字把「词典 / 字体 / shader / OCR 模型下载」列在**不经本层**的名单里。
- 而词典源全在 `github.com` / `raw.githubusercontent.com` / `huggingface.co`（`dictionary_downloader.dart:127-134` 的 base 常量）；用户这本 Pixiv 词典正是 `raw.githubusercontent.com/MarvNC/yomitan-dictionaries/master/dl/...`，约 30MB。**同一台机器上浏览器秒开 GitHub、app 里直连下 30MB，这就是「慢」的一半。**
- 另一半：`Dio()` 默认 `connectTimeout`/`receiveTimeout` 均为 null = **不超时**。服务器把连接晾着不发数据就能无限挂住，用户永远停在「正在更新…」。该链路当时也无重试、无镜像回退、无断点续传，`download` 的 `cancelToken` 形参三个调用点全不传且进度框 `barrierDismissible: false` → **没有取消按钮，只能杀进程**。

### 根因 ②：进度不可归因

- 下载期 `progressNotifier`（文案）只在开头写一次静态「正在更新 X…」，全程不变，用户看不出这是在下载、下到哪了。
- 导入期**没有任何一处**再写 `downloadProgress`：native 导入是一次不可分割的 FFI 调用（`packages/fushi_dictionary/lib/src/engine/fushidicts.dart:465` `Isolate.run`），C++ 侧零进度回调（`native/fushidicts/fushidicts_ffi.cpp` 无 callback/port/progress 任何形参）。下载结束时进度条是 1.0，于是**整个导入期定格在满格一动不动**——这才是「看起来卡死」的直接来源。

- **[x] ① 已修复** —
  - `packages/fushi_dictionary/lib/src/formats/dictionary_downloader.dart`：新增进程级 `dictionaryDioFactory` 钩子 + `createDictionaryDio()`（统一钉死 `kDictionaryConnectTimeout` 30s / `kDictionaryStallTimeout` 60s），`download` 与 `dictionary_update_service.dart` 的 `fetchRemoteIndexResult` 一律经它出站；`download` 增开 `onBytes` 回调透出原始字节数。
  - `fushi/lib/src/utils/net/dictionary_dio.dart`（新增）：app 侧把该工厂接到 `applyAppProxy`，`AppModel.initialise()` 里 `installDictionaryDioFactory()` 一次性接线。**零新 UI、零新配置**——无代理时解析结果就是 DIRECT，与接线前逐字等价。
  - 进度分阶段：`dictionary_dialog_page.dart` 的 `dictionaryDownloadStageMessage`（下载中 + 已下载/总量，`Content-Length` 缺失时不显示假分母）与 `enterDictionaryImportStage`（**把进度条归零 → 退化成不定态动画**，如实表达「正在处理、无法估算」），单本更新与批量下载两条路径共用。
  - 新增 i18n key `dict_downloading_size`（`i18n_sync --add` + `dart run slang`，17 语言齐）。
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/dictionary_download_proxy_progress_test.dart`（10 例：工厂未接线/已接线的回退与调用、超时兜底、app 侧 adapter 非默认、`installDictionaryDioFactory` 幂等、两种下载文案分支、导入阶段归零、以及「词典链路不得再出现裸 `Dio()`」的源码扫描守卫 + 剥注释器自测）。变异实测：把 `download` 改回裸 `Dio()`、把导入阶段的归零删掉，各打红对应用例，反向替换还原。

- **备注 / 未验证缺口**：
  - **代理接线的边界**：只接了「词典包下载 + index.json 拉取」两条。`app_proxy.dart:24-28` 名单里的字体 / shader / OCR 模型下载、刮削、弹幕等仍是裸出站，本条不动它们。
  - 未做**端到端计时验证**（本机没有可复现的真词典更新场景 + 需要真实网络对照组），「接代理后变快多少」没有实测数字；上述定性完全基于代码结构与两个 UI 信号的交叉印证。
  - 仍**没有取消按钮**：`cancelToken` 形参存在但三个调用点都不传，进度框 `barrierDismissible: false`。60s 停顿超时把「无限挂住」变成了可见失败，但用户主动中止一次进行中的慢下载仍做不到。这是本条剩下的产品缺口，独立于两条根因。
