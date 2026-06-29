# ttu-ebook-reader fork 补丁清单（PR8a）

**上游仓库**：https://github.com/ttu-ttu/ebook-reader

**fork 基准**：commit `7086bdc`（"chore(deps): update dependency vite to v5.0.9"，2023-12-15），@sveltejs/kit 1.30.3 + svelte 4.2.8，**SvelteKit 1.x 最后一个稳态**。上游随后 `0535909` 升 kit v2，输出目录结构有较大变化（chunks 结构、服务端 adapter 约定都换了）。hibiki 的 AudiobookBridge 是在 kit-v1 的 DOM 结构上反向对齐的（`.book-content` / `.book-content-container` / `column-gap: 40px` / `data-cue-id`），跟 kit-v1 dist 兼容性最强，所以 fork 锁在 kit-v1 最后一个可构建版本。

**fork 存放位置**：
- 工作副本：本机 `/d/ttu-fork/`（branch `hibiki-patches`）
- 远程：https://github.com/hajisensai/ttu-fork （`origin/hibiki-patches`）
- 上游 remote：`upstream` → https://github.com/ttu-ttu/ebook-reader

每个 patch 以 `feat(reader): [hibiki] ...` 开头便于 rebase 时辨识。

**编译产物去向**：`hibiki/hibiki/assets/ttu-ebook-reader/`（替换整套，保留 hibiki 自维护的 `fonts/` 预打包字体目录）。

---

## 1. API 契约

所有 API 挂在全局 `window`。Flutter 侧 `AudiobookBridge.probeTtuApi` / `requestSectionNav` 是唯一消费者。

| API | 签名 | 语义 |
|---|---|---|
| `window.__ttuGoToSection(n)` | `(n: number) => Promise<void>` | 跳到第 n 个 section（0-based）。resolve 时新 section 的 DOM 已挂载（paginated）或 viewport 已滚到位（continuous）。越界 reject `RangeError`，5s 超时 reject。 |
| `window.__ttuCurrentSection()` | `() => number` | 当前 section index。书未打开 / 未挂载任何章返回 `-1`。 |
| `window.__ttuSectionCount()` | `() => number` | 当前书的 spine 段数。未打开书返回 `0`。 |
| `window.__ttuGetToc()` | `() => {label, index, parent?}[]` | 扁平的 TOC，`index` 对齐 `sectionList$` 数组下标（= `__ttuGoToSection` 接受的参数）。label 缺失退回 reference。 |
| `window.__ttuBookmarkPage()` | `() => Promise<void>` | 触发 ttu 内部 `bookmarkPage()`（paginated / continuous / selection 三分支统一入口）。 |
| `window.__ttuScrollToCharOffset(s, o)` | `(s: number, o: number) => Promise<void>` | 跳到第 `s` 个 section 里从起始起算的第 `o` 个归一化字符。跨 section 先 `nextChapter$` 等 render complete 再 scroll，5s 超时。复用 `bookmarkManager.scrollToBookmark` 路径。 |
| `window.__ttuGetColumnGap()` | `() => number` | paginated 模式 `.book-content-container` 的 computed `columnGap` 像素值，continuous 模式返回 0。|

额外：`window.__ttuInternalNav` / `__ttuInternalNav` 字段暂未实现。PR8b 如果需要区分 ttu 内部程序化导航（如"恢复阅读位置"）与用户翻页，再补。

---

## 2. 当前 patch 清单

基准：`7086bdc`。

