## BUG-2404 · Mihon 全局代理选择器误将 TCP socket URI 发送至 HTTP 策略端点
- **报告**：2026-09-10（用户：在 Windows Fushi 下载《週に一度クラスメイトを買う話》测试，不使用 Mokuro；Rawkuma / WeLoveManga 均报代理策略不可用。）
- **真实性**：✅ 真 bug。`third_party/m_extension_server/overlay/server/src/main/kotlin/mextensionserver/impl/HostProxyPolicy.kt:92` 的全局 `ProxySelector.select` 无条件把所有 URI 发送到宿主；JDK `SocksSocketImpl.connect` 会为 OkHttp 已选路的底层 TCP socket 再调用它，URI scheme 为 `socket`。`fushi/lib/src/media/manga/mihon/mihon_proxy_policy_server.dart:41` 仅接受 HTTP(S)，返回 400；Kotlin lookup 抛出通用 IOException，被外层包装成 BRIDGE_HTTP_500。
- **[x] ① 已修复** — `HostProxyPolicy.select` 区分底层 socket 传输与原始 HTTP 选路；非 200 错误保留纯数字状态码。修复提交见本文件同批 Git 提交。
- **[x] ② 已加自动化测试** — `HostProxyPolicyTest.kt` 新增全局真实选择器下 Socket 字节往返、OkHttp 已选 HTTP 代理的真实请求测试。移除修复：7 项执行/2 项失败；恢复修复：7 项通过/0 跳过（Gradle exit 0）。
- **证据**：用户安装版 `D:/APP/Hibiki/fushi.exe` 的 Mihon 日志（2026-09-10 07:12:56 Rawkuma / 07:13:09 WeLoveManga）含完整 `HostProxyPolicy.lookup → select → SocksSocketImpl.connect → Socket.connect → okhttp3.internal.platform.Platform.connectSocket` 栈。使用安装版 Java 21 加全局选择器及真实 Socket 可复现 `socket://127.0.0.1:<port>` 回调；策略查询自身的 `openConnection(Proxy.NO_PROXY)` 不触发该回调。
- **边界**：HTTP(S) 仍由宿主决定 auto/manual/direct、认证与本地绕过，策略接口不可用仍报错；仅底层 `socket` 传输不重复做 HTTP 代理选路。不能通过放宽宿主 URL 校验、HTTP 失败自动直连或重启重试掩盖错误。
- **验收**：Windows `build_desktop_runtime.ps1` 完整 `:server:test` + `:server:shadowJar` 和 `verify_desktop_runtime.ps1` 均 exit 0。Dart 宿主策略、vendored server、出站纪律三个 suite 共 35 项通过（首次 PDFium 下载超时，补构建进程代理后通过）。已备份安装版 JAR/checksums 并替换 JAR，只停止已核身份的 Mihon 子进程让主应用重新拉起。原始 Rawkuma UI 列表、封面与搜索均恢复，日志确认公网 HTTP 200，原代理错误消失。指定漫画下载验收另记。
- **安全复核**：宿主 token、URL 验证、HTTP 策略失败关闭和代理凭据作用域不变；仅 `socket` 分支不再重复路由。verify-security 脚本未支持 Kotlin（扫描 0 文件），不计作安全通过；以上边界以人工 diff 和实际代理回归测试复核。
- **指定作品复测**：用户安装版通过 Rawkuma 搜索 `shuu ni` 找到 `Shuu ni Ichido Classmate wo Kau Hanashi`，详情显示作者 HANEDA Usa、匹配封面及 15 个章节。随后用户物理 Escape 停止 Computer Use，加入书架操作未执行，下载/离线阅读未验证。
