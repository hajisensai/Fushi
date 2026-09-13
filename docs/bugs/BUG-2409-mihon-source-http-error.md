## BUG-2409 · Mihon 保留源站HTTP错误状态并区分桥接失败
- **报告**：2026-09-10（用户：源站502不应被包装成BRIDGE_HTTP_500。）
- **真实性**：✅ 真 bug。DalvikHandler.errorResponse只保留少数4xx，HttpException(502)被降为桥接500；DesktopMihonRuntime._postJson又仅按transport状态生成BRIDGE_HTTP，忽略响应里的源站类型/状态。真实カドコミ日志含源站502→UI桥接500。
- **[x] ① 已修复** — JVM保留类型化源站HTTP400..599原状态并附errorKind/sourceStatusCode；Dart按结构化来源生成SOURCE_HTTP_n，兼容旧版HttpException类型+code，桥接内部失败仍用BRIDGE_HTTP_n。非JSON失败响应保留HTTP分类，完整栈保留在details。
- **[x] ② 已加自动化测试** — DalvikErrorResponseTest覆盖来源403/429/500/502/503/599、内部异常和非法状态；desktop_mihon_error_response_test覆盖新版/旧版协议、伪HTTP文本、非法字段、非JSON；运行时集成通过真实子进程+HTTP响应fixture验证分类及失败后进程不变。
- **验证**：Dart定向7项（含3项实际启动Java运行时的测试）通过、0跳过；Kotlin完整JVM44项、0失败/0跳过，lint与shadowJar通过；`flutter analyze --no-pub`通过（No issues found）。
- **范围**：本修复针对桌面漫画元数据/搜索桥接错误归因，不修复外部站点502/403本身；不从异常消息字符串猜测来源。主应用需包含Dart改动的新构建才显示SOURCE_HTTP分类，本轮未替换用户主程序。
