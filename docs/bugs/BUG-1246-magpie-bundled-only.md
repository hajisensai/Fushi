## BUG-1246 · Magpie 内置后仍显示并保留下载路径
- **报告**：2026-07-29（用户截图指出：“这什么垃圾说明，我们不是内置了吗，还下载？”）
- **真实性**：✅ 真 bug。BUG-1217 虽然把精简 Magpie 放进 Windows 主包，但
  `hibiki/lib/src/mining/magpie_installer.dart:542-601` 仍在随包安装失败后落到确认框和
  `_runInstall` 网络路径，`:604-645` 还保留后台静默自更新；同时
  `hibiki/lib/i18n/strings_zh-CN.i18n.json:2736-2737` 继续向用户解释“下载约 10 MB”。
  所以这不是单纯旧文案：开发构建、旧包、归档缺失/损坏和 ARM64 判定都可能真的联网。
- **[x] ① 已修复** —
  - `magpie_installer.dart` 收口为随包唯一来源：生产固定使用随包 x64 精简归档（ARM64
    Windows 走系统 x64 模拟），保留 SHA-256、staging 清单和原子换入，删除 HTTP、
    镜像、续传、确认框和后台更新。缺包返回 `bundleMissing`，由上层作为安装包不完整的
    **硬错误**明确报告；摘要或归档损坏也单独报校验错误，不再联网补取或伪装成“暂时不可用”。
  - `magpie_upscaling.dart` / `magpie_upscaling_service.dart` 把 `needsDownload` 改成
    `needsBundledInstall`；删除下载确认注入和 `magpie_download_confirm.dart`。
  - 超分档位文案改成“启用 Hibiki 内置版本，不需要下载”；“仅用已装”明确表示不解压
    Hibiki 内置版本，避免两个档位继续围绕已经不存在的下载行为解释。
  - 删掉随下载链路一起失去消费者的 `magpieArchForProcessorArchitecture` /
    `magpieCurrentArch`：只剩一个 x64 切片之后，“探测机器架构”没有任何调用方。
  - `hibiki/windows/CMakeLists.txt` 增加与 helper 同款的 `install(FILES ... OPTIONAL)`，
    把 `dist/Magpie-hibiki-slim-x64.zip[.sha256]` 拷进 bundle 的 `magpie_bundle/`。
    此前该目录**只**由 CI 的独立 YAML 步骤创建，于是 `flutter run` / debug 构建出来的
    exe 旁边永远没有它，超分在开发构建里恒 `bundleMissing`、根本没法验证。
  - `tool/check_release_policy.ps1` 补 `magpie_bundle` 断言（组包脚本 + 载荷目录 +
    sha256 侧车，两个 Windows workflow 各一套）：下载链路删干净之后，随包归档是超分
    **唯一**的安装来源，漏带它会构建全绿而用户侧恒报“安装包不完整”。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/mining/offline_installer_guard.dart`（新增，helper 与 Magpie 共用）：
    判据从**字面量黑名单**升级为**可达通道**检查 —— import 白名单 + 折叠字符串拼接后的
    能力名扫描（`Uri` / `Http*` / `*Socket` / `download` / `dio` …）。旧守卫只扫
    `HttpClient` / `https://` 这几个串，而 app 直接依赖 `http` 与 `dio`，于是
    `import 'package:http/http.dart'` + `Uri.parse('htt' 'ps://…')` 这条**最自然的**写法
    整条穿过守卫、测试全绿（已实测复现）。
  - `magpie_installer_test.dart` / `galgame_helper_no_network_guard_test.dart` 改用共享
    判据，并钉住跨模块复用只 `show` 四个纯工具函数（退化成整包 import 等于把对面全部
    符号拉进可达面）。
  - `magpie_upscaling_test.dart` 的 BUG-1100 文案守卫补上 `failureReason` 这一维：新增的
    两条交付错误文案原本完全不在遍历范围内。
  - 行为断言同步到新契约：`auto` 缺随包 → `failed` + `bundleMissing`（交付错误），
    `installedOnly` 没装 → 仍是 `unavailable`（用户自己选的档位，不是交付错误）。
- **状态**：`implemented_unverified`。按用户要求不等待 Windows 编译与安装包真机验收；
  本轮只跑定向 Flutter 测试、i18n/BUG 守卫和静态分析，**没有一次真机执行**，不得据此
  宣称“窗口超分已修好/已支持”。正式包仍由现有 workflow 生成并携带 4.72 MB 精简归档。
