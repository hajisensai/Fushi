# Sasayaki 上游对齐 — 剩余 PR

对齐对象：https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md

已落地：PR1（多格式 EpubCueMatcher）/ PR2（AudiobookHealth + match rate UI + 可调 searchWindow）/ PR8a（ttu fork 挂 `__ttuGoToSection` 等 API，见 `docs/ttu-fork-notes.md`）/ PR8b（Follow audio 开关 + pill 降级）。剩下只有 PR6。

---

## PR6 — `{sasayaki-audio}` Anki handlebar

### 动机
上游的 Anki 片段能**把 cue 扩展到句子边界**，hibiki 的 Anki 管线来自 jidoujisho，没有 Sasayaki 语义。本 PR 新增一个独立 handlebar，不动既有管线。

### 范围
- 在 `AnkiExportField` 系统里注册新 handlebar `{sasayaki-audio}`
- 实现 `SasayakiClipBuilder`：
  1. 拿当前选中文本对应的 cue（通过 `AudiobookBridge.cueForSelection`）
  2. 句子边界扩展：从当前 cue 向前回溯到前一个句号类标点（`。！？」』`），向后扩到下一个句号类标点。**跨 cue 合并为连续时间段**，以最早 `start` 和最晚 `end` 作为切段范围
  3. 用 `ffmpeg_kit_flutter`（如项目已有）或 `just_audio` seek + 录制 fallback 切段成 mp3，写入 AnkiDroid 媒体目录
  4. handlebar 返回 `[sound:filename.mp3]`
- 失败降级：当前选词不在任何 cue → handlebar 返回空字符串（与 jidoujisho 现有 handlebar 行为一致）

### 风险
- `ffmpeg_kit_flutter` 体积大，如项目未引入，先评估是否用 `just_audio` 的 `setClip` + AudioSession 录制 fallback（精度略差但无新依赖）
- 句子边界扩展在中文/日文混排时需测试（日文以 `。` 为主，中文可能出现 `，` 分隔长句）；保守策略：**只以 `。！？` 为边界**，不扩张就不扩张，不追求完美
