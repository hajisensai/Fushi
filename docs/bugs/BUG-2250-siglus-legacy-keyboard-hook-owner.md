## BUG-2250 · 旧版Siglus键盘状态接口被通用输入盾抢占
- **报告**：2026-09-08（原始启动路径复测 Rewrite 体験版 Ver.2.00）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/generic_input_shield.inc:787` 在 Siglus 身份判定前安装 `GetKeyboardState`；旧版精确输入随后在 `hook/adapters/siglus_lookup.inc:1186` 请求同一目标。`HookFn` 对已跟踪目标返回成功但不提供第二份原始 trampoline，导致旧版传感器安装始终失败。预留 `GetKeyState` 没有覆盖整张键盘状态接口。
- **[x] ① 已修复** — `ShouldReserveSiglusKeyboardState` 在身份未定和旧版 family 下预留键表；现代 family、身份拒绝和 x64 放行通用安装。精确接口已安装时只补 coverage，不重复注册 trampoline。修复未使用游戏哈希或固定 RVA 准入。
- **[x] ② 已加自动化测试** — `tests/generic_input_shield_install_test.cpp` 通过 CMake 直接提取并执行生产安装函数和预留判定，覆盖 pending、现代双 family、旧版延后启用、精确先装、拒绝/其它引擎、重复轮询及 Leaf/Hunex 负向。x86 Release 六类场景通过；私有夹具替换为修复前生产安装函数时编译成功、断言失败。另有 `tests/adapter_structure_test.py` 49 项守卫通过。测试提交 `6415fdff1b`，注册与生产修复同下一提交。
- **备注**：修复前真实游戏 PID 2056 的 sensor 未安装，输入盾 required `0xE4` / ready `0x64`；正常退出并替换测试 bundle DLL 后，从相同 `Start.exe` 经转区菜单进入 PID 51284，sensor 与采样盾已就绪，required/ready 均为 `0xE4`。新 DLL SHA-256 `6F6064FD90FA16DAFFBA9865D8AD78AEA28BEEB4B210464EB67C4B71DCB233F6`。本条只证明接口安装修复，正文点击、语音配对和制卡仍须独立验收；不升级引擎支持状态。
