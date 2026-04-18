# ttu-ebook-reader fork 补丁清单（PR8a）

对应上游：https://github.com/ttu-ebook-reader/ttu-ebook-reader

当前 hibiki 把 ttu 的 dist 直接塞在 `hibiki/hibiki/assets/ttu-ebook-reader/`，**没有源码**。PR8b 的跨章自动同步需要 ttu 暴露 section 导航 API，本文档记录：
1. 需要挂在 `window` 上的新 API 契约（Flutter 侧已按该契约注入 shim）
2. 需要改的 ttu 源码位置与思路
3. 编译 → 替换 dist 的流程
4. 后续追上游的策略

Flutter 侧在 fork 未落地时已经能安全运行：`AudiobookBridge.probeTtuApi` 探不到 API 会返回 `forkReady=false`，`__sasayakiRequestNav(n)` 会打 `ttuForkMissing` 日志并 resolve，上层自动降级为 pill 提示（见 `SASAYAKI_PARITY_PLAN.md` 的 PR8b）。

---

## 1. API 契约

**所有 API 必须挂在全局 `window` 对象上**。Flutter 侧通过 `evaluateJavascript` 调用它们，不走 Svelte store。

### 1.1 `window.__ttuGoToSection(n: number): Promise<void>`

- **语义**：跳转到 spine 中第 `n` 个 section，`n` 为 0-based。
- **Promise resolve 条件**：目标 section 的 DOM 已挂载进 `.book-content-container`，Flutter 侧的 `MutationObserver` 能立刻看到新文本节点。**不允许**早于 DOM 挂载 resolve（否则 PR8b 的 cue 高亮会打空）。
- **实现思路**：调用 ttu 内部切换 section 的 Svelte store setter；setter 派发异步渲染，在下一 `tick()` 之后 DOM 挂载完成即可 resolve。若无法精确挂钩 tick，可在模块内部 mount MutationObserver 监听 `.book-content-container`，第一次 mutation 即视为挂载完成。
- **reject**：越界（`n < 0` 或 `n >= sectionCount`）应 reject 一个 `RangeError`。其他内部错误原样抛。

### 1.2 `window.__ttuCurrentSection(): number`

- 返回当前展示的 section 的 0-based 索引。未挂载任何 section（封面）时返回 `-1`。
- 必须是同步读取（直接读 Svelte store 的 current value），供 `__sasayakiRequestNav` 做幂等判断。

### 1.3 `window.__ttuSectionCount(): number`

- 当前书的 spine 总段数。书未打开时返回 `0`。

### 1.4 `window.__ttuInternalNav: boolean`（可选，推荐）

- ttu 自身做的"恢复阅读位置"这种程序化 scroll 会派发 sectionChange 回调；PR8b 用 `__sasayakiAutoNav` 区分用户 / 系统意图，但那个 flag 只在 `__sasayakiRequestNav` 调用期间为 true。ttu 内部的程序化导航要另起一个 flag，否则会被误判为"用户翻页"→ Follow audio 被自动关掉。
- 如果 fork 时方便，给 ttu 内部所有"非用户触发"的 section 切换包上 `window.__ttuInternalNav = true; try { ... } finally { __ttuInternalNav = false; }`。
- Flutter 侧（PR8b）读 `__ttuInternalNav || __sasayakiAutoNav` 合并判断。

### 1.5 保留 / 透传 section id（可选，强推）

- ttu 当前在渲染时会剥掉 section 原始 id（实测只剩一个 `.book-content-container`）。当前 hibiki 依赖 `__hoshiSasayakiSectionStarts`（整书归一化偏移表）反推位置，既贵又脆。
- 理想做法：找到 ttu 把 section HTML 写进 DOM 前的 sanitize 点，要么允许 id 透传，要么在 section root 元素上挂 `data-ttu-section-ref="<reference>"`。
- 挂上之后 `audiobook_bridge.dart` 可以切一条 "按 section root 定位" 的捷径，省掉整书偏移扫描；但这不阻塞 PR8b。标记为 **可选**。

---

## 2. 需要改的 ttu 源码位置（估计，fork 后确认）

**警告：下面都是"按 ttu 项目结构规律推断"的位置，fork 后需要用 ripgrep 实地核对。**

