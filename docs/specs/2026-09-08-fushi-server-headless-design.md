# Fushi 无头服务端（Linux CLI + WebUI）与互联计算卸载设计

日期：2026-09-08 · 状态：四期全部落地（见 §7）· 分支 `worktree-fushi-server-headless`

## 0. 一句话

服务端不是新产品，是现有互联 host 角色的无头化：把已经存在的 shelf 服务器
（配对 PIN / TLS 指纹钉扎 / 能力位 / 库流播 / 远程 OCR 作业）从 Flutter app 里
抽成纯 Dart 包 `fushi_engine`，再用 `fushi_server` 这个 CLI 进程跑起来；客户端
沿用既有配对与 `RemoteLibrarySource` 消费路径，只为新卸载能力加能力位。

## 1. 用户拍板（2026-09-08）

| 问题 | 决定 |
|---|---|
| 包切分粒度 | 一个 `packages/fushi_engine` 大包 |
| 服务端与 GUI Fushi 同机共存 | 不需要。端口只走配置文件，不自动躲 |
| WebUI 上传文件 | 要 |
| 分期 | 四期全部做 |

## 2. 勘察结论（决定设计的硬事实）

- 传输层已完整：`fushi_sync_server.dart` + 7 个 part 是 shelf 服务器，HTTP
  Basic（用户名固定 `hibiki`，密码 = per-peer token），可选自签 EC P-256 TLS +
  SHA-256 指纹 TOFU；配对 v2 = 6 位 PIN + HMAC 证明，PIN 不过线；发现走
  mDNS `_fushi-sync._tcp`（bonsoir 插件）。**没有协议版本号**，靠
  `/api/capabilities` 能力位 + 404/405 降级；wire 冻结面见
  `docs/plans/2026-09-06-sync-interconnect-refactor.md`。
- 远程 OCR 作业协议已存在（`fushi_manga_ocr_host.dart`，
  `POST /api/ocr/job` → 逐页 `PUT` → `/start` → 轮询 → `/result`），客户端
  `interconnect_manga_ocr_client.dart` 已会消费。
- host 侧抽象 `FushiLibraryHostService`（37 个方法）只有一个实现
  `LocalLibraryHostService`，它靠构造回调解耦，**不直接依赖 AppModel**。
- ASR：上游 `hajisensai/fushi-asr` 已有纯 Dart FFI ORT 后端 `asr_onnx_ffi`
  与 `asr_cli` / `asr_server`；本仓 `asr_host.dart` 只是插件后端装配。
  有声书对齐执行器 `audiobook_alignment_service.dart` 也几乎纯 Dart。
- 下载执行器 `VideoDownloadPipelineService` DI 干净；Linux 缺
  `libfushi_torrent_ffi.so`（从未构建），回退外接 qBittorrent 的分支已存在。
- **传递闭包**：15 个候选根的 import 闭包是 1267 个文件（几乎整个 app）。
  但「干净文件 → 污染文件」的切割边只集中在几个枢纽：
  `utils/misc/error_log_service.dart`（124 处调用）、
  `models/preferences_repository.dart`（2 处）、`storage/app_paths.dart`
  （3 处）、`media/video/ffmpeg_backend.dart`（4 个调用方，ffmpeg-kit 插件）、
  `media/manga/mokuro_payload.dart`（`dart:ui`）、`media/video/video_storage.dart`
  （`FileImage.evict` 一行）、`epub/epub_book.dart`（只用
  `ReaderFushiSource.kHost` 常量）、`media/audiobook/subtitle_rematch.dart`
  （同文件混了两个 Slider 组件）、`models/content_font_chain.dart`
  （`cjk_font_families.dart` 的 `dart:ui Locale`）。
  `local_library_host_service.dart` 与 `source_library_scanner.dart` 各有
  85+ 条切割边（深耦合 `MediaSource` UI 类），**不净化，服务端另写无头实现**。
- 本仓无任何 `bin/*.dart`；`fushi_core` 只有 2 处 Flutter import，
  DB 走 `NativeDatabase`；`fushi_audio` 依赖 just_audio/audio_session/
  path_provider/charset 插件。

## 3. 架构

```
packages/fushi_core      Drift DB / 偏好（既有）
packages/fushi_audio     字幕解析 / 匹配 / 有声书仓储（既有）
packages/fushi_engine    ★新：纯 Dart 引擎（服务器 + 任务 + OCR + 下载 + 刮削 + ffmpeg）
packages/fushi_server    ★新：CLI 进程 bin/fushi_server.dart（config + headless host + WebUI + admin API）
fushi/                   Flutter app：依赖 fushi_engine，只保留 UI 与平台实现
```

### 3.1 工具链决定（明说）

