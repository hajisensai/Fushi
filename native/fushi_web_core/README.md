# fushi_web_core

app 内**网页内容**的计算核心（Rust），给 Dart FFI（`packages/fushi_web_core`，纯 Dart，无 Flutter /
插件依赖）用：

| 模块 | 作用 | Dart 入口 | 接线 |
|---|---|---|---|
| `src/adblock/` | 网页广告 / 跟踪拦截（Brave adblock-rust） | `AdblockCore` | `fushi/lib/src/web_adblock/` |
| `src/comic_ad/` | 网页漫画章末广告页识别（彩色 + 二维码定位图形） | `ComicAdDetector` | `fushi/lib/src/media/manga/web/web_comic_runtime_adapter.dart` |
| `src/article/` | 网页小说正文提取（站点规则表 + readability + 密度兜底）与连载会话 | `WebNovelSession` / `WebArticleExtractor` | `fushi/lib/src/media/novel/web/` |

## 设计：胖核心

用户 2026-10-19 拍板的规则，本 crate 是第一个按它落地的子系统：

- **Rust 持有状态与业务逻辑并落盘**，对外只给少量粗粒度命令 + 状态快照；Dart 只渲染快照，不另存镜像状态。
- **FFI 边界要粗**：不在循环里逐元素跨 FFI；大块数据（列表原文、图片）以字节指针传，不来回编码成字符串；
  慢调用（引擎编译、整批图片判定）放后台 isolate。
- UI、平台插件、WebView 桥、i18n、**联网**留在 Dart（联网必须走 app 的 `createAppHttpClient` 全局代理）。
- 原生库是**硬依赖**：Dart 侧没有「缺库判不可用」的分支，缺库抛 `FushiWebCoreLibraryMissing`；
  Profile / Release 打包缺库直接构建失败；测试找不到库就失败，不 skip。

### 广告拦截（`AdblockCore`）

状态（数据目录由 Dart 传入）：`state.json`（总开关、订阅集、白名单原文、每份列表的 ETag /
Last-Modified / 上次成功核对 / 上次尝试 / 规则行数 / 内容哈希 / 上次结果与错误）、
`lists/<id>.txt`（列表原始字节）、`engine/<key>.dat`（序列化引擎）、`engine/<key>.cb.json`（WebKit
规则，只在 iOS / macOS 生成）。`key` = 库版本 + 每份在用列表的 id / 长度 / 内容哈希。过期 4 天。

同步流程：`begin_sync(force)` 给出要联网取的清单（带条件请求头）→ Dart 用全局代理取回**原始字节** →
逐份 `ingest(id, status, body, etag, last_modified, error)`（304 续期、200 校验不是 HTML 后落盘、
失败按有无缓存记 staleCache / missing）→ `finish_sync()`（后台 isolate；键没变什么也不做，有序列化缓存就
反序列化，否则编译并落盘、清旧件）。每个改状态的命令都返回新快照。

| C ABI | 作用 |
|---|---|
| `fwc_adblock_open(dir, len, want_content_blocking) -> core*` / `fwc_adblock_close` | 打开 / 关闭（open 只读 `state.json`，很快） |
| `fwc_adblock_catalog(&len)` | 内置列表目录 JSON（不需要句柄） |
| `fwc_adblock_snapshot` / `set_enabled` / `set_list_enabled` / `set_allowlist` | 快照 / 设置命令，都返回快照 JSON |
| `fwc_adblock_begin_sync(core, force, &len)` | 取数清单 `{"run","fetch":[{"id","url","etag","lastModified"}]}` |
| `fwc_adblock_ingest(core, id, status, body, …)` | 交回一份列表的原始字节与响应头 |
| `fwc_adblock_finish_sync(core, &len)` | 收尾（可能编译，慢），返回快照 |
| `fwc_adblock_check(core, url, source, page, type) -> i32` | 热路径（Dart 侧 leaf 调用）：`0` 放行 / `1` 拦截 / `3` 例外放行 / `-1` 参数错；开关、白名单（按 `page` 主机名）、引擎就绪都在这里判 |
| `fwc_adblock_cosmetic(core, href, page, &len)` | 页面 cosmetic 载荷：**直接是交给页内 JS 的 JSON 文本**（Dart 不解码、不重组） |
| `fwc_adblock_generic(core, href, page, classes, ids, &len)` | 通用 hide 选择器 JSON 数组；`classes` / `ids` 是页内 JS 换行拼好的整批原文；该页的例外集在 Rust 里缓存 |
| `fwc_adblock_content_blockers(core, &len)` | WebKit 内容拦截规则 JSON（Rust 已筛选：只留 block / ignore-previous-rules、丢插件不认识的 resource-type、`if-*`/`unless-*` 互斥、5 万条上限只截拦截规则） |

