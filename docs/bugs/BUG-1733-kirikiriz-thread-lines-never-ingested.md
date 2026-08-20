## BUG-1733 · 选中 KiriKiriZ 文本线程后实时台词恒 0，且没有任何东西告诉用户这条线程不可能产出台词
- **报告**：2026-08-19（用户：真机验证游戏内查词制卡时发现）
- **真实性**：✅ 真 bug（用户可见后果真实），但**根因不在 native 过滤**——过滤是对的。根因是 UI 侧把一条结构上必然空的线程呈现为最健康的选项，见下。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：见下。**本文件第一版把根因写成「伪影门误杀好行」，被运行期证据推翻，已整体更正**；更正过程本身记在末尾，因为它是这条 bug 最容易重犯的坑。

### 复现（真机，2026-08-19）

《天使☆嚣嚣 RE-BOOT!》（`tenshi_sz.exe`，KiriKiri Z），由 Fushi 2.1.1-debug.11887「启动游戏」拉起。

1. 工作台选文本线程 `KiriKiriZ · 0x54c450 · #0a47`。
2. 推进剧情，**下拉框自己的计数在涨**：`· 1` → `· 4` → `· 5`。
3. 但「实时台词」恒为 **0**，中间一直是「尚未收到台词」，状态卡在「正在监听 / 等待信号」。
4. 换选 `EmbedKrkrZ · 0x452188` → **实时台词立刻变成 8 条**，逐句正确。

后果：制卡拿不到 line id → 静默失败（BUG-1734）。用户完全没有线索知道该换线程。

### 真根因（运行期实证，非静态推断）

用 `FUSHI_LUNA_DIAG=1` 手动经 injector 拉起同一游戏，把**过滤前每一行**打到 stderr，
同一句话在两个 hook 面上的原文是：

```
name=EmbedKrkrZ  raw_len=26 normalized_len=13  「聞いたことくらいはある」「聞いたことくらいはある」
name=KiriKiriZ   raw_len=26 normalized_len=26  「「聞聞いいたたここととくくららいいははああるる」」
name=KiriKiriZ   raw_len=39 normalized_len=39  「「「聞聞聞いいいたたたここことととくくくらららいいいはははあああるるる」」」
name=KiriKiriZ   raw_len=18 normalized_len=18  【 天音 】【 天音 】【 天音 】
```

- `EmbedKrkrZ` 是**整串二倍**（`X+X`），块级折叠 `LunaNormalizedTextLength`
  （`include/luna_text_selector.h:45`）正好吃掉它：26 → 13，干净行入环。
- `KiriKiriZ` 的三条线程是**逐字二倍 / 逐字三倍 / 名字整块重复**。逐字重复的块长 k=1，
  远小于 `kLunaMinFoldedLineChars = 4`（`luna_text_selector.h:16`），**折叠在设计上就折不动它**；
  于是 `normalized_len == raw_len`，随后 `LunaTextIsArtifact`（`:77-103`）按「相邻重复字占比 ≥30%」
  把它判为伪影，`LunaShouldWriteLine`（`injector_main.cpp:830`）丢弃。

**这个丢弃是正确的**：那串东西不是台词，进环只会污染浮窗、台词列表和卡片的例句字段。
所以 native 侧无需修改，也**绝不能**为了让计数变成非零而放宽伪影判据——那等于把
「聞聞いいたた」写进用户的 Anki 卡。

真正的缺陷在这里：

1. **下拉框的计数用的是「观测数」而不是「已发布数」**。
   `observedLineCount`（`fushi/lib/src/sync/texthooker_service.dart:250`，注释自己写着"含被伪影过滤和
   线程门控丢弃的"）来自预览区，native 侧 `injector_main.cpp:799` 无条件 `slot->line_count++`。
   于是一条 100% 伪影的线程和一条健康线程在选择器里都显示"有 5 条"。
2. **预览副标题被折叠成干净句子**。`collapseTexthookerPreview`（`texthooker_service.dart:45-51`）
   把「「聞聞いい…」」显示成「聞いた…」，把唯一的肉眼线索也抹掉。**我本人就是照"预览最干净"
   选中了那条死线程**。
3. **伪影信号采到了却不渲染**。`previewIsArtifact` / `observedArtifactCount` 一路传到 Dart
   （`gal_hook_session_controller.dart:3638`、`texthooker_service.dart:254`/`:257`），
   但全 app 只用于排序（`:551-553`）。详见 BUG-1735。
4. **选中之后没有任何反馈说"这条线程一条都没通过"**。状态文案「等待信号」与「实时台词 0」
   是同一个空列表的两个投影（`gal_hook_session_controller.dart:3732` 只在 `appendLine` 成功后
   才置 `receivedTextLine=true`），用户无法区分"游戏还没出台词"和"我选了一条死线程"。

### 修复方向

- 选择器同时显示「观测 N / 已发布 M」，M=0 且 N>0 的线程直接标注为不可用（配 BUG-1735 的伪影标记）。
- 预览折叠时保留"已折叠 ×k"标记，不要让折叠结果冒充健康输出。
- 选中一条线程后若持续只观测不发布，主动提示换线程（这也顺带覆盖 BUG-1734 的用户可见性）。
- native 侧不动。

### 更正记录（重要）

本文件第一版（本次会话早期）把根因写成「消重折叠只对 `EmbedKrkrZ` 生效
（`luna_text_selector.h:71`），KiriKiri 的串原样进伪影判定被误杀」，并据此打算把折叠推广到
所有 hook。**这是错的**：`KiriKiriZ` 的串是逐字重复，折叠本来就折不动它；按那个方向改只会
放宽伪影门、把垃圾写进卡片。推翻它的是 `FUSHI_LUNA_DIAG=1` 的逐行原文——**静态代码链条读起来
完全自洽，但结论是错的，只有运行期原始串能定性**。下次遇到"某类线程收不到行"，先取
lunadiag 原文再谈根因。
