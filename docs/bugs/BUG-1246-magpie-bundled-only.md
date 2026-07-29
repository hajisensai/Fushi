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
    镜像、续传、确认框和后台更新。缺包返回 `bundleMissing`，由上层降级并提示更新/重装
    Hibiki，不再联网补取。
  - `magpie_upscaling.dart` / `magpie_upscaling_service.dart` 把 `needsDownload` 改成
    `needsBundledInstall`；删除下载确认注入和 `magpie_download_confirm.dart`。
  - 超分档位文案改成“启用 Hibiki 内置版本，不需要下载”；“仅用已装”明确表示不解压
    Hibiki 内置版本，避免两个档位继续围绕已经不存在的下载行为解释。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/mining/magpie_installer_test.dart` 增加零网络源码守卫，禁止 `HttpClient`、
    `ResumableDownload`、远端 URL、确认回调和后台更新入口回流，并钉住缺包返回值。
  - `hibiki/test/mining/galgame_helper_no_network_guard_test.dart` 扩展到 Magpie；
    `magpie_bundled_install_test.dart` 保留随包摘要/清单及 debug/release 组包契约。
- **备注**：按用户要求不等待 Windows 编译与安装包真机验收；本轮只跑定向 Flutter 测试、
  i18n/BUG 守卫和静态分析。正式包仍由现有 workflow 生成并携带 4.72 MB 精简归档。
