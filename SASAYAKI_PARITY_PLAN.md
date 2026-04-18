# Sasayaki 上游对齐 PR 规划

对齐对象：https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md

目标：把 iOS 版 Sasayaki 的 **用户体验** 搬过来，但保留 hibiki 已有的"多格式+ttu渲染"架构决策。不做一对一复刻。

---

## PR1 — 多字幕格式模糊匹配（覆盖设计差异 1）

### 动机
上游 Sasayaki 只吃 SRT，在 App 里跑"srt cue ↔ EPUB 文本"模糊匹配。hibiki 目前 SMIL/JSON 走"信任文件锚点"，SRT/LRC/VTT/ASS 走字幕→EPUB 生成（`CuesToEpub`）。两条路径并存，但**没有"拿一份纯时间戳字幕 + 一本独立 EPUB 来匹配"的入口**。本 PR 补上。

### 范围
- 新增 `EpubCueMatcher`（对 `EpubSrtMatcher` 做格式抽象）
- 输入：任意 `List<TimedCue>`（来自 SRT/LRC/VTT/ASS parser 的归一化结构）+ 一份 EPUB
- 输出：`List<MatchedCue>`（携带 `{sectionIndex, normalizedStart, normalizedEnd}`）+ 匹配率统计
- 参数化 `searchWindow`（默认 30 行，命中率过低时 UI 允许调整）
- 接入现有 `AudiobookImportDialog`：导入音频后，若选择了**外部字幕**而不是内嵌 EPUB，走此管线

### 不在本 PR 范围
- SMIL / JSON 路径不动（仍然"信任文件"）
- UI 暴露 matchRate 在 PR2
- ttu 侧高亮在 PR8

### 风险
- 四格式归一化到 `TimedCue` 时，ASS 的 override tag、LRC 的歌词元数据要剔干净，否则匹配率虚低
- EPUB 文本归一化必须和 `EpubSrtMatcher._buildIndex` 的口径完全一致（全书累计 sectionStarts），否则 PR8 的高亮会偏移

---

## PR2 — 统一对齐健康度指标（覆盖设计差异 2）

### 动机
上游有显式 **match rate + search window**；hibiki 目前成败静默，用户感知不到 8233/9805 这种天花板。直接加字段不够，必须做跨格式的统一抽象。

### 范围
- 新增 `AudiobookHealth` ValueObject：
  ```dart
  enum HealthKind { unrun, running, ok, partial, failed, notApplicable }
  class AudiobookHealth {
    final HealthKind kind;
    final int? ratePct;      // 0..100, null 表示 kind 不需要此值
    final String? reason;    // partial/failed 时的人话说明
    final DateTime measuredAt;
  }
  ```
- `Audiobook` schema 新增 nullable 字段 `matchRatePct / healthKindRaw / healthMeasuredAt / healthReason`。Isar 对新字段自动兼容，无迁移脚本。
- 各格式的 health 来源：
  | 格式 | health 来源 | 计算时机 |
  |------|------------|---------|
  | SRT/LRC/VTT/ASS（走 PR1 匹配） | `EpubCueMatcher` 返回的 `matchRate` | 导入时 |
  | SMIL | 解析时 `<text src="…#id"/>` fragment id 有效数 / 总数 | 导入时 |
  | JSON | selector 存在性的静态检查 → 首次打开后补 DOM 命中率 | 懒计算 |
  | 字幕→EPUB（CuesToEpub 生成） | N/A，标记为 `notApplicable` | - |
- UI 侧（书架角标 + 导入对话框结果页）只 `switch(kind)`，永远不直接读 `ratePct`
- 旧记录读出来 `kind=unrun`，书卡角标显示灰色 `?`，点击触发 PR1 的独立 Match Dialog。**不自动回填**（避免首次打开卡顿）

### 风险
- JSON 路径首次打开的 DOM 命中率依赖 PR8 的 ttu DOM 访问接口，在 PR8 落地前先用 selector 静态检查兜底
- `search window` 调节 UI 仅对 PR1 管线有效，其他格式 UI 应隐藏该控件（用 `kind == partial && alignmentFormat in {srt,lrc,vtt,ass}` 判断）

---

## PR6 — `{sasayaki-audio}` Anki handlebar（覆盖设计差异 6）

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

---

## PR8 — 跨章自动同步（覆盖设计差异 8）

当前天花板：ttu 剥 section id、默认停封面、无 programmatic jump。本 PR 拆两步。

### PR8a — Fork ttu 暴露 section 导航 API

