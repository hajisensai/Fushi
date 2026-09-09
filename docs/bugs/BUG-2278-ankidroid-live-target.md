## BUG-2278 · AnkiDroid识别与API实例缓存导致安装或启用后仍无法连接
- **报告**：2026-09-08（用户：已安装 AnkiDroid，新手引导「测试连接」仍报不可用，要求根治缓存）
- **真实性**：✅ 真 bug。`fushi/android/app/src/main/java/app/fushi/reader/AnkiDroidTarget.java:110` 的旧实现把首次 PackageManager 查询（包括 null）永久缓存，且没有调用方使缓存失效；安装、卸载或启用外部 API 不保证重启 Fushi。`fushi/android/app/src/main/java/app/fushi/reader/AnkiDroidHelper.java:28` 的旧实现又在构造时固定 provider，使后续操作继续使用 null 或旧安装实例。真实生产 Java 配合可变 PackageManager 边界回放，旧版本三个状态转换场景均触发 AssertionError。
- **[x] ① 已修复** — 删除解析结果缓存和手动失效入口；每次解析重新查 PackageManager。Helper 不保留 provider 字段，每个查询操作获取当前 provider，并在该操作内复用同一个局部实例。提交：见本文件所属修复提交。
- **[x] ② 已加自动化测试** — `fushi/test/android/ankidroid_live_target_test.dart`：真实生产 Java 的同进程不可用→可用→不可用、并行版→主包→并行版、禁用→启用三个行为场景，以及 Helper 不保留旧 provider 的守卫；旧版三个行为场景均失败，修复版均通过。
- **备注**：设备原始路径尚未复测（ADB 无连接设备）；JVM 测试模拟 Android PackageManager 边界，不等同真实手机授权端到端验证。
- **验证**：`flutter test test/android/ankidroid_live_target_test.dart test/android/ankidroid_parallel_build_guard_test.dart --no-pub` 退出 0、13 项通过；`flutter analyze --no-pub` 无问题；完整 JDK 21 下 `:app:compileDebugJavaWithJavac` 退出 0。Release Java 编译因缺少 `android/key.properties` 在配置阶段受阻，未出发布包。首次测试/Debug 编译的 SQLite 下载失败已通过当前进程代理解决；精简运行时缺少 RMI 的构建失败已通过完整 JDK 解决。
