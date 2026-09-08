## BUG-2265 · 安卓查词发音库把 SAF 缓存副本当成原文件引用

- **报告**：2026-09-08，用户转述 Android 有声书页面查词单词无声，昨晚正常，更新后显示「暂无发音」。有声书正文播放不是本次故障。
- **真实性**：真 bug，截图与真实代码路径相符；未取得用户设备文件存在性、日志与更新前后版本，不能断言更新动作删除了缓存。
- **截图证据**：单词 disgust 查词显示「暂无发音」；管理音频来源中 android_english.db 开启，但持久引用路径为 `/data/user/0/app.fushi.reader/cache/saf_pick/android_english.db`。
- **根因**：
  1. `fushi/android/app/src/main/java/app/fushi/reader/MainActivity.java:371`：SAF 无法解析原路径时回退 `copyUriToCache`，仍将裸字符串返回 Dart。`:1373` 明确写入 `getCacheDir()/saf_pick`。
  2. `fushi/lib/src/media/import/real_path_directory_picker.dart:182` 与 `:192`：SAF 分支无条件标记 `isRealPath: true`，丢失临时缓存出处。
  3. `fushi/lib/src/settings/settings_schema_lookup.dart:862` 按该标记允许引用；`fushi/lib/src/models/local_audio_manager.dart:226` 在引用模式直接保存传入路径，未复制到持久库目录。
  4. `fushi/lib/src/models/local_audio_manager.dart:337`：启动时文件缺失则跳过绑定，设置仍保留已开启条目。缓存清理后可出现本地发音消失。
- **与 BUG-1667 的关系**：此前只防住未授权时 file_picker 的缓存回退；已有全文件权限的原生 SAF 本身也会回退到缓存，该分支漏判。现有 `fushi/test/tools/local_audio_import_real_path_guard_test.dart` 只检查源码存在 `isRealPath: false`，未覆盖该跨语言返回契约。
- **[x] ① 根因修复** — 本分支修复提交（见 Git 历史）：
  - Android SAF 文件结果改为 `{path, isRealPath}`；目录契约保持字符串。Dart 严格解码，过滤扩展名也保留出处，临时副本由既有导入路径复制到持久库。
  - 主入口与弹窗入口绑定前迁移本机实际临时目录下的旧库；复制成功后以短事务 CAS 同步替换两份偏好路径，保留顺序、开关、子来源和名称。配置在复制期间变化则保留新配置。原文件不删除，失败记录诊断并保留恢复入口。
  - 迁移和孤儿清理共用进程内队列与跨进程文件锁；清理在锁内读取最新持久配置，防止删除正在迁移或刚提交的库。文件名保留数字形状并加入进程 ID，隔离主进程与 popup 的同毫秒命名。
  - 缺失库显示本地化提示和「重新选择发音库」，恢复时复制持久副本并保留原行顺序/开关/名称/子来源；取消或选择失败不替换。
  - Dart 与 Android native 绑定保留缺失库的序号槽位；空配置也清除旧绑定，防止后续正常库错位及 warm popup 使用已移除库。
- **[x] ② 自动化测试** —
  - `fushi/test/media/import/saf_file_provenance_test.dart`：真实/缓存返回、扩展过滤、取消、损坏契约及原生接线。
  - `fushi/test/models/local_audio_cache_reference_migration_test.dart`：真实 SQLite 迁移、缓存清除、幂等、失败回滚、并发配置修改与迁移/清理互斥。
  - `fushi/test/models/local_audio_binding_slots_test.dart`：缺失首库不挤序号、关闭与移除后清空旧绑定、原生槽位契约。
  - `fushi/test/pages/audio_sources_missing_file_test.dart`：缺失提示、重选成功/取消/失败、异步期间排序与开关变化。
  - `fushi/integration_test/local_audio_cache_recovery_itest.dart`：Android 实际查询、BLOB 字节比对、WAV 启播、清源缓存后重载及旧引用迁移（执行结果见验证记录）。
- **临时恢复**：重新选择原始 android_english.db，关闭引用原文件（不复制）选项，复制入应用持久库目录。沿原设置重新导入可能只重造缓存并再次复发。此建议尚未在报告用户设备执行验证。
- **验证边界**：已读取两张原图并沿 Java → Dart → 导入 → 重启绑定复核。最终自动化、构建及设备结果见下方；未取得报告用户设备日志，不能断言更新动作清除了缓存。

### 本轮验证记录
- 首轮定向 86 条通过。
- 扩展定向覆盖 243 条：242 条通过，一条既有 Windows 测试清理因后台索引占用文件失败；补齐清理等待后，该文件 18 条重跑全部通过。未运行本地全量套件。
- 全量 `flutter analyze --no-pub`：零问题。
- `dart tool/bug.dart check`：号唯一、索引同步、无跨工作区撞号。
- Android `:app:assembleRelease`：因缺少本地 `android/key.properties` 被发布签名门阻止，未绕过签名。
- Android 平台测试首次零用例启动失败：Flutter 在未生成 APK 时不识别当前 launcher activity-alias；继续先构建 debug APK，再执行平台测试。最终结果待补。