快照 JSON：`{"version","enabled","allowlist","allowlistHosts","status":"idle|loading|ready|failed","error",
"syncing","ruleCount","fromCache","builtAt","lastUpdatedAt","lastSyncOk","lists":[{"id","title","url","host",
"enabled","cached","stale","fetchedAt","checkedAt","byteLength","ruleCount","lastResult","lastError"}]}`。

### 章末广告页识别（`ComicAdDetector`）

| C ABI | 作用 |
|---|---|
| `fwc_comic_ad_default_rules() -> FwcComicAdRules` | 默认规则（最后 10 张、前 3 张永不判、彩色占比 0.12、长边缩到 900） |
| `fwc_comic_ad_candidate_start(page_count, rules*) -> u32` | 要判定的页序区间 `[start, page_count)` |
| `fwc_comic_ad_detect_batch(rules*, images**, lens*, count, out*) -> i32` | 一章末尾整批一次判完（Rust 内部最多 4 线程），`out[i]`：0 正文 / 1 广告 / 2 解码失败（按正文保留） |

判据逐行移植自已删除的 Dart 实现（含 package:image 4.3.0 `copyResize` 的 average 缩放与 Dart 不稳定
排序），回归向量在 `tests/vectors/comic_ad/`（36 张输入 + 旧 Dart 输出，`cargo test` 与
`packages/fushi_web_core` 的 Dart 测试都跑）。唯一刻意偏差（两条向量）写在 `expected.json` 的 `note` 里：
8 位灰度 PNG 在 Dart 里被当成彩色（package:image 读出 g = b = 0），Rust 按灰度处理。图像解码用
`image` crate（MIT OR Apache-2.0；只开 png / jpeg / webp / gif / bmp），截断的 JPEG（无 EOI）按
解码失败处理，与 Dart 一致。

### 网页小说正文提取与连载会话（`WebNovelSession`）

一次调用交进**整页 HTML 原始字节** + 页面 URL（编码在 Rust 里嗅探：BOM → 整段合法 UTF-8 → `<meta charset>`
→ Shift_JIS / GB18030 里挑错误少的），出：章节标题、作品名 / 作者、清洗后的正文 XHTML 片段、上一章 / 下一章 /
目录链接、语言提示、正文指纹。

取正文：**站点规则**（`src/article/sites.rs` 的数据表，选择器命中且有字就用）→ 否则 **readability**
（dom_smoothie）与**文本密度兜底**都跑、取字数多的（readability 不到密度结果 60% 时用密度）。清洗只留段落、
空行（作者的 `<p><br></p>` 与三个以上连续 `<br>`）、`h2`–`h6`、ruby 注音（`ruby/rb/rt/rp/rtc`）、强调类行内
标签与图片；`<br>` 分隔的纯文本切成段落；只折叠 ASCII 空白（全角空格缩进原样保留）；通用模式额外按 class / id
关键词与「最新域名 / 加入书签…」垃圾行表剔除。图片 `src` 写成占位 `fushi-web-image:<i>`，绝对 URL 在 `images`
里——取图（联网、cookie、全局代理）在 Dart。上下章：规则选择器 → `rel=next/prev` → id / class → 锚文字
（下一章 / 次へ / 次の話 / Next…）→ 页面里**真实存在**的「末尾数字 ±1」链接；指回目录的「下一章」丢掉。

站点规则（真实页面快照在 `tests/vectors/article/inputs/`）：

