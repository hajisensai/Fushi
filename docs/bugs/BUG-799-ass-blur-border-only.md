## BUG-799 · ASS `\blur` 有描边时整字被糊成一团（应只糊描边、留锐利字面）
- **报告**：2026-07-14（用户：视频字幕截图，`{\blur5}かわいい娘ができて　幸せ`，Nekomoe kissaten ASSx2 Text_JP2 样式 Outline=2.5，整行白字被糊成不可读的一团，黑描边完全消失；mpv 渲染为清晰白字+柔光黑晕）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/video_subtitle_overlay.dart:1148-1153`（修复前）——TODO-1373 的 `\blur/\be` 实现把**合成字形（描边+填充+阴影）整体**包进 `ImageFiltered` 高斯模糊。libass 语义（`ass_bitmap.c`）是：**`\bord>0` 时只对描边位图做高斯，字面填充保持锐利**（阴影是模糊后描边位图的平移拷贝，随之同糊）；只有 `\bord==0` 才糊字形本身。fansub 对白常用「白字+细黑边+`\blur`」组合追求柔光晕效果，整体糊直接毁掉可读性。
- **[x] ① 已修复** — `_buildSubtitleChar` 把 sigma 提前算：有描边分支只把 `ImageFiltered` 包在描边层（stroke Text，含 ASS 阴影）上，fill 层留在滤镜外保持锐利；无描边分支维持整字形糊（libass 同语义）。命中矩形不变（ImageFiltered/Stack 不改布局），逐字查词照常。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_blur_border_semantics_test.dart`：①有描边+`\blur`：stroke 层必须在 `ImageFiltered` 内、fill 层必须不在（修复前红）；②无描边+`\blur`：整字形糊保留；③无 `\blur`：零 `ImageFiltered`。既有 `video_subtitle_overlay_markup_test.dart` / `video_subtitle_obscure_blur_sigma_test.dart` 无回归。
- **备注**：与 PR#65 的 `\blur` 量级修正（`2/sqrt(ln256)` 因子，`assBlurValueToSigma`）正交——那次修的是 sigma 数值，本次修的是施加对象。真机观感（柔光晕 vs mpv）待用户复测。姊妹 bug：[[BUG-800]]（同截图会话报的双语字幕闪烁）。
