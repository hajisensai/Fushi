## BUG-2358 · 启动菜单等待耗尽游戏注入握手期限
- **报告**：2026-09-08（剩余 Siglus 适配中的原始启动菜单回归）
- **真实性**：✅ 真 bug。`fushi/lib/src/mining/galgame_audio_source.dart:2051` 的 helper 输出等待原先从进程启动起共用固定握手期限；`native/galgame_hook/injector/injector_main.cpp:2475` 的启动器子进程发现也使用同一 `--wait-ms` 期限。用户停在官方启动菜单时尚未启动游戏，却已耗尽机器注入预算；宿主随后停止 helper，native 还可能尝试注入已确认的启动器。BUG-2249 的角色字段阻止了部分重复转区启动，但没有分离两个阶段。
- **[x] ① 已修复** — 只有经过现有目录结构识别的交互启动器发出 `role=launcher wait=launcher`。native 使用保留句柄和创建时间验证的完整进程链等待用户操作；整条链结束或无法读取进程快照立即结束，不注入菜单。确认稳定游戏子进程后才进入原注入流程，宿主给该转换一次完整握手预算；迟到/重复记录不能续期或将游戏身份降回菜单。未知角色、旧 helper、普通直接附着保留有界等待。控制器只允许明确 `role=game` 的 PID 进入失败后的附着/恢复路径。取消仍终止 helper，不终止用户游戏。实现见本文件同批修复提交。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/launcher_wait_test.cpp` 直接执行生产等待策略和 `ChildProcessLineage`，覆盖菜单跨越原期限、Start 退出但菜单存活、整链退出、创建时间/PID 复用、稳定观察、未知启动器期限及失败关闭；x86/x64 Release 定向编译运行通过。`fushi/test/mining/gal_launcher_wait_test.dart` 通过真实 `EngineHookGalAudioSource.start` 和可控 helper 管道覆盖阶段转换、重复/矛盾/分批记录、EOF、helper 退出、取消和 attach 边界。与启动结果/转区恢复/控制器/诊断守卫共 188 项定向测试通过；完整 injector 源码 x86/x64 编译链接及双架构 CLI 契约测试通过。
- **备注**：本修复只覆盖 Windows 启动握手，不改变引擎文本、几何或音频 Hook。源代码与自动化验证完成；官方菜单停留超过原 30 秒后进入游戏的原路径实机验证由整合后的 Windows bundle 执行，不能用单元测试代替该验收。