1. **Section loader / book store**
   - 期望位置：`apps/web/src/lib/data/book/...` 或 `apps/web/src/lib/components/book-reader/...`
   - 找 "switch section" / "setSection" 逻辑；Svelte store 的 setter 在这里暴露。
   - 新增一个 top-level 模块导出：
     ```ts
     // apps/web/src/lib/ttu-fork-bridge.ts（新建）
     import { currentSection, sectionCount } from './book-store'; // 实际路径随 fork 确认
     import { tick } from 'svelte';

     if (typeof window !== 'undefined') {
       (window as any).__ttuGoToSection = async (n: number): Promise<void> => {
         const total = get(sectionCount);
         if (n < 0 || n >= total) throw new RangeError(`section ${n} / ${total}`);
         (window as any).__ttuInternalNav = true;
         try {
           currentSection.set(n);
           await tick();
           // 加一层 MutationObserver 兜底，等 DOM 真的挂上
           await waitForContainer();
         } finally {
           (window as any).__ttuInternalNav = false;
         }
       };
       (window as any).__ttuCurrentSection = () => get(currentSection);
       (window as any).__ttuSectionCount = () => get(sectionCount);
     }
     ```
   - 在 reader 页面入口（`+page.svelte` / `+layout.svelte`）`import '$lib/ttu-fork-bridge'` 触发副作用。

2. **Section id 透传（可选）**
   - 估计在 "sanitizeHtml" / "sectionProcessor" 类文件；ripgrep `stripId` / `removeId` / `id=` 找剥 id 的地方。
   - 要么去掉这段剥 id 的逻辑，要么在写入 DOM 前把 `record.sections[i].reference` 作为 `data-ttu-section-ref` 挂到 section 根元素。

3. **恢复阅读位置的程序化 scroll**
   - ttu 打开书时会恢复上次位置；找这段代码，把它包在 `window.__ttuInternalNav = true; ... finally { false }` 里。

---

## 3. 编译 & 替换流程

前置：Node 20+, pnpm（ttu 项目常用），git。

```bash
# 1. Fork 并克隆
git clone https://github.com/<your-fork>/ttu-ebook-reader.git
cd ttu-ebook-reader
# 基于某个具体 tag 建 fork 分支，便于追上游
git checkout -b hibiki-patches <upstream-tag>

# 2. 装依赖 & 确认能跑
pnpm install
pnpm -C apps/web dev

# 3. 应用 hibiki patches（见 §2 位置清单），每个 patch 一个 commit
#    推荐 commit message 前缀 `[hibiki]`，便于 rebase 时辨认

# 4. 构建生产 dist
pnpm -C apps/web build

# 5. 替换 hibiki 的 assets
rm -rf <hibiki>/hibiki/hibiki/assets/ttu-ebook-reader/*
cp -r apps/web/build/* <hibiki>/hibiki/hibiki/assets/ttu-ebook-reader/
```

### 验证步骤（必做）

构建产物替换后，不能盲信编译通过就等于 API 可用。验证：

1. hibiki 里跑 debug APK，打开任意 ttu 书。
2. 在 Flutter 侧调用 `AudiobookBridge.probeTtuApi(controller)`，预期返回 `forkReady == true`、`sectionCount > 0`。
3. 调用 `AudiobookBridge.requestSectionNav(controller, sectionIndex: 1)`，console 看到 `sasayakiNavOk`；book-content-container 里是第 2 段的文本。
4. Flutter 侧立刻调 `probeTtuApi` 再读 `currentSection`，应为 1。

---

## 4. 追上游策略

- 每个 hibiki patch 独立 commit + `[hibiki]` 前缀。
- ttu 上游出新版 → `git rebase <new-tag>`，手工合并冲突。section loader 这种核心文件最可能冲突，`ttu-fork-bridge.ts` 是新增文件基本不会冲突，值得在结构上尽量把逻辑推进新文件、最小侵入已有文件。
- 冲突多到无法 rebase 时：在新上游上重新走一遍 §2 的 patch 清单，写新 commit，不强追之前的 commit hash。
- 本文档跟 fork 走——fork commit 对应的 patch 编号、位置改动要回填到此文件"当前 patch 清单"小节（现阶段还没落，空着）。

---

## 5. 当前 patch 清单

> fork 尚未创建。落地后在此记录每个 patch 的：commit hash / 改动文件 / 对应本文 §2 编号 / 验证结果。

（空）

---

## 6. Flutter 侧契约（不需要改）

以下代码在 fork 未落地时就已经按本契约写好，fork 落地后**自动**生效，不需要再动 Flutter：

- `hibiki/hibiki/lib/src/media/audiobook/audiobook_bridge.dart`
  - `_ttuApiShimFn`：定义 `window.__sasayakiAutoNav` / `window.__sasayakiRequestNav(n)` / `window.__hoshiTtuProbe()`。
  - `AudiobookBridge.probeTtuApi(controller) → TtuApiProbe`：探针封装。
  - `AudiobookBridge.requestSectionNav(controller, sectionIndex)`：上层统一入口，fork 未落地打 `ttuForkMissing` 日志后降级。

fork 落地后建议：在 `AudiobookBridge.inject()` 完成后调一次 `probeTtuApi`，把 `describe()` 写进 `AudiobookHealth.reason`（目前只在导入时写一次；fork 落地后这里再补一轮"打开书时复测"）。
