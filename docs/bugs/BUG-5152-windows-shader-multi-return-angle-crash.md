## BUG-5152 · Windows Impeller(ANGLE) 下带采样器且 main() 多处 return 的片元着色器可能让 d3dcompiler_47 崩溃（flutter#190809）
- **报告**：2026-11-22（来源：PR #3400 审查；Flutter 3.50.0 的 impellerc 在 `flutter test` / 构建时对 5 个着色器打印「Shader Warning」）
- **真实性**：⚠️ 待复现（潜在风险，未在本仓观测到崩溃）。上游 flutter/flutter#190809（P1，Windows / Impeller
  `OpenGLESSDF`）：带纹理采样器、`main()` 里有多处 `return` 的运行时片元着色器，ANGLE 交给 `d3dcompiler_47.dll`
  编像素着色器时 `0xc0000005` 崩溃；报告版本 3.47.0 beta，上游只在 impellerc 加了编译期警告
  （`engine/src/flutter/impeller/compiler/compiler.cc:688`）就关单，引擎侧未修，所以 3.47.6 与 3.50.0 同样存在，
  不是升级带来的回归，只是 3.50 起才看得见。命中本仓的：`fushi/shaders/page_curl.frag:153` 起的 `main()`
  （6 处 `return`，采样 `uSheet` / `uBase` / `uBackSheet`）；依赖 `liquid_glass_widgets-1.8.1` 的
  `progressive_blur.frag`、`lightweight_glass.frag`、`interactive_indicator.frag`、`liquid_glass_render.frag`。
- **[ ] ① 未修复** — 待做：先在 Windows 真机 / CI 窗口上用 Impeller 跑翻页卷曲与液态玻璃确认是否崩；无论是否复现，
  `page_curl.frag` 都按上游给的规避改成 `main()` 单出口（各分支写 `fragColor` 后落到末尾），视觉逐帧比对不变；
  `liquid_glass_widgets` 的四个着色器走 `ci/patches/hosted` 打补丁或提上游。
- **[ ] ② 未加自动化测试** — 改完加源码守卫：仓内与 `ci/patches/hosted` 下的 `.frag` 的 `main()` 不得出现多处
  `return`（或直接把 impellerc 的该警告在 CI 里当错误）。
- **备注**：Windows 渲染全线 Impeller（ANGLE → D3D11），不得用关 Impeller 规避。
