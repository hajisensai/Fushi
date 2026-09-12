# ceshi CMVS 内嵌查词复核

## Proved

2026-09-13 从用户原目录运行 ChronoClock trial v2 的 `cmvs64.exe`，取消修改启动设置后进入主菜单并点击 START，随后点击正文推进，观察到正常日文正文。旧资料中的启动/locale 阻塞在本轮未复现。没有修改系统 locale。

- EXE SHA-256：`AA89205A61C7078A167F9E6668EEA2E4328BDD5C9CBCDD6F45B238CF475ACEA2`，x64。
- 游戏 PID 62980；正常启动后附着，helper PID 66880。
- helper 和 DLL 来自本独立 worktree `native/galgame_hook/build-x64/Release/`；源码基线 `a5fc01fd6b`。
- DLL SHA-256：`D263C0E18CB7477943D34AA4EB6ED7CFCD18FF269F8FDE8AFEDE007AAA451921`。
- helper SHA-256：`EE84AB00A91C54C0A265DC6E38CD3439E3DE901BA1C23B9FA869F9547813EB4A`。
- 注入日志记录两个 LoadLibrary 成功、Luna connected；生产 lookup probe 读到 IPC v24，启用 lookup 后 `text_writes=2`、`hits=0`、`frames=0`、`geometry=0/0`、`lookup_diag=0`。这仅证明文本区有写入，不证明已选正文线程。
- 本机日志：`.codex-test/cmvs-lookup/`，未纳入游戏内容。

当前 `CmvsAdapter` 只有文本及 PCM 能力，没有几何采集或 lookup admission 实现；零几何读数与源码一致。

## Not proved

尚未建立当前正文索引与最终屏幕字格的映射，没有新增生产 adapter，不能称内嵌查词完成，也不能认定游戏无法适配。没有进行字形命中、弹窗显示、输入屏蔽或制卡 E2E。

静态 EXE 使用 D3D9 绘制，导入 GetGlyphOutlineA。后者提供字体栅格化数据，不提供最终屏幕坐标，不能直接当布局 provider。保留 CMainFrameDraw / CTexture / CRenderTexture RTTI，但未证明正文布局对象契约。

## Checks

x64 CMake 配置及 hook、injector、lookup probe、ring probe 四个目标构建成功。存在既有构建警告；未做代码修改，因此没有运行 CTest、x86 或 Flutter 测试，构建不等于查词测试通过。

## Next gate

确认正文线程与 CMVS 文本布局/纹理绘制对象的对应关系，取得 source-index → glyph rect → 客户区投影契约后再实现严格 provider。游戏通过自身退出菜单关闭。
