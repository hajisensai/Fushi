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
- **[ ] ① 根因修复** — 本轮仅调查。应让原生选择结果明确携带真实文件/临时副本出处，临时副本必须转为持久副本；已保存缓存路径在文件尚存时迁移，文件缺失时明确引导重新选择原 DB。
- **[ ] ② 自动化测试** — 待补原生 SAF 回退缓存的行为测试、持久化后清理缓存仍可查询的回归测试。不能仅用源码字符串守卫证明契约正确。
- **临时恢复**：重新选择原始 android_english.db，关闭引用原文件（不复制）选项，复制入应用持久库目录。沿原设置重新导入可能只重造缓存并再次复发。此建议尚未在报告用户设备执行验证。
- **验证边界**：已读取两张原图、追踪 Java → Dart 选择器 → 本地库导入 → 重启绑定，并经独立只读复核；未运行 Android 真机/E2E，未修改运行时代码。
