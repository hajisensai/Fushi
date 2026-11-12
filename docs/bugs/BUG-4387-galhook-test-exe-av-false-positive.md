## BUG-4387 · Kaspersky 把 galgame hook 测试 exe 报为 Trojan.Win32.Sdum.gen 并删除
- **报告**：2026-11-11（用户：Kaspersky 弹窗「检测到 VHO:Trojan.Win32.Sdum.gen，位置 …Release\fushi_utterance_window_test.exe」）
- **真实性**：✅ 真问题（杀软误报，非恶意代码）。`native/galgame_hook/CMakeLists.txt:461` 的
  `fushi_utterance_window_test` 与其余 ~140 个测试 exe 一样是不带任何版本资源的极小控制台程序；
  x64 Release 产物恰好撞上 Kaspersky 的泛型启发式（VHO = 启发式），落盘后数秒内被锁定并删除，
  x64 CTest 因此静默少跑一条（BUG-1708 验证记录里的 32/33 就是它）。源码只有纯算术断言 + printf。
  本机独立复现（scratchpad 单独 CMake 工程，同源码 x64 Release）：
  - 不带 VERSIONINFO：构建两次，两次都被锁 / 删除（`uw_orig`「being used by another process」、`uw_orig2` 10s 后已不存在）；
  - 只多一段 VERSIONINFO：构建两次，两次都留存并输出 `utterance_window_test: ok`；
  - 对照：同配置的 `voice_clip_energy_test`、Debug 配置的同一测试均不被拦。
- **[x] ① 已修复** — 新增 `native/galgame_hook/tests/test_version.rc`，`CMakeLists.txt` 末尾在 MSVC 下遍历
  `BUILDSYSTEM_TARGETS`，给所有 `*_test` 可执行目标统一挂上，不逐个目标打补丁、以后新增的测试自动覆盖。
  未改发布产物（injector / probe / DLL）。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/test_version_resource_test.cpp`（CTest
  `fushi_test_version_resource_test`）：读自身模块的 VERSIONINFO 并核对 FileDescription；它本身也是被同一循环
  挂上 .rc 的，循环失效或 .rc 丢失即红。
- **备注**：误报判定依赖 Kaspersky 特征库，库更新后可能变化；当前修法是让测试 exe 带上正常 PE 都有的版本元数据，
  不涉及签名、不加白名单。已被删除 / 标记的旧产物在各 worktree 的 `build/x64/Release/` 下，重新构建即可。