| 规则 | 站点 | 作品身份 | 验证 |
|---|---|---|---|
| `syosetu` | 小説家になろう（ncode / novel18） | 路径第 1 段 | 真实页面快照（含 ruby） |
| `kakuyomu` | カクヨム | `/works/<id>` | 真实页面快照 |
| `jjwxc` | 晋江文学城 | `novelid` 参数 | 真实页面快照（GB18030 原编码） |
| `hameln` | ハーメルン（syosetu.org） | `/novel/<id>` | **只有合成快照**：站点对非浏览器请求给 Cloudflare 质询页，本机抓不到真实页面；选择器不中时通用算法兜底 |

通用算法另有合成的中文盗版站页面与「真实页面换到规则表外的主机」三条用例。

连载会话状态（快照 JSON，Dart 原样存进书行 `sourceMetadata`，几 KB）：`{"type":"fushi_web_novel","version":1,
"workKey","siteRule","workTitle","author","lang","toc","chapters":[{"url","title","next","prev","chars","hash"}],
"queue":[…],"tailNext"}`。第一章定下 `workKey`，别的作品的页拒收（`otherWork`）；规范 URL（https、去 `www.`、
去片段与末尾斜杠）或正文指纹相同 → 原地更新（`updated`，典型是「上次的末章现在有下一章了」）；新章按章节之间
声明的 next / prev 插到对的位置；`tailNext` = 末章的下一章（追更取它）。

| C ABI | 作用 |
|---|---|
| `fwc_article_extract(html, len, url, len, &len)` | 无状态提取一页（预览 / 测量）；慢调用，后台 isolate |
| `fwc_article_work_key(url, len, &len)` | 只从 URL 推作品身份键（Dart 找书架上已有的同一部作品） |
| `fwc_novel_session_open(snapshot, len) -> session*` / `fwc_novel_session_close` | 开会话（空 = 新；快照坏了 NULL）/ 关闭 |
| `fwc_novel_session_ingest(session, html, len, url, len, &len)` | 喂一页：提取 + 并进会话；慢调用，后台 isolate |
| `fwc_novel_session_snapshot(session, &len)` | 快照 JSON |

提取结果是帧 `[u32 LE 头长度][JSON 头][正文 XHTML 的 UTF-8]`：正文不进 JSON（不转义、不来回编码）。

## 端到端耗时（Windows x64，AOT Dart + release DLL，2026-10-19）

均含 Dart 侧编码 / 拷贝、FFI 与 isolate 开销；广告拦截用真实四份默认列表（~5.1 MB 文本、17.3 万条规则）。

| 场景 | 旧（薄 C ABI + Dart 状态 / 纯 Dart） | 新（胖核心） |
|---|---|---|
| 漫画章末 10 张广告判定 | 1384 ms（每张一次 `Isolate.run` 跑 Dart 解码 + 扫描） | 31 ms（一次批量调用）；逐张 10 次 86 ms |
| 逐请求 `check` | 4.48 µs（3 次 `toNativeUtf8` + free） | 3.68 µs（常驻原生暂存区 + leaf 调用） |
| cosmetic（每页） | 593 µs（JSON → Dart 对象 → 重组 → 插件 jsonEncode） | 416 µs（Rust JSON 文本原样交 JS） |
| generic（250 个 class/id） | 41 µs | 19 µs |
| 编译引擎（后台 isolate） | 108 ms | 102 ms（含落盘） |
| 冷启动从缓存恢复引擎 | 29 ms（UI isolate 上反序列化） | 27 ms（后台 isolate） |

网页小说正文提取（没有旧实现可比）：~198 KB 的典型小说页（真实快照段落重复拼接，1480 段、3.3 万字）。

| 场景 | Rust 内（`cargo test --release`） | Dart 端到端（AOT，含开会话 + 整页拷进原生内存 + 后台 isolate + FFI + 帧拷回 + 解码 + 取快照） |
|---|---|---|
| 站点规则命中（なろう） | 10.2 ms | 12.1 ms |
| 通用算法（readability + 密度兜底都跑） | 30.6 ms | 35.4 ms |