| # | Commit | 作用域 | 说明 |
|---|---|---|---|
| 1 | `0a60fd6` feat(reader): [hibiki] expose window.__ttuGoToSection / Current / Count | 整套 | 见 §3 四个文件的改动合集 |
| 2 | `d832837` fix(reader): [hibiki] onMount-cleanup instead of onDestroy to avoid SSR window | `+page.svelte` | SvelteKit prerender 会在 SSR 阶段调用 onDestroy，早期版本在 onDestroy 里 `delete window.xxx` 会抛 "window is not defined"。改为 onMount return 清理函数（onMount 只在 client 跑）规避。 |
| 3 | `9ea0a87` feat(reader): [hibiki] emit sectionChanged console event with auto flag | `+page.svelte` | 向 console 发 `sasayakiSectionChanged` 消息，带 auto 标记，供 Flutter 侧区分程序化导航 vs. 用户翻页。 |
| 4 | `09dda9e` feat(reader): [hibiki] expose window.__ttuGetToc / __ttuBookmarkPage | `+page.svelte` | TOC 列表 + 当前位置书签 的对外 API。配合 AudiobookSettingsSheet 展示章节、触发书签。 |
| 5 | `b938d32` feat(reader): [hibiki] remove native reader chrome | `+page.svelte` | 删除顶部 tap 热区 + BookReaderHeader 浮层（TOC/书签/全屏/退出 按钮）、底部进度条整块（tracker/replicate 图标 + 右下角百分比）。功能已由 Flutter 侧 AudiobookSettingsSheet 承载；删源码比外部 CSS `display:none` 更干净，让上游产出与 hibiki UI 一致，不用再在 Flutter 侧注 hide-css。顺带清理 unused imports：`BookReaderHeader` / `faClock` / `faCloudBolt` / `dummyFn` / `copyCurrentProgress` / `showFooter` 变量。 |
| 6 | `1a419d0` feat(reader): [hibiki] flip autoBookmark / avoidPageBreak defaults to true | `store.ts` | 把两条偏好的 default 从 false 翻成 true。原因：(a) autoBookmark 在 bundle 模块顶层一次性读 localStorage，Flutter 侧再 setItem 已经晚了，原先靠 DOCUMENT_START UserScript 戳；(b) avoidPageBreak 开关需要 `location.reload()` 才生效，reload 会毁掉 audiobook bridge。改 default 后 hibiki 侧的 DOCUMENT_START UserScript 和 `p{break-inside:avoid}` CSS 注入都可以删除。已有 localStorage 值的用户不受影响。 |
| 7 | `12e56d1` feat(reader): [hibiki] expose __ttuScrollToCharOffset / __ttuGetColumnGap | `+page.svelte` | 两个新 window API：`__ttuScrollToCharOffset(sectionIndex, charOffset)` 按 `(section, 章内归一化字符偏移)` 跳到该位置（paginated / continuous 都支持，跨 section 先 `nextChapter$` 等 `sectionRenderCompleteGlobal$` 再 scroll，5s 超时，rAF 对齐 layout 后 resolve）。`__ttuGetColumnGap()` 返回 paginated 模式 `.book-content-container` computed `columnGap` 数值（continuous 返回 0）。实现走 `bookmarkManager.scrollToBookmark` + `sectionList$[i].startCharacter`，复用 ttu 自己的 charCount 反推逻辑，不动 calculator。|
| 8 | `dab09ab` feat(reader): [hibiki] continuous 模式滚动同步 currentSectionIndex$ | `book-reader-continuous.svelte` + `+page.svelte` | continuous 原版只在 `nextChapter$` 订阅里更新 `currentSectionIndex$`，自然滚动 / Sasayaki reveal=true scrollIntoView 都不会动它，`__ttuCurrentSection()` 长期 stale。表现：有声书 cue 跨章判定把视口已在 11 的状态当 10，反复触发 `requestSectionNav(11)` → `__ttuGoToSection` 因 scrollBy≈0 不发 renderComplete → 5s 超时 → hibiki `_chapterTransition` 卡死，字幕/黄高亮冻住。`updateSectionProgress` 末尾按 sectionList 顺序挑第一条 `progress < 100` 的段（视口里正在读的段）同步 `currentSectionIndex$`。滚动触发的 sectionChanged 由 hibiki bridge 侧的 `__hoshiAutoScrollInFlight` flag 区分来源：Sasayaki reveal 自动对齐（`__hoshiAlignToRect` 设置 flag → `auto=true` → Follow 不关）vs 用户手动滚动/音量键翻页（flag=false → `auto=false` → Flutter 关 Follow audio，与 iOS Sasayaki 行为对齐）。|