`fushi_engine` 与 `fushi_server` 的 pubspec **不依赖 `flutter` sdk**，但它们
依赖的 `fushi_core` / `fushi_audio` 目前仍声明 flutter；因此**解析依赖时需要
Flutter SDK（构建工具链），运行时二进制不含 Flutter**。服务端构建命令固定为
`flutter pub get && dart compile exe packages/fushi_server/bin/fushi_server.dart`
（CI Linux job 已有 Flutter）。守卫测试禁止 `fushi_engine`/`fushi_server` 源码
出现 `package:flutter`、`dart:ui`、任何 method-channel 插件 import；
`dart compile exe` 是最终门（`dart:ui` 一旦进闭包直接编不过）。
把 `fushi_core` / `fushi_audio` 的 pubspec 彻底去 Flutter 是后续独立清理，
不在本项目内。

### 3.2 平台边界钩子（引擎侧全局装配点，与 `asr_host.dart` 同一范式）

| 钩子 | 引擎定义 | app 装配 | server 装配 |
|---|---|---|---|
| 日志 | `engineLog: EngineLogSink`（`log` / `logDiagnostic` / `logFatal`） | `ErrorLogService implements EngineLogSink` | stderr + 滚动文件 |
| 路径 | `enginePaths: EnginePaths`（documents/support/temp 根 + 子目录） | `AppPaths` 桥接 | 配置文件 `data_dir` |
| 偏好读取 | `PrefReader.getPref` | `PreferencesRepository implements PrefReader` | 服务端 `preferences` 表 |
| ffmpeg | `FfmpegBackend` 抽象 + `CliFfmpegBackend` + `ffmpegBackendProvider` | Android/iOS 装 `KitFfmpegBackend`（留在 app） | CLI（`FUSHI_FFMPEG` / PATH） |
| ONNX | `OnnxSessionFactory`（`asr_core` 既有） | `OrtOnnxSessionFactory`（flutter_onnxruntime） | `asr_onnx_ffi` |
| 封面缓存失效 | `coverImageEvictHook` | `FileImage.evict` | no-op |
| mDNS | `LanAdvertiser` 接口 | bonsoir | `avahi-publish` 子进程（缺 avahi 时只靠手动 IP） |
| 字符集探测 | `fushi_audio` 既有分级：纯 Dart → 平台 → utf8 兜底 | 插件 | 纯 Dart 一级 + 兜底 |

### 3.3 三种卸载的本质不同（决定协议形状）

- **下载 = 改变服务端的库**。客户端要的是「能播」，不是拿回文件。所以下载走
  服务端自己的 `VideoDownloadPipelineService` + `video_download_jobs` 表，
  完成后进服务端库，客户端用既有 `/api/library/videos` + `/stream` 消费。
  协议只加 `/api/downloads`（add / list / cancel / 订阅 CRUD）。
- **OCR = 计算任务，产物是 sidecar**。协议已存在，原样保留。
- **ASR = 计算任务，产物是 SRT（+ token sidecar），回挂到某个媒体**。走新的
  通用任务协议。

### 3.4 通用任务协议 `/api/jobs`

```
POST   /api/jobs                       {kind, params}          → {jobId}
PUT    /api/jobs/<id>/input/<name>     body=bytes              上传输入
POST   /api/jobs/<id>/start
GET    /api/jobs/<id>                  {state, progress, message, kind}
GET    /api/jobs/<id>/result           产物（kind 决定 content-type）
GET    /api/jobs/<id>/result/<name>    多产物按名取（如 tokens sidecar）
DELETE /api/jobs/<id>                  取消 / 清理
GET    /api/jobs                       列表（admin）
```

状态机照抄 OCR：`pending → uploading → running → done | error | cancelled`。
任务落 Drift 表 `host_jobs`（schema +1），重启可续；产物落
`<support>/host_jobs/<id>/`。能力位 `jobs.kinds: [asr]`。`kind=asr` 参数：
`{source: {upload|videoId|path}, language, model, align?: {epubUpload}}`。
`/api/ocr/job/*` **不迁移**到通用协议（冻结面）。

### 3.5 身份与鉴权

沿用 per-peer token（`fushi_paired_peers` 表）。服务端**只暴露配对 v2**
（PIN 打到 CLI 日志与 WebUI），不广播 v1（v1 需要 host 有 UI 点批准）。
WebUI / admin API 用独立 admin token（首次启动生成写入配置文件，或
`fushi_server admin reset-token`），与 peer token 分离；WebUI 登录 cookie 只
承载 admin token。多用户账号不做。

## 4. 分期

### 第 0 期：`fushi_engine` 抽离 + `fushi_server serve`（无头 host）