## 上游与许可

| 项 | 值 |
|---|---|
| 上游 crate | `adblock` **0.13.3**（MPL-2.0）、`image` 0.25（MIT OR Apache-2.0）、`dom_query` 0.28 / `dom_smoothie` 0.18（MIT；readability.js 的 Rust 移植，本仓未改源码）、`encoding_rs` 0.8 / `url` 2（MIT OR Apache-2.0） |
| 本 crate 许可 | MPL-2.0（与 adblock-rust 一致） |
| adblock 特性 | `embedded-domain-resolver`、`full-regex-handling`、`content-blocking`；**关掉**默认的 `single-thread`（引擎因此是 `Send + Sync`） |

MIT / Apache-2.0 与 GPL-3.0 兼容（GPL 作品可以包含它们，只需保留版权与许可声明）。
MPL-2.0 是文件级 copyleft：链接进本体（GPL-3.0）作为「更大作品」分发是许可明文允许的（MPL-2.0 §3.3）。
本仓**没有改**上游源码。iOS 伞形库 `native/fushi_ios_umbrella`（GPL-3.0-only）把它与 fushi_p2p /
fushi_fsrs 合成一个归档，同理。

`adblock` 钉成 `=0.13.3`：序列化格式**不保证跨 minor 兼容**。升级时同步 bump 本 crate 的 `version`——
引擎缓存键含 `fwc_version()`，旧缓存会自动作废重编。

过滤列表（EasyList / EasyPrivacy / AdGuard 中文 / 日文）**不随包分发**，运行时从官方地址下载。

## C ABI 通用约定

前缀 `fwc_`；每个导出函数 `catch_unwind`（`panic = "unwind"`），永不 panic 过 FFI；字符串入参是
`(ptr, len)` 的 UTF-8；返回的字节缓冲用 `fwc_bytes_free(ptr, len)` 释放；失败原因 `fwc_last_error()`
（线程局部，`fwc_string_free` 释放）；`fwc_version()` 是静态串。

## 构建

| 平台 | 命令 | 产物 | 怎么进包 |
|---|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_web_core/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_web_core.dll` | `fushi/windows/CMakeLists.txt` 装到 exe 同级；Profile/Release 缺库构建失败 |
| Android | `build_android_so.ps1 [-NdkRoot …] [-Abis …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24） | `prebuilt/android/<abi>/libfushi_web_core.so` | `build.gradle` 的 `jniLibs.srcDirs`；release 构建按 target-platform 逐 ABI 核对，缺库失败 |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_web_core.so` | `fushi/linux/CMakeLists.txt` 装到 `bundle/lib/`；Profile/Release 缺库失败；CI 单测经 `FUSHI_WEB_CORE_LIB` 加载 |
| macOS | `build_macos_dylib.sh`（只出 arm64） | `prebuilt/macos/libfushi_web_core.dylib` | Runner 构建阶段「Bundle fushi_web_core dylib」拷进 `Contents/Frameworks`；Release/Profile 缺库失败 |
| iOS | **并入伞形库** `native/fushi_ios_umbrella/build_ios_staticlib.sh` | `libfushi_ios_umbrella.a` | Runner `-force_load`，Dart 侧 `DynamicLibrary.process()`；出包后核对 `fwc_*` 符号 |

- 测试：`cargo test --release`（含回归向量）；Dart 包 `packages/fushi_web_core` 与 `fushi/` 的单测经
  `package:fushi_web_core/testing.dart` 找本目录 `target/release/` 或 `prebuilt/<平台>/` 的库（或
  `FUSHI_WEB_CORE_LIB`），找不到就失败。CI 的单测 job 先编 Linux `.so`。
- `verify_abi.sh <二进制> [nm]`：按 Dart 绑定里 lookup 的 `fwc_*` 名逐个核对导出表（ELF / Mach-O）。
  期望集取自绑定文件里**单引号包住的** `fwc_` 名字面量，注释里别那样写。

`target/`、`prebuilt/` 不入库。访问 crates.io 不稳时设 `CARGO_HTTP_PROXY` / `HTTPS_PROXY`。