#### 范围
- Fork `ttu-ebook-reader`（或在现有 `hibiki/chisa` 下维护补丁集），改动点：
  - 在渲染入口模块（book store / section loader）挂 `window.__ttuGoToSection(n: number): Promise<void>`
    - 内部调用 ttu 自己的 section 切换逻辑（Svelte store 的 setter）
    - 返回 Promise，resolve 时 `.book-content-container` 的新章节 DOM 已挂载
  - 挂 `window.__ttuCurrentSection(): number`（读当前 section index）
  - 挂 `window.__ttuSectionCount(): number`
  - **保留原始 section id**：找到 ttu 剥 id 的那段代码（估计在 section 内容写入 DOM 前有一道 sanitize），改为允许 id 透传。或者在渲染后把 `record.sections[i].reference` 补挂为 `data-ttu-section-ref` 属性
- 在 Flutter 侧 `AudiobookBridge` 注入前检测 `window.__ttuGoToSection` 是否存在，记录到健康状态

#### 产物
- Fork 的 ttu 构建产物（`dist/`）替换 hibiki 当前使用的 ttu assets
- 在 `docs/ttu-fork-notes.md` 记录 patch 清单，便于追 ttu 上游

#### 风险
- ttu Svelte store 是模块私有，暴露 API 可能需要在 store 定义处显式 `window.X = set` 或通过自定义事件桥接
- ttu 更新时需要重新打 patch。记录 patch 位置和每个 patch 的意图，遇到冲突能人工合并
- section id 透传要确认不会和 ttu 自己注入的 id（如 `__hoshi_audio_css`）冲突

---

### PR8b — 跨章同步策略

基于 PR8a 的 API。**不做 2 秒节流**。采用 A + B + E（E 已改为调用 PR8a）。

#### A. 意图标记（基础设施，必做）
在 `audiobook_bridge.dart` 注入的 JS 里：
```js
window.__sasayakiAutoNav = false;
window.__sasayakiRequestNav = async (n) => {
  window.__sasayakiAutoNav = true;
  try { await window.__ttuGoToSection(n); }
  finally { queueMicrotask(() => window.__sasayakiAutoNav = false); }
};
```
ttu 的 pageChange / sectionChange 回调在触发时读 `__sasayakiAutoNav`：
- `true` → 系统行为
- `false` → 用户行为（翻页/滚动/点击目录）

后续所有策略基于这条区分，**不依赖时间窗**。

#### B. 显式 "Follow audio" 开关（主交互）
播放栏加磁铁图标按钮，状态持久化（`Audiobook.followAudio: bool`，默认 false）：
- **OFF**：cue 正常高亮（只要当前章 DOM 已挂载），但**不会自动跳章**。跨章时播放栏顶部弹一条 "→ 第 N 章" pill，点一下手动跳
- **ON**：cue 跨章时自动调 `__sasayakiRequestNav(n)` 跳过去
- **用户手动翻页/点目录（意图标记 = false）→ 自动关回 OFF**，弹 toast "已暂停 Follow"

这条是上游 Sasayaki 没有的原创。彻底消灭竞速。

#### E（改）. 调用 PR8a 的 `__ttuGoToSection(n)`
原计划里"预跳跃"（音频还剩 10s 预跳）废弃。替代为：
- Follow 开关 ON 时，**在当前章最后一个 cue 结束后、下一章第一个 cue 开始前**调 `__sasayakiRequestNav(targetSection)`
- `__ttuGoToSection` 返回 Promise，await 完成后再播下一章第一个 cue 的高亮，**不会出现"章还没切，cue 先打 highlightMiss"**
- 跳章失败（Promise reject，ttu fork API 异常）→ 降级为 pill 提示

### 不做的备选
- ~~C 调度+取消~~：被 A+B 覆盖，不需要
- ~~D pill-only~~：作为 Follow OFF 时的默认行为保留，不单独做成 PR
- ~~F 闲置门控~~：B 已经足够，闲置检测是额外复杂度

### 风险
- PR8a 的 `__ttuGoToSection` Promise 要真 resolve 在 DOM 挂载后，否则 A+B 都瘫；要在 fork 时用 MutationObserver / Svelte `tick()` 确认
- Follow 开关被"用户手动"关掉的检测要严谨：ttu 内部的程序化 scroll（比如进入书时恢复阅读位置）不能被误判为用户意图。解决：ttu fork 时把"恢复位置"也用 `__sasayakiAutoNav = true` 包起来，或另起一个 flag `__ttuInternalNav`

---

## 实施顺序

1. **PR2**（UI/数据层，独立可合）
2. **PR1**（依赖 PR2 的 health 字段写入）
3. **PR8a**（ttu fork，与 PR1/PR2 并行）
4. **PR8b**（依赖 PR8a）
5. **PR6**（独立，可任何时候插）

PR8a 优先级可提前：它同时解决高亮 miss 率（section id 透传后不用再走全书归一化偏移），顺带降低 PR1/PR2 的测试复杂度。
