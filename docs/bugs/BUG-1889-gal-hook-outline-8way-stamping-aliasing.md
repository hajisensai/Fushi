## BUG-1889 · gal 台词浮窗描边是 8 向偏移叠印伪描边，边缘粗细不均有锯齿感
- **报告**：2026-08-27（用户对着台词浮窗截图：「总感觉这个描边有点奇怪，奇怪地有锯齿感」）
- **真实性**：✅ 真 bug。先排除两处误判：这条大字台词**不是** Flutter 画的（`texthooker_page.dart:1341-1372` 那排「启动并捕获 / 附着并捕获 / 停止监听」才是 Flutter 工具栏，台词浮在它上方），也**不是** WebView2/CSS（全仓 `-webkit-text-stroke` 零命中）。它是 runner 自有的 Win32 分层窗，`FloatingLyricWindow` 在 `hook_text_mode_` 下用 Direct2D `DrawTextLayout` 直绘：`fushi/windows/runner/floating_lyric_window.cpp:1662-1699`（正文）与 `:1730-1749`（振假名）。
  实现是「同一 `text_layout_` 沿 8 个方向偏移各画一遍」的伪描边，三个锯齿来源：
  1. **半透明叠印的 alpha 非线性**：`outline_color` 默认 `0xE0000000`（alpha 224/255，**不是**不透明），8 遍直接 src-over 到 `D2D1_ALPHA_MODE_PREMULTIPLIED` 目标（`:199-205`）。字形边缘像素被覆盖的次数沿轮廓从 1 到 8 不等，累加 alpha 非线性且方向相关 → 描边粗细忽粗忽细，曲线笔画（の / っ / あ 的弧）最明显。附带一个语义 bug：叠 k 遍后实际不透明度是 1-(1-a)^k，用户把描边设成半透明，拿到的却几乎恒为纯色。
  2. **亚像素相位不一致**：`ScaleForDpi`（`:311-313`）是 `v * dpi_/96.0f`，**不取整**。`r = 1.6dip` 在 150% DPI 下是 2.4px，`d = r*0.7071 = 1.697px`——每一遍字形都在不同的亚像素相位上栅格化，灰度 AA 的边缘覆盖率各不相同，叠起来是摩尔纹式毛边。
  3. 未显式固定文字反锯齿模式（全文件无 `SetTextAntialiasMode` / `SetTextRenderingParams`）。
  仓库对这个形状已有判例：**BUG-323** 对视频字幕下过同样结论（「8 向偏移拷贝是伪描边，要换成沿轮廓单层描边」），视频字幕那边现在走的是真描边 `PaintingStyle.stroke` + `strokeJoin/strokeCap = round`（`fushi/lib/src/media/video/video_subtitle_style.dart:621`）。
- **[x] ① 已修复** — **没有**照搬 BUG-323 的真描边方案，理由是它在这里被明令禁止且禁得有道理：native 侧的等价做法是 `IDWriteFontFace::GetGlyphRunOutline → ID2D1PathGeometry → DrawGeometry`，落地必须经自定义 `IDWriteTextRenderer`，而 `test/lookup/overlay_ruby_render_guard_test` 禁止那条路——点字 `CharIndexAt`、折行、滚动、注音四处几何必须与 `text_layout_` 同源，分叉即各走各的（`test/build/gal_overlay_lyric_style_guard_test.dart` 的守卫 ① 也锁着「多遍偏移」这条路本身）。
  所以修正**留在多遍偏移这条路内**，消除上面的根因 1 与 2：
  - **偏移取整到物理像素**：`r` / `d` / 注音的 `rr` / `rd` 全部经 `std::round`，各描边遍与填充遍同相位。
  - **图层内不透明叠印 + 一次性 alpha 合成**：`CreateLayer` 后 `PushLayer(..., opacity = outline_color 的 alpha)`，图层内描边画刷强制不透明（`style_.outline_color | 0xFF000000`）——多遍叠加只决定**形状的并集**，不再累加 alpha；`PopLayer` 时按用户真正设定的 alpha 整体合成一次。正文与振假名两处各包一次（只包其一会让两处描边浓淡不同）。`CreateLayer` 失败时原样降级回旧路径（半透明直绘），拿不到 layer 也绝不少画描边。
  - **描边环 8 → 16 向**（补 22.5° 的 `n = round(r*0.9239)` / `m = round(r*0.3827)`）：8 向在曲线笔画上留的扇形缺口由中间这 8 个方向补齐。
  - 根因 3（显式 `SetTextAntialiasMode(GRAYSCALE)`）**刻意没做**：PREMULTIPLIED 目标下 D2D 本就退到 GRAYSCALE，它不是根因；而 `SetTextAntialiasMode` 是 render target 级状态，设了会连带改到有声书歌词条与剪贴板文字窗的观感，违反「其余浮窗逐像素不变」（守卫 ②）。
- **[x] ② 已加自动化测试** — `fushi/test/build/gal_overlay_outline_aliasing_guard_test.dart`（源码守卫，C++ 无法在 Dart 测试里执行），10 条：取整三处（正文半径 / 对角与 22.5° 分量 / 注音）、图层四条（描边色强制不透明、alpha 提取成图层 opacity、正文与注音各 Push/Pop 一次且配对、CreateLayer 失败降级）、以及三条「没绕过禁令」（仍无 `IDWriteTextRenderer`、描边环仍复用 `text_layout_`、补到 16 向）。
  既有守卫 `test/build/` + `test/lookup/` 整批 1050 条通过，`gal_overlay_lyric_style_guard_test` 与 `overlay_ruby_render_guard_test` 均未被打红。
  变异实测：撤掉整像素对齐（保留图层）→ 精确红「主文本描边半径经 std::round」与「对角与 22.5° 分量同样取整」2 条，图层那组仍绿（隔离正确）；还原后 sha256 与变异前一致（`779f1ba8ad0dfe9c…`）。
- **备注**：Windows-only。已做 `flutter build windows --debug` 编译验证。**肉眼复测未做**（真机验证环节用户已取消）——「锯齿是否真的消失」最终是个视觉判断，源码守卫只能证明三条机制接上了，证不了观感。若复测时发现 `PushLayer` 在 DC render target + `UpdateLayeredWindow` 分层窗下有意外（例如图层被额外做了一次 premultiply），降级分支（`outline_layer == nullptr`）就是现成的回退口子。
