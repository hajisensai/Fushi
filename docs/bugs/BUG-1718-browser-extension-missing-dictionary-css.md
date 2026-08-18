## BUG-1718 · 浏览器扩展查词拿不到词典自带 CSS 与词典内嵌图片，mdx 词典在插件里样式全失效
- **报告**：2026-08-18（用户：截图对比同一本 OALDPE En-Cn mdx 词典——视频内查词有 CEFR 徽标 / OPAL 标签 /
  彩色音标 / 义项缩进，浏览器插件里全是裸文本竖排；日语侧「明鏡国語辞典」的词条插图还是裂图）
- **真实性**：✅ 真 bug。两条独立根因，症状都落在「插件里词典渲染坏了」上。

  **根因①：弹窗「CSS 尾段」这条通道在扩展侧根本不存在。**
  三镜像（app 内弹窗 / gal 全局浮窗 / 浏览器扩展）跑的是**同一份** `fushi/assets/popup/popup.js`
  （`tools/browser-extension/vendor/popup.js` 与它字节一致，守卫见
  `fushi/test/build/browser_extension_popup_parity_guard_test.dart`）。它渲染词典自带样式的唯一输入是
  三个全局：`fushi/assets/popup/popup.js:3322`（`window.dictionaryStyles?.[dictName]` →
  `constructDictCss` → 内联 `<style>` 塞进 `[data-dictionary=...]` 容器）和
  `fushi/assets/popup/popup.js:3607` `applyCustomCSS()`（`window.globalDictCSS` / `window.customDictCSS`）。
  - app 内由 Dart 注入：`fushi/lib/src/pages/implementations/popup_settings_injection.dart:741-743`
    （tail 段一次性写下这三个全局），数据源
    `packages/fushi_dictionary/lib/src/engine/fushidicts.dart:414` `FushiDicts.dictionaryStyles`
    （mdx 导入时兄弟 `.css` 被落成词典目录下的 `styles.css`，见
    `native/fushidicts/fushidicts_src/importer.cpp:1012` `read_sibling_css` /
    `:1439` `write_simple_dict`，查询侧 `native/fushidicts/fushidicts_src/query.cpp:145` 读回）。
  - 扩展侧**从来没人赋值**：`/api/lookup/dictionary` 的响应体只带 `theme` / `audioSources` /
    `extensionBuild`（`fushi/lib/src/sync/fushi_remote_api_handlers.dart:100-111`，修复前），
    `tools/browser-extension/content.js` 全文搜不到 `dictionaryStyles`。于是
    `window.dictionaryStyles` 恒 `undefined` → `dictStyle` 恒 `''` → mdx 词典自带样式在插件里 100% 失效。

  **根因②：TODO-1215 为了不泄漏 token 把词条内 `<img src>` 降级成占位属性，却从没有人兑现占位。**
  `tools/browser-extension/vendor/dict-media.js:36-45`（修复前）在扩展环境下把
  `<img src=...>` 改写成 `data-fushi-media-dict` / `data-fushi-media-path` 并**删掉 src**，
  计划由「popup.js 在 innerHTML 之后 fetch→blob 补 src」兑现——但全仓搜索
  `data-fushi-media` / `mediaPath` / `createObjectURL`，除这一处生产端外**零消费端**。
  结果：所有 mdx 词典（走 `rewriteDictLinks` 的原始 HTML 词条）里的图片在扩展里恒为裂图。
  同一函数里 `<link rel=stylesheet>` 被改写成 `dictmedia://`，真实浏览器同样没有这个 scheme
  handler，也是死链。

- **[x] ① 已修复** — 提交 `9aa27d3615`
  - 服务端契约（单一真相源，两个 server 共享）：`fushi/lib/src/sync/fushi_remote_api_handlers.dart`
    新增 `RemotePopupDictionaryCss`（`dictionaryStyles` + `globalDictCss` + `customDictCss` + 内容指纹
    `revision`），`buildRemoteDictionaryLookupResponse` 把三件套按 **revision 门控** 放进响应：
    请求体没有 `stylesRevision` 键 ⇒ 老客户端，一个字节都不发（向后兼容）；键在且指纹不一致 ⇒
    全量下发一次；一致 ⇒ 只回指纹。**必须门控**：实测本机词典库 `styles.css` 合计 285 KB
    （单本 OALDPE 就 210 KB），而查词是 hover 级高频请求（BUG-871 / BUG-1525 已为同样理由收窄过响应体）。
  - 供给器接线：`fushi/lib/src/models/app_model.dart` `browserExtensionPopupDictionaryCss()`
    （按数据源身份/内容缓存实例，指纹不在查词热路径上重复哈希）→ `yomitan_api_server_manager.dart`
    → `yomitan_api_server.dart` → 共享 handler。
  - 扩展侧：`tools/browser-extension/background.js` 新增 `fushiPopupCss` 缓存 + `fushiMergePopupCss()`，
    请求带 `stylesRevision`，响应回填**完整**尾段；`vendor/dict-media.js` 新增
    `applyFushiPopupCss()`；`content.js`（首次查词 + 嵌套查词两条渲染路径）与 `side-panel.js`
    落到 popup.js 读的全局上。
  - 根因②：`vendor/dict-media.js` 新增 `resolveDictMediaPlaceholders()` /
    `installDictMediaPlaceholderResolver()`（弹窗 shadow root 上挂 MutationObserver，
    懒展开/嵌套查词新插入的占位一并兑现）：`<img>` → fetch→`blob:` URL（token 只在 fetch 参数里，
    不进宿主页 DOM），`<link>` → fetch→内联 `<style>`；`<link>` 在扩展环境下也改发同款占位，
    不再产生 `dictmedia://` 死链。app 内路径（`window.__fushiDictMedia` 未设）逐条保持原样。
  - 镜像：`node tools/browser-extension/scripts/sync-mirrors.mjs` 同步到
    `fushi/assets/browser_extension/`；`popup.css` 未改，`vendor/content.css` 生成物无变化
    （`generate-content-css.mjs --check` 通过）。

- **[x] ② 已加自动化测试** — 提交 `9aa27d3615`
  - `fushi/test/sync/remote_lookup_dictionary_css_test.dart`：契约行为（未注入供给器 / 无
    `stylesRevision` 键 / 指纹不一致 / 指纹一致 / popupOnly 快路径 / 指纹随内容变）+ 三镜像接线
    源码扫描守卫（app_model→manager→server 与两个扩展镜像的 background/content/side-panel/dict-media）。
    守卫做过变异实测：删掉 `content.js` 首次查词那处调用、删掉 `background.js` 的
    `stylesRevision` 上报，均能让守卫变红（首版守卫用 `contains` 时**没有**红——被嵌套查词那处
    同形调用顶着，故改成数够 2 次）。
  - `tools/browser-extension/dict-media.test.js`：`applyFushiPopupCss` 落地与缺字段归零、
    `<link>` 在扩展/app 两侧的分流、`<img>`/`<link>` 占位兑现（含 token 不进 DOM、占位属性只解析一次、
    未配置 server 时不动手）。CI 走 `.github/workflows/main.yml` 的 `node --test *.test.js`。

- **备注**：
  - 未做真浏览器装扩展的端到端复测（需要真实 Chrome + 已导入 mdx 词典 + 运行中的 app）。
    已验证到「契约 + 三镜像接线 + JS 行为」层；浏览器端仍是缺口。
  - 图片兑现走 `blob:` URL，宿主页若设了极严的 `img-src` CSP 仍可能被拦——这是「不把 token 写进
    宿主页 DOM」的既定取舍（TODO-1215），比修复前 100% 裂图严格更好，不再回退。
