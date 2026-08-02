## BUG-1449 · helper 改为构建期解压随包，消灭需与本体同步的第二份副本

- **报告**：2026-08-02（用户连问三处：「安装/更新的时候不应该初始化吗？」「两个架构不是
  都应该装吗？」「全部动手，根本性修复」）
- **真实性**：✅ 结构性缺陷（不是单点故障，是 [BUG-1448](BUG-1448-gal-helper-version-check-short-circuited.md)
  能够存在的土壤）

### 为什么是根因的根因

BUG-1448 是「版本对账被前置门短路」。但更该问的是：**为什么需要运行期版本对账？**

因为磁盘上存在**两份** helper：随包的 `galgame_helper/*.zip`（归档）和解压落地的
`voice_hook/<arch>/`（真正被注入的那份）。两份就必须同步，同步就会断——BUG-1448 断在
调用点，就算修好调用点，同步这件事本身仍然是运行期行为，仍有下一个断法。

这套 zip + sha256 侧车 + 运行期校验/解压/换入的机制，是 helper 还**走网络下载**时的设计
（BUG-1103 的安全边界针对的是被掉包的下载产物）。BUG-1196 把 helper 改成随主包内置后，
这套机制的前提就没了，却留了下来，只剩一个后果：多一份要跟本体保持同步的副本。

用户的两问直接击穿了它：
- **「安装/更新时不应该初始化吗？」** —— 应该。安装器本来就在往 `{app}` 铺文件。
- **「两个架构不是都应该装吗？」** —— 是。两个 zip 本来就都随包了，磁盘上都在。
  于是「装哪个 arch 取决于目标游戏位数、app 启动时不知道」这个 lazy 安装唯一的借口不成立：
  `is32Bit` 只该用来**选用哪个**，不该用来**决定装哪个**。

### 修复与测试

- **[x] ① 已修复** —— helper 改为**构建期**解压成普通文件随包：
  - 新增 `native/galgame_hook/tools/install_into_bundle.ps1`：校验 zip 与侧车 sha256
    （fail-closed 前移到构建期）→ 解压两个架构进 `<bundle>\voice_hook\<arch>\` → 按清单
    复检完整 → 写 `installed.sha256` 版本标记（与运行期安装器写的同形，账目一致）。
  - `release-desktop.yml` / `build-multiplatform.yml` 改为调用该脚本，**不再**把 zip 复制进
    `galgame_helper/`。这两段原是孪生副本——「两份各自漂移」正是本条要根治的形态，
    所以解压逻辑收进同一个脚本，不再复制粘贴。
  - `hibiki.iss` 新增 `[InstallDelete]` 清掉上一版残留的 `{app}\galgame_helper`。
    **这一步不能省**：残留归档会以「随包真相源」的身份留在磁盘上，用户一旦手工删过
    `voice_hook\<arch>\installed.sha256`（排障时的常见动作，也是本轮给用户的自救建议），
    `GalgameHelperInstaller` 就会拿那份**旧** zip 回填，把安装器刚放好的新组件覆盖成旧的，
    当场复发 BUG-1448。打包侧 `Source: "{#SourceDir}\*"` 本就是 `recursesubdirs`，
    所以 `voice_hook/` 自动进包，**安装器打包段一行未改**。
  - Dart 侧**行为零改动**，只更新注释与日志措辞：`_ensureBundledVersion` 的
    「随包归档不存在 → 沿用现有安装」从异常路径变成**正常路径**（安装器已保证同源），
    整套归档安装逻辑保留给便携解压 / 开发构建 / 用户误删组件的修复。

  结果：helper 与本体同一次构建产出、同一个安装包落地，**版本漂移在结构上不再可能**，
  正常安装路径上不可能再出现「捕获组件与本体版本不一致」。

- **[x] ② 已加自动化测试** —— `hibiki/test/mining/gal_helper_bundled_as_plain_files_test.dart`：
  ①脚本的 x86/x64 必需文件清单与 `galgameHelperRequiredFiles` **逐条比对**（两份清单不得已，
  但「两份各自漂移」是 BUG-1345 的形态，故用守卫钉死；用宽/严两个正则交叉校验，
  防两个正则一起写错导致空列表相等的假绿）②两个 workflow 都必须调用共用脚本且不得再出现
  `galgame_helper` ③`hibiki.iss` 的 `[InstallDelete]` 必须清 `{app}\galgame_helper`。
  `galgame_helper_installer_test.dart` 中钉旧契约的那条同步改为钉新契约。

  变异实测：脚本清单多一项 / workflow 恢复 `galgame_helper` / `[InstallDelete]` 改名，
  三条逐一如期判红且 reason 精确对应；还原后 83 项定向测试全绿、全量 `flutter analyze`
  无 issue。

  **脚本真机实跑**（不是只读断言）：用用户机器上的真 zip 作 dist，在 PowerShell 5.1 下
  执行 `install_into_bundle.ps1` —— x86 7 个、x64 19 个必需文件全部校验通过，marker 内容
  等于 zip 的 sha256；再把侧车篡改成全 0 重跑，**退出码 1**、错误带双方摘要，
  fail-closed 确认生效。

- **备注**：磁盘占用变化（实测）——zip 合计 34.9 MB，解压后合计 80.5 MB。只玩单一架构的
  用户从 37.5 MB 升到 80.5 MB（+43 MB，主要是 x64 的 `unity_audio_runtime`）；而**同时玩
  32/64 位游戏的用户从 115.4 MB 降到 80.5 MB**（旧模型下 zip 与两份解压结果同时留在磁盘）。
  安装包体积预计持平或略降：旧模型塞进去的 zip 已压缩过、Inno 的 lzma2 压不动，
  换成原始 exe/dll 后 solid 压缩效果更好。此项未实测，需一次真实出包核对。
