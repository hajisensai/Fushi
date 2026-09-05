## BUG-2147 · MDX 松散兄弟资源（sound.png / 图标字体）从不进 media store，发音按钮渲染成 0x0 破图

- **报告**：2026-09-05（用户：要求适配「剑桥在线2023_发音词典_音标词典」）
- **真实性**：✅ 真 bug，根因 `native/fushidicts/fushidicts_src/importer.cpp` 只有两个
  `extract_referenced_names` 调用点（`<link href=*.css>` / `<script src=*.js>`）

### 词典实测形状

`C:\Users\wrds\Downloads\QQ\剑桥在线2023_发音词典_音标词典\`：

```
hogan_came_head.mdx    7.9 MB  Encrypted="2" Format="Html" Encoding="UTF-8"  101,735 条
hogan_came_head.css    68 KB
hogan_came_head.js     1.2 KB
cdoicons.woff          15 KB
sound.png              357 B
（没有 .mdd）
```

条目 HTML（从 mdx 记录块直接解出，非推测）：

```html
<link href="hogan_came_head.css" rel="stylesheet" type="text/css" />
<div class="page-content">…<span class="hw dhw">12th man</span>…
<audio class="hdn" id="audio1" preload="none">
  <source src="https://dictionary.cambridge.org//media/english/uk_pron/c/cdo/…uk0001.mp3" type="audio/mpeg">
  <source src="https://dictionary.cambridge.org//media/english/uk_pron_ogg/…ogg" type="audio/ogg">
</audio>
<img class="i i-volume-up c_aud …" tonclick="audio1.load(); audio1.play();" src="sound.png">
<span class="pron dpron">/<span class="ipa dipa">ˌtwelfθ ˈmæn</span>/</span>
…</div><script src="hogan_came_head.js"></script>
```

样式表：`@font-face{font-family:'ico-c';font-display:swap;src:url(cdoicons.woff) format('woff')}`。

### 先排除掉的三条（都不是问题所在）

- **导入不失败**：`Encrypted="2"`（key-block-info 混淆）在 `mdx_reader.cpp:242-330` 已支持。
- **词典自带 `<script>` 会执行**：`popup.js:4190` 调 `runDictScripts` →
  `dict-media.js:315-378` 经 bridge `getDictAsset` 取源码后 `new Function` 执行
  （BUG-2063 已补）。`getDictAsset` 只放行 `.js`（`dictionary_popup_webview.dart:1754-1775`），
  而 `.js` 本来就被收集，所以这本词典的 click 监听**真的装上了**。
- **远程 mp3/ogg 能播**：popup.html / global_lookup_host.html 全文无 CSP；
  `global_lookup_host.js:13` 明写不加 sandbox；`dict-media.js:7` 的
  `/^(?:[a-z][a-z0-9+.-]*:|\/\/|#)/i` 直接放过绝对 URL 且 `rewriteDictLinks` 不匹配
  `<source>`；`dictionary_popup_webview.dart:1706` `mediaPlaybackRequiresUserGesture: false`。

### 根因

导入侧只有两个收集调用点：

```cpp
// importer.cpp:1263 / :1267（原实现）
return extract_referenced_names(entries, scan_limit, "<link",   "href", ".css");
return extract_referenced_names(entries, scan_limit, "<script", "src",  ".js");
```

`.png` / `.woff` / `.gif` 这类**被条目 `<img src>` 或样式表 `url()` 引用的松散兄弟文件，
没有任何代码路径把它们收进 media store**；`fushidicts_src` 全树 grep `url(` 零命中。
它们只有打进 `.mdd` 才进得去——而这本词典没有 .mdd。

于是弹窗把 `src="sound.png"` 重写成 `image://?dictionary=…&path=sound.png`
（`dict-media.js:5-25`），`dictionary_webview_media.dart:295-320` 调 `getMediaFile` 拿到
null → 404 → `<img>` 破图。`.i{display:inline-block}`（词典 CSS:51）没有固定宽高，
破图塌成 0 宽 → **喇叭按钮点不着**。`<audio>` 和它的远程 mp3 一直是好的，只是没有
任何东西够得着它。

作者把 `.i-volume-up:before{content:"\f028"}`（词典 CSS:89）**注释掉了**、刻意换成
`sound.png`，所以这一格没有任何回退。（56 条 `.i-*:before` 里只有这一条被注释，
其余 55 条这本词典的条目不用，故 `cdoicons.woff` 对本词典实际无影响。）

### [x] ① 已修复

`native/fushidicts/fushidicts_src/importer.cpp`：

1. `extract_referenced_names` 的 `required_ext` 允许为空 = 「任何裸文件名」
   （`<img src>` 没有值得枚举的单一扩展名）。名字仍要过 `is_plain_file_name`
   （拒绝 `/ \ :` 和 `..`）且必须真的存在于 .mdx 同级目录才会被读。
2. 新增 `extract_img_src_names`（条目 `<img src>`）与 `extract_css_url_names`
   （样式表 `url(...)`，处理可选引号、剥掉 `?query` / `#fragment`、拒绝绝对与远程）。
3. `import_mdx` 把三路合并去重后一起塞进 `ExtraMediaFile` 交给 `import_mdd_into`。
4. zip 导入路径的抽取白名单从「`.css`/`.js` 枚举」改成「除 .mdx 与非同名 .mdd 外全取，
   单文件上限 `kMaxLooseSiblingBytes` = 64 MiB」——枚举扩展名本身就是这个 bug 的形状。

### [x] ② 已加自动化测试

`native/fushidicts/tests/mdx_loose_asset_media_test.cpp`（已注册进 `tests/CMakeLists.txt`），
用真词典的条目形状（远程 `<audio><source>` + `<img src="sound.png">` + `<script>`）钉住：
`sound.png` / `cdoicons.woff` / 带 `?version=` 的 `sprite.gif` 都按裸名进 store；
`.js` 不回归；没人引用的 `never-used.png` 不被扫进来；绝对路径与远程 url() 不产生 media key。
载荷用真实 PNG/WOFF 魔数字节，顺带钉住读取是二进制安全的。

### 已知剩余缺口（不在本次范围，另案）

样式表内联进弹窗后，`url()` **在 popup 侧仍未被重写**（`dict-media.js:41-179` 的
`constructDictCss` 对 `@font-face` 逐字原样吐出），所以即使字节已进 store，相对 url()
仍相对**弹窗文档**解析（Android 是 `file:///android_asset/.../popup/`，Windows/iOS 是
`initialData` 的 opaque origin），拿不到。字体还额外卡 CORS：`CustomSchemeResponse`
（`dictionary_webview_media.dart:281-289`）带不了 header，词典自带字体要能用得接到
`kDictionaryFontUrlPrefix`（`https://fushi.local/dictfonts/`）那条能带
`Access-Control-Allow-Origin` 的通道上，且该通道只有 Android/Windows 有
（`kInAppPopupFontUrlSupported`）。对本词典无影响（它只用 sound.png），故不在本次修。
