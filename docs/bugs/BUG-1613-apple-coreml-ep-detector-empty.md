## BUG-1613 · Apple CoreML EP 上 int8 检测模型静默返回空结果且更慢
- **报告**：2026-08-14（用户：实现 iOS/macOS 漫画本地 OCR 时真机实测发现）
- **真实性**：✅ 真 bug — 根因 `fushi/lib/src/ocr/ocr_inference.dart:137`（`selectOcrExecutionProviders` 的 `OcrPlatform.macos` / `OcrPlatform.ios` 分支给检测模型选 CoreML）
- **[x] ① 已修复** — Apple 两端检测模型改走 CPU，`5d0a2f7`（见下「修复」）
- **[x] ② 已加自动化测试** — 两层：`fushi/test/ocr/manga_ocr_service_impl_test.dart` 的 `BUG-1613 macOS / iOS：检测与识别都是纯 CPU，绝不选 CoreML`（纯函数层）+ `fushi/integration_test/manga_ocr_volume_e2e_itest.dart`（真机端到端，断言必须检出块并逐字比对——**本 bug 就是被它抓到的**：CoreML 下它检出 0 块）
- **备注**：这段分支是 2026-07 写 OCR 流水线时**照着 Windows/DirectML 类比推出来的**，当时 `flutter_onnxruntime` vendored fork 把 Apple 整个 gate 掉了，所以它从落地那天起就不可达、从未被任何真机或 CI 验证过。2026-08-14 打开 Apple 本地 OCR 后它第一次被执行，缺陷当场暴露。

### 症状

iPhone SE 2（A13, iOS 26.6）上整卷本地 OCR「跑完了、不报错、耗时 20s」，但产出的 manga.json **一个文字块都没有**。同一份代码、同一份模型、同一页图在 macOS 上是 4/4 块、逐字 100% 正确。

### 根因

`selectOcrExecutionProviders` 对 Apple 两端给**检测模型**返回 `[coreml, cpu]`：

```dart
case OcrPlatform.macos:
case OcrPlatform.ios:
  if (kind == OcrModelKind.detection) {
    return const <OcrExecutionProvider>[
      OcrExecutionProvider.coreml,
      OcrExecutionProvider.cpu,
    ];
  }
```

检测模型是 **int8 量化**的 RT-DETR-v2（`detector-v4-s_int8.onnx`）。ORT 的 CoreML EP 把它交给 Apple Neural Engine 后：

- **iOS：输出全空**。不抛异常、不触发 `INVALID_PROVIDER` 回退，`onProviderResolved` 也照常报 `effective=coreml, fallback=null` —— 也就是说**现有的降级可观测性（BUG-1163）完全看不见这条**：它不是降级，是「成功地算出了错的东西」。
- **macOS：结果正确**，但比 CPU 慢。

### 实测数据（定位期的一次性对拍脚本，数据留档于此；常驻断言见 ②）

同一页 1200×1700 合成漫画（4 个竖排气泡），1 次预热 + 3 次稳态取中位：

| 平台 | EP | 检出（文字区/气泡） | 建会话 | 稳态/页 |
|---|---|---|---|---|
| macOS 26.6 (M 系列) | CoreML | 4 / 4 | 4248ms | 237ms |
| macOS 26.6 (M 系列) | **CPU** | 4 / 4 | **79ms** | **148ms** |
| iOS 26.6 (A13) | CoreML | **0 / 0** ❌ | 9269ms | 1491ms |
| iOS 26.6 (A13) | **CPU** | **4 / 4** ✅ | **174ms** | **381ms** |

两端 CPU 都**又快又对**：macOS 每页快 1.6×、建会话省 4.2s；iOS 每页快 3.9×、建会话省 9.1s。CoreML 在任何页数下都追不平（总耗时 `4248 + 237N` vs `79 + 148N`，N≥1 恒负）。

### 修复

`selectOcrExecutionProviders` 的 Apple 分支与 linux/android 合并成 CPU 单档，并把「为什么不用 CoreML」的实测结论写进 doc，防止下一个人再按直觉加回来。

`OcrExecutionProvider.coreml` 枚举与 `_toOrtProvider` 的映射**保留**：它们是 ORT 的合法能力面，将来换非量化检测模型时可能重新可用；删掉只会让重新评估时无处可接。

### 为什么单测抓不到

`selectOcrExecutionProviders` 是纯函数，改之前它的单测钉的就是「Apple 返回 coreml」——测试和实现一起错，因为两者都源自同一个未经验证的假设。只有真机跑真模型才能证伪。故 ② 的自动化测试同时落两层：纯函数层钉住新结论，真机层钉住「CPU 路径必须检出框」这条与模型行为直接挂钩的不变式。