1. 建 `packages/fushi_engine`，用 `git mv` 把候选根的**干净闭包**平移进去
   （保持 `src/` 相对路径），全仓 import 改写 `package:fushi/src/X` →
   `package:fushi_engine/src/X`。
2. 切割边逐条处理：
   - `ErrorLogService.instance.log*` → `engineLog.log*`（124 处，脚本改）。
   - `AppPaths.*RootDirectory()` → `enginePaths.*`（3 处）。
   - `PreferencesRepository` 参数 → `PrefReader`（`video_source_scrape_config`、
     `media_tracking_service`）。
   - `ffmpeg_backend.dart`：`KitFfmpegBackend` 拆到 app 文件，引擎留抽象 +
     CLI + 解析函数 + `ffmpegBackendProvider`。
   - `mokuro_payload.dart`：`dart:ui Rect` → 引擎 `MokuroRect`（app 侧加
     扩展转 `Rect`）。
   - `video_storage.dart`：`FileImage.evict` → `coverImageEvictHook`。
   - `epub_book.dart`：`ReaderFushiSource.kHost` → 引擎常量 `kReaderFushiHost`，
     `ReaderFushiSource` 反向引用。
   - `subtitle_rematch.dart`：两个 Slider 组件拆到 app `subtitle_rematch_widgets.dart`。
   - `cjk_font_families.dart`：`CjkScript`/`CjkFontStyle` 枚举拆到引擎
     `cjk_script.dart`，字体映射留 app。
   - `interconnect_service_config.dart` / `pref_redaction_policy.dart` 引用的
     `k*Pref` 常量从 `media_tracking_service.dart` 抽到引擎 `tracking_pref_keys.dart`。
   - `lan_discovery_service.dart`（bonsoir）留 app，引擎定义 `LanAdvertiser`。
3. `fushi_core`：`debugPrint` → `fushiCoreLog` 钩子；`fushi_text_selection.dart`
   搬回 app。`fushi_audio`：`foundation` 的 `debugPrint/listEquals/
   visibleForTesting` → 钩子 / `collection` / `meta`；charset 插件级改注入。
4. `packages/fushi_server`：
   - `bin/fushi_server.dart`：`serve` / `pair` / `scan` / `jobs` / `download` /
     `transcribe` / `models` / `admin` 子命令（`package:args`）。
   - 配置文件 `fushi_server.yaml`（`data_dir` / `port` / `bind` / `tls` /
     `device_name` / `libraries[]` / `ffmpeg` / `admin_token` / `qbittorrent`）。
   - `HeadlessLibraryHostService implements FushiLibraryHostService`：
     videos（列表/封面/流/字幕/断点）、books（epub 导入 + 进度）、activity /
     aggregate / collections 走既有纯 Dart 服务；dictionaries / localaudio /
     audiobooks 第 0 期返回空集（能力位不宣告）。
   - `HeadlessLibraryScanner`：遍历 `libraries[]`，视频经 `VideoBookRepository`
     upsert + ffmpeg 封面 + 刮削协调器；epub 经 `epub_importer`。
   - mDNS：`avahi-publish` 子进程；无 avahi 打 warning。
5. 守卫：`fushi/test/build/fushi_engine_purity_guard_test.dart`（扫两包源码禁
   Flutter/插件 import）；CI Linux job 加 `dart compile exe` + `--help` 冒烟。

### 第 1 期：`/api/jobs` + ASR

- 引擎 `jobs/`：`HostJobManager`（表 `host_jobs`）、`HostJobKind` 注册表、shelf
  路由；`AsrJobRunner` 用 `asr_core` + `asr_onnx_ffi` + `FfmpegAsrPcmSource`，
  可选 EPUB 强制对齐（`audiobook_alignment_service`）。
- 客户端：`InterconnectJobClient`（照 `interconnect_manga_ocr_client` 的轮询
  退避）；`asr_transcribe_sheet.dart` 能力位存在时多一个「在 <设备名> 上运行」。

### 第 2 期：下载卸载

- 服务端起 `VideoDownloadPipelineService` + 订阅；torrent 先 qBittorrent
  后端，另起 CI job 构建 Linux `.so`（`native/fushi_torrent`），好了切内置。
- `/api/downloads`（add / list / cancel / subscriptions CRUD）；能力位 `downloads`。
- 客户端下载中心「目标：本机 / <服务端>」；远端任务列表只读展示。

### 第 3 期：WebUI + admin API + 上传

- `/ui` 静态单页（原生 JS，无框架，与 popup / 浏览器扩展同风格），
  `/api/admin/*`：status / logs / pairing(PIN、peers、revoke) / libraries
  (list、add、scan) / jobs / downloads / models / settings / upload。
