## BUG-2080 · 浏览器扩展 Netflix 制卡的片段时间窗恒为 0，卡上永远显示不出时间
- **报告**：2026-09-03（PR #1161「卡片 Details 栏带上截取片段的时间窗」的代码审查副产物，不是用户报告）
- **真实性**：✅ 真 bug（静态追链确认，未做真机落卡）。根因 `fushi/lib/src/mining/immersion_capture_channel.dart:191-192`：纯函数 `buildImmersionRequest` 把 `clipStartMs` / `clipEndMs` **硬编码成 0**，而入参 `ImmersionMinePayload` 明明带着可用的 `clipStartMs` / `clipEndMs`（`fushi/lib/src/models/app_model.dart:7743-7748` 就是用它俩去 `ImmersionCaptureChannel.capture` 抓片段的）。YouTube 分支反而是通的（`app_model.dart:7664-7665` 经 `youtube_clip_miner` 带真值）。于是 `{clip-timestamp}` 对 Netflix 用户**结构性恒空**
- **[ ] ① 未修复** — 见下「为什么不是一行改」；PR #1161 只记录，不顺手改
- **[ ] ② 未加自动化测试** — 修的时候和修复一起加（`buildImmersionRequest` 是纯函数，断言成本极低）
- **备注**：与 PR #1161 同域但独立。该 PR 新增的 `{clip-timestamp}` 占位符在本地视频 / YouTube / 互联转发三条路上都通，唯独浏览器扩展的 Netflix 路不通。

### 为什么不是一行改（实测的耦合）

把 `clipStartMs: 0, clipEndMs: 0` 直接换成 `p.clipStartMs ?? 0, p.clipEndMs ?? 0` **会改变 Netflix 的既有制卡行为**——这两个字段在引擎里还兼着第二个语义：

`fushi/lib/src/mining/immersion_mining_request.dart:363`

```dart
bool get hasRange => clipEndMs > clipStartMs;
```

`hasRange` 是引擎的行为闸门，Netflix 路径当前恒 `false`，两处依赖它：

- `fushi/lib/src/mining/immersion_mining_engine.dart:437-441`
  ```dart
  final bool viaProvidedBytes = req.providedCoverBytes != null && !req.hasRange;
  if (req.requireAudio && audioPath == null && (req.hasRange || viaProvidedBytes)) { ... abort ... }
  ```
  TODO-1303 的「Netflix 录制片段丢音轨 → 中止而非静默出无声卡」正是靠 `viaProvidedBytes` 这条**无 range** 分支生效的。填了真值窗 → `viaProvidedBytes` 变假、`hasRange` 变真，中止判据换了一条腿：原先「有 providedCoverBytes 才中止」变成「无条件按 range 中止」，2A 截图卡（无音频、本就不该算失败）会开始被判失败。
- `fushi/lib/src/mining/immersion_mining_engine.dart:410`
  ```dart
  if (coverPath != null) degradedToStill = req.hasRange;
  ```
  Netflix 截图卡会开始被标成「降级为静态」并弹 OSD。

现有测试也把这条不变式写死了：`fushi/test/mining/immersion_mining_engine_test.dart:445` 的注释「此前 requireAudio 被 `&& hasRange` 门控架空（Netflix clip 恒 hasRange=false）」，且该用例就是用 `clipStartMs: 0, clipEndMs: 0` + `providedCoverBytes` 构造的。

这是本仓已知的「同一数字两层两语义」形态：**抽取区间**（引擎要不要去裁 GIF / 音频）和**卡面时间窗**（渲染 `{clip-timestamp}` 给用户看）共用了同一对字段。Netflix 恰好是「有卡面时间窗、但没有本地可裁的源」，两个语义第一次分叉。

### 修复方向（择一，动手前先定）

1. **拆语义**（推荐）：给 `ImmersionMiningRequest` 加一对只喂 `AnkiMiningContext` 的显示用字段，`immersion_mining_engine.dart:470` 处 `?? clipStartMs` 回落；`hasRange` 与抽取路径一个字节不动。改动小、零行为变更，代价是多一对字段（要在字段注释里把两个语义的分工写死，否则就是又造一个「同一数字两层两语义」）。
2. **收敛 `hasRange`**：把「引擎要不要裁」从「时间窗非空」改成一个显式的意图字段（如 `mediaSource != null && 有区间`），再让时间窗只表示卡面语义。更干净，但要重新审 TODO-1303 的中止矩阵和 `degradedToStill`，属于独立改动，不该塞进 #1161。

无论哪条，都必须补 `buildImmersionRequest` 的纯函数断言（Netflix payload 带窗 → request 带窗）+ 引擎那两条 `hasRange` 分支的回归用例。
