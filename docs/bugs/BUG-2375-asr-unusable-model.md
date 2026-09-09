## BUG-2375 · ASR 模型文件损坏后永久卡死：Protobuf parsing failed 且无自愈路径
- **报告**：2026-09-09（用户：截图，设备端语音转录弹层）
- **真实性**：✅ 真 bug。根因 `packages/asr_core/lib/src/asr/asr_model_manifest.dart:1096`（上游 `hajisensai/fushi-subtitles`）的 `isAsrModelFileReady` 只判「存在且非空」，坏档永远被判为已就绪
- **[x] ① 已修复** — 上游 PR [#9](https://github.com/hajisensai/fushi-subtitles/pull/9)（merge commit `b8a7b76`）：`AsrEngineLoader._openManifestSession` 在建会话失败时用 `isOnnxUnreadableModelFailure` 分类，命中「文件读不出图」的标记就删掉该文件并抛 `AsrModelFileUnusableException`；本仓 bump 钉定 sha + `asr_transcribe_sheet.dart` 的 `_failWith` 把这类失败退回既有的「需要下载」阶段
- **[x] ② 已加自动化测试** — 上游 `packages/asr_core/test/asr/asr_model_file_unusable_test.dart`（6 条：用户报障原文分类、三种 ORT 实测原文、EP/显存类失败的负向判定、坏档从磁盘消失且不牵连同目录其它文件）
- **备注**：

### 现象

转录弹层里只有一句，重试同样复现：

```
转录失败: Bad state: PlatformException(ORT_ERROR, Load model from
D:\hibiki\support\asr_models\reazonspeech-k2-v2\encoder-epoch-99-avg-1.onnx
failed:Protobuf parsing failed., false, null)
```

### 定性证据

本机 onnxruntime 1.22 实测四种情形（错误串来自 ORT C++ 核心，FFI 与插件两个宿主一致）：

| 文件状态 | ORT 报错 |
|---|---|
| 不存在 | `NO_SUCHFILE ... File doesn't exist` |
| 0 字节 | `ModelProto does not have a graph` |
| **被截断 / 内容不是 onnx** | **`INVALID_PROTOBUF ... Protobuf parsing failed`** ← 与报障逐字一致 |

所以那份 encoder **存在、非空、内容是残档**。

### 根因

不在下载器：`ModelFileDownloader._finalizePart` 在 rename 前的长度校验是严的，坏档是**转正之后**才产生的（写盘中断、外部截断、断电后 NTFS 内容 NUL 化）。真正的问题是这种档没有出路——`isAsrModelFileReady` 判「存在且非空」，坏档永远满足它：设置页显示已下载、`downloadAll` 当就绪跳过、转录每次在同一处炸，用户除了手删整个模型目录没有别的办法，而错误文本里没有任何提示指向那里。

`Bad state:` 前缀来自 `asr_transcribe_isolate.dart:215`——整本转录跑在后台 isolate，错误跨边界被统一压成 `StateError(文本)`，所以 UI 侧只能按文本识别，不能按异常类型。

### 刻意没做的事

**没有**把 `isAsrModelFileReady` 改成按清单 `expectedBytes` 强校验。清单字节数会因上游重新导出而过期，强校验会把「长度不符但确实跑得起来」的旧档误判成缺失，逼用户重下几百 MB（原注释里已写明这条宽松语义是故意的）。长度只作为异常上的诊断字段，不参与判定。