- 上传：`PUT /api/admin/upload?library=<id>&path=<rel>`（分块 `Content-Range`
  可续传），落到库根后触发增量扫描；磁盘配额 `upload_quota_bytes`。

### 第 4 期：原生缺口

- `native/fushi_torrent` Linux 构建脚本 + CI job → `.so` 随 server 包。
- `fushidicts` Linux 构建 → 远程查词能力位。
- ORT CUDA EP 可选包（`asr_onnx_ffi` 已支持 CUDA provider 名）。

## 5. 不做

多用户账号；服务端阅读器 / 播放器；公网加固超出现有模型；
Android / iOS / macOS 装服务端；`/api/ocr/job` 迁通用协议。

## 6. 验证分级

- 第 0 期：全量 `flutter analyze`；`flutter test test/sync test/ocr
  test/media/video test/media/audiobook --no-pub`；Windows 上
  `dart compile exe` 出 `fushi_server.exe` 并与 Windows Fushi 真机配对、列库、
  流播、OCR 作业（协议层验证，平台无关）；Linux 编译走 CI。
- 第 1/2 期：引擎层 shelf 路由单测（`shelf` 内存请求）+ Windows 真机
  端到端（ASR 任务、下载任务）。
- 第 3 期：WebUI 走 node 宿主测试（与 popup 同法）+ 手工截图证据。

## 7. 落地记录（2026-09-08）

| 期 | 提交 | 交付 |
|---|---|---|
| 0A/0B/0C | `7330439057` `70a53e10c1` `362dd2a863` | `packages/fushi_engine`（平移 + 切割边钩子）、`packages/fushi_server`（init/serve/scan/status/pair/admin/models/transcribe）、纯度守卫、CI linux 出 bundle |
| 1 | `b5cbe92883` | `/api/jobs` 通用任务协议 + ASR runner；app 转录弹层「运行位置：本机 / host」 |
| 2 | `834f32bc65` | `/api/downloads` + `ServerDownloadHost`；app 手动下载对话框「下载到」+ 下载中心混排 host 任务 |
| 3 | `8e193edbe5` | admin 端口独立、token/cookie 鉴权、`/api/admin/*` 九组、单页 WebUI、分块可续上传 + 配额 |
| 4 | `38da0dde35` | `torrent.engine` 三态 + 内置 libtorrent 随包；ORT 随包 + CUDA 说明；CI 编 `.so`/下 ORT/真进程冒烟；README |

### 与原设计的偏差（明说）

- **订阅（tracker 订阅 CRUD）没进 `/api/downloads`**：host 只接客户端投来的磁力；订阅仍在客户端本地跑、可把目标选成 host。原因：订阅带发现页身份快照与「实例接管」判据，服务端没有发现页，硬塞会造出第二套判据。
- **漫画目录扫描没做**：`LibraryRootConfig.kind` 只认 `video` / `book`；漫画走客户端上传（既有 manga sync package）+ OCR 任务。
- **`ffmpeg` 配置项只做展示**：引擎 CLI 后端只认 `FUSHI_FFMPEG` 环境变量与可执行同级；`serve` 启动时校验路径并提示用环境变量。根治要改引擎的 ffmpeg 解析装配点，本轮不动（影响面是 app 五端）。
- **Linux torrent bridge 动态链接发行版 libtorrent**（不是 vcpkg 静态链）：目标机要装 `libtorrent-rasterbar2.0`。换静态链只多 40 分钟冷编、不多信息，等真有「目标机装不了 apt 包」的用户再说。
- **WebUI 没有浏览器级自动化测试**：内联 JS 过 `node --check`，API 面走真进程 HTTP 冒烟（27 + 9 项）；页面交互靠人工。
- **audiobooks 库服务仍返回空集**（第 0 期既定），有声书不经 host 托管。

### 验证证据（本机 Windows）

- `packages/fushi_server`：`dart analyze` 零 issue；`dart test` 9 条全过（配置往返 / 上传分块 / 随包库定位）。
- 真进程 HTTP 冒烟 `serve`：登录页 / 401 / Bearer / cookie 302+HttpOnly / 库 CRUD 写回 yaml / 上传三段+重放 409+穿越 400+配额账本 / 设置写回 / 扫描单飞 / 互联端口拒绝 admin 路由——27 项 PASS。
- 随包原生库冒烟：`bundle/lib/` 放入 `fushi_torrent_ffi.dll`（+3 个运行时 DLL）与 `onnxruntime.dll`，`torrent.engine: auto` 解析成 `embedded`（libtorrent 2.0.11），17 语 ASR plan 无 error，磁力任务经内置引擎入 `video_download_jobs` 并可删——9 项 PASS。
- Linux 真机没有：CI linux job 的冒烟步骤是 Linux 侧唯一证据（合并后看该 job）。