---

## 3. 改动细节

### 3.1 `apps/web/src/lib/components/book-reader/book-toc/book-toc.ts`

新增两个全局 RxJS subject：

```ts
export const currentSectionIndex$ = new BehaviorSubject<number>(-1);
export const sectionRenderCompleteGlobal$ = new Subject<number>();
```

**为什么不用 store 里现成的**：ttu 自己的 `sectionIndex$` / `sectionRenderComplete$` 定义在 `book-reader-paginated.svelte` 的组件作用域，外部 import 不到；continuous reader 又根本没有 sectionIndex 概念。所以 `book-toc.ts`（原本就是章节相关全局状态的 home）是最合适的放置点。

### 3.2 `apps/web/src/lib/components/book-reader/book-reader-paginated/book-reader-paginated.svelte`

1. import 追加 `currentSectionIndex$`, `sectionRenderCompleteGlobal$`。
2. 在已有的 `sectionRenderComplete$.next(sectionIndex$.getValue())` 调用旁边多发一份 `sectionRenderCompleteGlobal$.next(...)`。
3. 模块 top-level 增加一次性订阅：

```ts
sectionIndex$.pipe(takeUntil(destroy$)).subscribe((i) => {
  currentSectionIndex$.next(i);
});
```

（takeUntil destroy$ 保证 reader 组件 destroy 时订阅释放，避免跨书泄漏。）

### 3.3 `apps/web/src/lib/components/book-reader/book-reader-continuous/book-reader-continuous.svelte`

1. import 追加两个全局 subject + `sectionList$` （已有）。
2. 在已有的 `nextChapter$.subscribe((chapterId) => { ... })` 开头，根据 `sectionList$` 查 `reference == chapterId` 的 index：

```ts
const list = sectionList$.getValue();
const idx = list.findIndex((s) => s.reference === chapterId);
if (idx > -1) {
  currentSectionIndex$.next(idx);
  requestAnimationFrame(() => sectionRenderCompleteGlobal$.next(idx));
}
```

rAF 是因为连续模式 `window.scrollBy` 是同步调用，但 getBoundingClientRect 之后浏览器还需要一帧才真正把新滚动位置刷到 layout；等 rAF 再发 render-complete 信号对调用方更保险。

### 3.4 `apps/web/src/routes/b/+page.svelte`

1. import 追加 `currentSectionIndex$` / `sectionRenderCompleteGlobal$`；追加 `onMount` from svelte。
2. 在已有的 `sectionList$.next(rawBookData.sections || []);` 后补一行：

```ts
currentSectionIndex$.next(-1);  // 换书复位，防止跨书残留
```

3. 在已有 `onDestroy(() => readerImageGalleryPictures$.next([]));` 之后追加 onMount，把 window API 挂上去；**return 一个清理函数**等价于 onDestroy 在 client 的那份，这样 SSR 阶段不会碰到 window（onMount 自身只在 client 跑）。

```ts
onMount(() => {
  const w = window as unknown as { ... };
  w.__ttuGoToSection = (n) => new Promise((resolve, reject) => {
    const list = sectionList$.getValue();
    if (n < 0 || n >= list.length) { reject(new RangeError(...)); return; }
    let done = false;
    const sub = sectionRenderCompleteGlobal$.pipe(take(1)).subscribe(() => {
      if (done) return; done = true;
      clearTimeout(navTimer); resolve();
    });
    const navTimer = setTimeout(() => {
      if (done) return; done = true;
      sub.unsubscribe();
      reject(new Error(`__ttuGoToSection(${n}) timed out`));
    }, 5000);
    nextChapter$.next(list[n].reference);
  });
  w.__ttuCurrentSection = () => currentSectionIndex$.getValue();
  w.__ttuSectionCount = () => sectionList$.getValue().length;
  return () => {
    delete w.__ttuGoToSection;
    delete w.__ttuCurrentSection;
    delete w.__ttuSectionCount;
  };
});
```

---

## 4. 构建 & 替换流程

