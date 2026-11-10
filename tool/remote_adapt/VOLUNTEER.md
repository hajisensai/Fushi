# Fushi 远程适配：志愿者说明

谢谢帮忙！装好以后，维护者（和他的 Claude）可以远程操作你的电脑，在你**自己的游戏**上调试 Fushi 的
galgame 内嵌查词。

## 安装（一次，约 5 分钟）

1. 安装 Tailscale，并用维护者发的邀请链接登录：
   ```powershell
   winget install Tailscale.Tailscale
   ```
2. 解压适配包到一个固定位置（例如 `D:\fushi-adapt`），在该目录打开 PowerShell：
   ```powershell
   powershell -ExecutionPolicy Bypass -File install_agent.ps1 -Name 你的机器名 -Gateway <维护者给的地址> -Token <维护者给的 token>
   ```
   如果你的游戏要「以管理员身份运行」，改在**管理员 PowerShell** 里运行，并加 `-Elevated`。
3. 任务栏会出现「Fushi 远程适配 agent」窗口，显示「已连上网关」就好了。之后每次登录 Windows 会自动启动。

## 它能做什么

- 截屏、移动 / 点击鼠标、按键、模拟触摸；
- 运行 PowerShell 命令、在本目录读写文件；
- 在本目录的 `work\test-root` 里启动一份**隔离的** Fushi 测试版，不会改动你自己的 Fushi 数据
  （需要词典时会把你的 Fushi 数据**复制**一份进去，原数据不动）。

窗口里会逐条显示收到的操作。

## 需要你配合的

- 调试时保持登录、不锁屏（锁屏后截图和点击都无效）。
- 维护者会告诉你需要准备哪款游戏、装在哪里。

## 暂停 / 卸载

- 暂停：关掉「Fushi 远程适配 agent」窗口即断开，下次登录会自动重新连接。
- 卸载：`powershell -ExecutionPolicy Bypass -File install_agent.ps1 -Uninstall`，然后删除本目录、退出 Tailscale。

## 隐私

调试时维护者会看到你的屏幕截图和游戏台词。这些只用于临时排查，不会提交到代码仓库，也不会公开。
