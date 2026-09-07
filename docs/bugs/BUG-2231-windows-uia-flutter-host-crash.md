## BUG-2231 · Windows宿主在UIAutomation回调进入Flutter时访问冲突退出
- **报告**：2026-09-07，Windows Siglus 适配验收中发现。宿主 PID 73368 导入词典成功后，从设置返回游戏首页、准备打开工作台时退出；当时尚未附着任何游戏。
- **真实性**：✅ 真 bug（Windows Event1000/1001 与两份本地转储确认）。14:26:59 记录 `c0000005`，14:27:05 记录 `c000041d`；同一 PID、开始时间、线程 72760、同一 `flutter_windows.dll+0x8e50da`。首个异常是读取 `0xffffffffffffffff` 引起的访问冲突。通过转储与时间戳匹配的本地 PE unwind 信息恢复出相同的 24 帧调用栈：Flutter `+8e50da → +8e5163 → +8dcfa0 → +9166b0 → +916121`，其调用方为 `oleacc` / `UIAutomationCore`，下层为 Windows 消息回调与 `GetMessageW`。确认走可访问性/UIAutomation 路径，但尚未确认具体失效对象或根因源码行，不能归属到注入器、Siglus adapter 或词典业务。
- **[ ] ① 未修复** — 当前缺少匹配 Flutter PDB，无法将内部偏移准确符号化。DLL 时间戳 `0x6a07c2d0`，SHA-256 `3168C546AEB0B0E6A77ABC97E0DE95B45D13ADA150FAAAD6DE75E79ACAF3B050`，PDB GUID `B97F462F-3431-49FC-A61E-A9DFED8E059C`、age 1；本机 SDK 为 Flutter 3.44.0、engine `4c525dac5ebe5971c5708ef73558ed8edcf4a362`。导出表最近符号距离超过 1 MB，不足以命名故障函数。后续需匹配符号与可重复触发证据后修复；本轮不修改 Flutter engine、不关闭可访问性、不添加绕过。
- **[ ] ② 未加自动化测试** — 已有真实异常与有界线程栈证据，但尚无确定性触发条件或根因层测试。不能把一次重新启动成功当作回归测试通过。
- **备注**：重启宿主 PID 36616 后，主代理确认游戏页面、两款原版游戏附着、Anemoi 实际查词均正常；这是后续正向验证，不能说明本崩溃已修复。此项独立于 BUG-2230 的快照读取契约缺口；没有证据建立二者因果关系，也不能把此前纹理桥 UAF 记录直接套用到本事件。

本地证据仅留在未入库的 `.codex-test/siglus-engine-adapter/host73368-crash/`：`findings.md`（边界说明）、`application-events.json`（WER 元数据）、`stack-av.txt` / `stack-callback.txt`（仅异常线程模块栈）、`binary-hashes.json`（构建身份）以及有限栈提取工具源码。诊断过程没有改动用户数据、注册表或进程；仓库不提交转储、游戏载荷或用户内存。两份原始转储仅本机留存，不随此记录发布。
