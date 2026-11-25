## BUG-5463 · music-plugin-switch-cover-pixi-slow
- **报告**：2026-11-26（用户：网易云插件切歌慢，加载封面和 Pixi 渲染慢）
- **真实性**：✅ 真 bug，三处根因（沿代码路径验证）：
  1. **手动切歌把预取好的流扔掉重取**：插件曲目在播放期间已由 `_attachNext` 取好下一首的流并排进 mpv（`fushi/lib/src/media/music/mpv_music_output_backend.dart` `_attachNext`），但「下一首」走引擎 `skipNext` → `openPair(下一首)` → `_open`，`_open` 不认这份现成源，先停掉旧曲再 `_mediaFor` 从头取流：插件 `invoke('stream')`（每个插件 http 一次后台 isolate 往返）+ `resolveMediaStream` 对音频 CDN 的 DNS + TCP/TLS + `Range: bytes=0-0` 探测（`packages/fushi_music/lib/src/plugin/plugin_net_guard.dart` `probeRedirect`），全部串行，期间无声。
  2. **在线封面没有字节缓存**：音乐封面统一用 `AppHttpImage`（`fushi/lib/src/media/music/lyrics/visualizer/lyric_visualizer_cover.dart`、`fushi/lib/src/pages/implementations/music/music_cover.dart` 两处），每次新建 client 下载原图、只进内存 ImageCache；播放条 / 列表（按显示尺寸 `ResizeImage`）、歌词背景（160px）、取色各自的 `ResizeImage` 宽度不同 = 缓存 key 不同，同一张封面各下载一遍，切回听过的歌也重下。
  3. **Pixi 背景**（`fushi/lib/src/pages/implementations/music/music_lyrics_backdrop.dart`）：每首歌一个场景、换歌靠 `AnimatedSwitcher` 叠新旧两层淡化——淡化期间两个全屏物理分辨率着色器各跑各的 30fps 驱动，外加两层不透明度合成；每层着色器 paint 上再叠 `ColorFilter.matrix`（整屏多一遍滤色）；新场景要异步等 `FragmentShader` 实例，第一帧先走离屏回退（toImageSync + 大 sigma 模糊）。
- **[x] ① 已修复** —
  1. 后端记下「已排进 mpv 的联网取流下一首」那份源（`_queuedStream`，按 `_nextGen` 代次失效），`_open` 打开的正是它、同一代、地址没进重取余量时直接复用，不再取流 + 探测；换下一首 / 停止 / 自然推进 / 403 原位重取都作废它。
  2. 新增 `musicRemoteCoverProvider`（`AppCachedHttpImage` 磁盘缓存 + 封面请求头），音乐的在线封面全部走它：一次下载各尺寸共用，之后读盘。
  3. 背景改为单场景两层：换歌 / 换样式在同一个画家里交叉淡化；两层都走 pixi 着色器时在**一次** pass 内混合（着色器新增 B 层封面 / 形态 / `uMix`），调色矩阵与不透明度并进着色器（去掉整屏 `ColorFilter`）；着色器程序加载后同步建实例，新层第一帧就走着色器。回退样式（mesh / classic / 无封面）淡化时旧层沿用离屏缓存、只按不透明度合成。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_mpv_plugin_stream_real_test.dart`（真 libmpv：手动切到预排的下一首不再调插件取流、快过期的地址重新取、非预排曲照常取）；`fushi/test/pages/music_lyrics_backdrop_test.dart`（换歌只有一个场景、无 `AnimatedSwitcher`、淡化期间不重画离屏图、淡完停帧）；`fushi/test/media/music/visualizer/lyric_visualizer_host_test.dart`（在线封面 provider 是带请求头的 `AppCachedHttpImage`）。着色器用 impellerc 编过 GLES / Vulkan / Metal 三种 runtime stage。
- **备注**：未做——① 点列表里任意一首 / 上一首仍要现取流（没有预取对象）；② 插件 http 的 DNS 每次 `pin` 都重新解析（`plugin_net_guard.dart`），系统 DNS 缓存一般能兜住，没改；③ 封面 URL 的缩图参数（如网易云 `?param=WxH`）属于插件侧，宿主不硬编码平台规则。真机观感（淡化观感、帧耗时）未在 app 里实测。