前置：Node 20+（本机用 24）、pnpm（`npm install -g pnpm@8 --prefix ~/.npm-global`，然后 `export PATH=~/.npm-global:$PATH`）。

```bash
# 1. 切到 fork 分支 & 确认补丁在
cd /d/ttu-fork
git switch hibiki-patches
git log --oneline | grep '\[hibiki\]'

# 2. 装依赖（首次 ~35s）
pnpm install

# 3. build（首次前必须一次 svelte-kit sync 生成 .svelte-kit/tsconfig.json，
#    否则 husky pre-commit 的 eslint 会失败；pnpm install 的 prepare 阶段
#    会触发一次 svelte-kit sync，正常情况下无需手动。）
pnpm build

# 4. 替换 hibiki dist（保留 hibiki 自维护的 fonts/）
cd /d/APP/vs_claude_code/hibiki/hibiki/assets/ttu-ebook-reader
mv fonts /tmp/hibiki-ttu-fonts
cd /d/APP/vs_claude_code/hibiki/hibiki/assets
rm -rf ttu-ebook-reader && mkdir ttu-ebook-reader
cp -r /d/ttu-fork/apps/web/build/. ttu-ebook-reader/
mv /tmp/hibiki-ttu-fonts ttu-ebook-reader/fonts

# 5. pubspec.yaml assets 目录列表：新 build 里 _app/immutable/ 下只有
#    {assets,chunks,entry,nodes}（kit v1 的 components/ 消失），顶层多了
#    statistics/ 目录。更新完后 flutter build apk --debug 验证。
```

### 运行时验证

1. debug APK 装到设备，开一本已导入 ttu 的书。
2. 在 audiobook_bridge 注入完成后（调 `AudiobookBridge.probeTtuApi(controller)`），预期返回 `forkReady == true`、`sectionCount > 0`。
3. `AudiobookBridge.requestSectionNav(controller, sectionIndex: 1)` → console 看到 `sasayakiNavOk`，`.book-content-container` 里是第 2 段文本。
4. 立即再调 `probeTtuApi` 读 `currentSection`，应为 1。
5. 翻回第 0 章（UI 层），`probeTtuApi.currentSection` 在 paginated 模式会自动更新；continuous 模式只在用目录点跳转时更新（用户滚动不更新，当前 patch 不跟踪）。

---

## 5. 追上游策略

- 每个 hibiki patch 独立 commit + `feat/fix(reader): [hibiki] ...` 前缀（conventional commits，ttu 的 husky commit-msg 钩子要求这个格式）。
- 上游出新版：`git fetch origin && git rebase <new-tag>`。预期冲突点：
  - book-toc.ts：低风险（仅新增 export）
  - book-reader-paginated.svelte / book-reader-continuous.svelte：中风险（subscribe 块位置可能被上游重排）
  - +page.svelte：中风险（import 块、onMount 位置）
- kit 从 v1 升 v2 后，adapter-static 的 build 目录结构、`.svelte-kit/output/` 路径都变了，可能需要重新对齐 hibiki 的 pubspec assets 列表和 ttu_epub_importer 里硬编码的页面 URL。
- 冲突严重时：不强追旧 commit hash，重新走一遍 §3 的清单写新 commit。

---

## 6. Flutter 侧契约（已固定）

以下在 fork 存在前就已按本契约写好（见 `feat(audiobook): PR8a Flutter 侧 ttu API shim + fork notes` commit），fork 落地后**自动**生效：

- `hibiki/hibiki/lib/src/media/audiobook/audiobook_bridge.dart`
  - `_ttuApiShimFn`：`window.__sasayakiAutoNav` / `window.__sasayakiRequestNav(n)` / `window.__hoshiTtuProbe()`
  - `AudiobookBridge.probeTtuApi(controller) → TtuApiProbe`
  - `AudiobookBridge.requestSectionNav(controller, sectionIndex)`

PR8b 在 Flutter 侧消费这些入口（Follow audio 开关 + pill 降级），不需要再动 ttu 源码。
