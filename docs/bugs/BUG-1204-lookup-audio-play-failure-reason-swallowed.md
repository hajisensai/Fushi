## BUG-1204 · 浮窗单词发音首播失败且失败原因被吞无法定位
- **报告**：2026-07-28（用户：电脑单词音频响应巨慢，app 外；第一次慢，之后就快）
- **真实性**：✅ 真 bug（诊断盲区，非性能本身）— 根因
  `hibiki/assets/popup/popup.js` 的 `playWordAudio`（改前 L2187）：
  `return audio.play().then(() => true).catch(() => false);` —— `audio.play()` 抛出的
  DOMException 被整个丢弃，宿主只拿到一个光秃秃的 `false`。
  用户机器上的 `%TEMP%\hibiki_glookup.log` 显示一个**稳定可复现**的现象：每次 app 启动后
  的第一次播放必失败、之后全部成功（07-27 `token=1 ok=false` 后 token=2..6 全 true；
  07-28 `token=1 ok=false`）。失败后回落 Dart 播放器，这一跳正对应用户「第一次慢、之后
  就快」的体感。但 `NotAllowedError`（autoplay 策略拦截）、`NotSupportedError`（解码
  失败）、`AbortError`（被下一次播放掐断）三者修法完全不同，而日志里一个字都没有——
  无法根因修复。这与 BUG-1015「静默失败零日志导致误诊」是同一类账。
- **[x] ① 已修复**（本条修的是可诊断性，不是首播失败本身）— 失败原因一路留痕：
  `playWordAudio` 保留 boolean 返回值（`if (!await playWordAudio(url))` 与宿主的
  `r === true` 契约一字未动），原因另存 realm 上的 `__hibikiWordAudioLastError`，成功时
  清空以免读到陈旧值；`assets/popup/global_lookup_host.js` 注入的 report 读走它，作
  `wordAudioPlayed` 第三个参数回传（帧未加载 / popup.js 未装载各有独立原因串，不与
  play() 的 DOMException 混淆）；app 内 `dictionary_popup_webview.dart` 注入脚本同一契约；
  两端 Dart handler（`global_lookup_controller.dart` / `dictionary_popup_webview.dart`）
  失败时记 `reason=`，成功不记以免刷屏。Dart 侧本就按位置读且有 `length >= 2` 守卫，多带
  一个参数对旧端无害。三份 popup.js 镜像经 `hibiki/tool/sync_browser_extension.dart` 同步，
  字节一致。
- **[x] ② 已加自动化测试** — `hibiki/test/utils/misc/word_audio_failure_reason_guard_test.dart`：
  这条链路没有可跑的运行时测试面（真实 WebView2 / InAppWebView 才有 `audio.play()`），故守
  在源码层：三份 popup.js 均含 `__hibikiWordAudioLastError` 且不得回潮 `.catch(() => false)`、
  三份字节一致、host 桥与 app 内注入脚本均回传原因、两端 handler 均记 `reason=`。
  **审查中补掉两处假绿**（均经变异实测确认）：① 所有正向锚点原本扫的是**含注释的**全文，而
  讲根因的注释里就写着 `__hibikiWordAudioLastError`——把代码侧属性整体改名、契约端到端断掉，
  守卫照样绿；现统一扫 `stripLineComments` 后的源码。② 原本只查「这个名字出现过」，而
  BUG 根因是 **`play()` 的 rejection 分支**丢了 DOMException——删掉那一句赋值，名字仍在
  `EmptyUrl` 分支和成功清空处，守卫照样绿；现用括号配平精确截出 rejection 回调体再断言
  （用「其后 N 字符」的窗口会把外层 `} catch (e) { noteError(e); }` 圈进来，仍是假绿，
  第一版加固就这么漏过一次）。`reason=` 那两条也从裸 `contains` 收紧到锚在
  `wordAudioPlayed` 附近的窗口内（大文件里任何别处的 `reason=` 都能满足裸写法）。
- **备注**：**尚未定案的部分**——已实测排除本地音频库（6.27GB 库随机词冷读 0.3ms、取字节
  0.5ms）、Dart 解析（浮窗日志 41 次成对打点 p50 3ms / max 46ms）、桥往返（同桥 1445 次
  p50 9ms / p99 295ms）、远端音源（用户配置里全部禁用）、AnkiConnect（13-33ms）；回落路径
  也在 `main.dart:206` 启动时预热过。也就是说各段都是毫秒级，**尚未测到与「巨慢」量级相符
  的证据**，真正耗时点还在没有打点的环节里。首播失败样本也只有 2 次。本条落地后，用户复现
  一次即可从日志读到确切的 DOMException 名字，再据此开新条目做根因修复。
