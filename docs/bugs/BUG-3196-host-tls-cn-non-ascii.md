## BUG-3196 · 计算机名含中文时主机服务开不起来（自签证书 CN/SAN 只收 ASCII）
- **报告**：2026-10-07（用户群聊：开「本机作为同步服务器 › 主机服务」报「同步错误：Invalid argument (string): Contains invalid characters.: "大祥老师的电脑"」；群里说「名字好像不能有中文」。需求清单里被误记成 galgame「游戏名带中文无法打卡」，实为互联主机服务，与 galgame 无关）
- **真实性**：✅ 真 bug。主机服务首次启动生成 TLS 自签证书，CN 与 dNSName SAN 直接用 `Platform.localHostname`；basic_utils / asn1lib 把它们按 PrintableString / IA5String（ASCII）编码，Windows 允许中文计算机名，`ascii.encode` 抛 `Invalid argument (string): Contains invalid characters.`，证书生成失败、主机服务起不来（`packages/fushi_engine/lib/sync/tls/fushi_tls_identity.dart:48`）。
- **[x] ① 已修复** — 新增 `tlsSafeCommonName`：只留主机名字符（字母 / 数字 / `-` / `.`），去首尾分隔符、截 63 字符，一个可用字符都不剩时退回 `fushi-host`；证书生成器在写 CN / SAN 前统一归一。身份校验走指纹钉扎，名字只是标签，归一不影响配对与连接。
- **[x] ② 已加自动化测试** — `fushi/test/sync/tls/fushi_tls_identity_test.dart`：用「大祥老师的电脑」「Wight的MacBook」生成证书并装进 `SecurityContext`；`tlsSafeCommonName` 的归一规则。
- **备注**：已有证书的设备不受影响（`loadOrCreate` 直接读盘）；只影响首次生成 / 重置证书。
