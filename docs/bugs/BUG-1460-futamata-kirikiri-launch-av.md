## BUG-1460 · 恋爱成双由 Hibiki 早注入后 Access Violation
- **报告**：2026-08-08（用户：Wight）
- **真实性**：✅ 真 bug。`injector/injector_main.cpp:2308` 对未命中既有例外的游戏使用
  `CREATE_SUSPENDED`；该标题在挂起态早注入后，`hook/adapters/kirikiri_adapter.inc:1150`
  会从插件 `V2Link` 启动边界安装 raw TVP stream hook，随即出现 Fatal Error / Access
  Violation。直接启动正常；移除这一处 raw stream 安装调用正常；正常启动并等
  `wuvorbis.dll` 与游戏窗口就绪后再附着也正常，故失败边界是该二进制的早注入生命周期，
  不是通用 injector 或 LunaHook。
- **[x] ① 已修复** — 提交 `673f6e062`：新增精确 SHA-256 的 KiriKiri 延迟附着 profile，
  `injector/injector_main.cpp:2278` 只对用户提供的中/日文两个二进制改为正常启动；
  `injector/injector_main.cpp:2397` 等主窗口与 `wuvorbis.dll` 就绪后再注入。其它 KiriKiri
  二进制保留早注入。提交 `155045336` 继续修复旧 Hibiki 消费兼容：
  `include/voice_hook_ipc.h:650` 按 helper/DLL 的完整 basename 选择 Hibiki 或 Fushi IPC
  命名空间，`injector/injector_main.cpp:117` 同步选择同品牌默认 DLL，避免游戏已启动后旧 host
  报 `voice_hook_open_mapping_not_found`。
- **[x] ② 已加自动化测试** — 提交 `673f6e062`：
  `native/galgame_hook/tests/kirikiri_launch_profile_test.cpp` 覆盖两份精确哈希、单 nibble
  near-miss、无关 KiriKiri 样本与空身份；定向运行
  `fushi_kirikiri_launch_profile_test.exe` 通过。提交 `155045336` 新增
  `native/galgame_hook/tests/voice_hook_ipc_name_test.cpp`，覆盖旧/新组件名、大小写、后缀
  near-miss 及两套精确映射/事件名；定向运行通过。
- **备注**：修复后实测中文版 PID 28496 在 765 ms 内返回 `OK hooked`，窗口正常响应，
  `fushi_voice_hook.dll` 与 `wuvorbis.dll` 均已加载。按用户要求未跑全量构建、全量 CTest
  或制卡 E2E；支持状态保持 `implemented_unverified`。旧 Hibiki 兼容实测 PID 6628：
  `Local\HibikiVoiceHook_6628` 可打开、Fushi 同名映射不存在，游戏窗口响应并返回
  `OK hooked`。
