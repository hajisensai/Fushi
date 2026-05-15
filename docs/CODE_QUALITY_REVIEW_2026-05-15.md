# Hibiki 项目代码质量审查

审查日期：2026-05-15

范围：`D:\APP\vs_claude_code\hibiki`。本次只做静态审查和少量命令验证，没有修改运行时代码。当前工作区已有未提交改动：

- `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDictActivity.java`
- `hibiki/lib/popup_main.dart`
- `hibiki/lib/src/database/database.dart`
- `hibiki/test/database/search_history_test.dart`

## 核心判断

值得修。这里不是“代码风格不漂亮”这种空话，而是有几处真实的状态契约断裂：UI 写了状态但业务不读，删除只删内存不删数据库，异步设置写入被同步调用吞掉，静态分析信号被几千条噪音淹没。坏味道的根因是迁移后旧抽象没被拆干净，新路径又为了兼容继续挂在旧 key 上。

## 致命问题 1：字典导入格式选择是死 UI

品味评分：垃圾。

证据：

- `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart:696-705` 显示 `JidoujishoDropdown<DictionaryFormat>`，用户选择后只写 `last_selected_dictionary_format`。
- `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart:211-219` 调用 `appModel.importDictionary(...)`，没有把选择的 `DictionaryFormat` 传进去。
- `hibiki/lib/src/models/app_model.dart:2219-2222` 文件导入始终走 `importDictionaryViaHoshidicts(...)`。
- `hibiki/lib/src/models/app_model.dart:2285-2289` 持久化时 `formatKey` 固定写成 `'yomichan'`。
- `hibiki/lib/src/models/app_model.dart:1944-2011` 还有 `_detectDictionaryFormat()` / `_detectDictionaryFormatFromDirectory()`，但 `rg` 只找到定义，没有实际调用。
- `hibiki/lib/src/dictionary/dictionary_format.dart:27-37` 和各 `formats/*` 里保留 `prepareDirectory` / `prepareName` / `prepareEntries`，当前导入主路径不消费这些回调。

影响：

用户以为选择了 Migaku、Mdict、ABBYY Lingvo，实际导入路径不看这个选择。更糟的是数据库里所有导入结果都标成 `yomichan`，之后 `getDictionaryFormat(dictionary)` 会拿假格式渲染 UI。这个字段已经不是事实来源，是误导源。

修复方向：

二选一，别再两头骗：

1. 如果 HoshiDicts 已经统一接管格式识别，删除导入格式下拉、删除 `last_selected_dictionary_format` 状态、清理未使用的 Dart 旧格式导入接口，只保留展示用 `detectedType`。
2. 如果仍要用户指定格式，就把 `DictionaryFormat` 传进 `importDictionary()`，让 native importer 或 Dart fallback 真正按选择执行，并把真实格式写入 `Dictionary.formatKey`。

## 致命问题 2：`deletePreference()` 只删内存，不删数据库

品味评分：垃圾。

证据：

- `hibiki/lib/src/media/media_source.dart:155-165` 的 `setPreference()` 会写 `_preferences`，也会写 Drift `preferences` 表。
- `hibiki/lib/src/media/media_source.dart:168-171` 的 `deletePreference()` 只 `_preferences.remove(key)`，没有调用 `db.deletePref(_dbPrefKey(key))`。
- `hibiki/lib/src/media/media_source.dart:478-484` 的 `clearOverrideValues()` 依赖 `deletePreference()` 清除 override title。
- `hibiki/lib/src/media/media_source.dart:408-417` 读取 override title 时又从 source preferences 读。

影响：

清除媒体条目的 override title 在本次会话里看起来成功，重启或重新加载偏好后，旧值会从 Drift 表复活。典型“代码执行了但不生效”。这不是 UI 问题，是持久化契约坏了。

修复方向：

`deletePreference()` 必须和 `setPreference()` 对称：先删内存，再删除 `_dbPrefKey(key)` 对应数据库记录，并记录失败日志。已有调用方不需要各自补丁。

## 致命问题 3：阅读器设置同步是竞态，设置可能偶发不生效

品味评分：凑合偏烂。

证据：

- `hibiki/lib/src/reader/reader_settings.dart:64-71` 的 `_set()` 是异步数据库写入。
- `hibiki/lib/src/media/sources/reader_hoshi_source.dart:477-580` 的 reader setting setters 也返回 `Future<void>`。
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:2633-2653` 的 `_syncSettingsToHive()` 连续调用 `src.setTtu...()`，没有 `await`。
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:2655-2674` 的 `_syncSettingsFromHive()` 连续调用 `s.set...()`，也没有 `await`。
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:2585-2592` 在同步后立刻 reload reader。
- `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:846-850` 拦截 HTML 时还会 `_settings!.setTheme(appModel.appThemeKey)`，同样没有等待。

影响：

内存值会马上变，但数据库写入还没完成；紧接着 reload、profile switch、页面销毁或下一次初始化时，读到的是哪个状态取决于时序。阅读器设置、主题、字体、分页模式这类“偶尔没生效”的问题很容易从这里来。

修复方向：

把同步函数改成 `Future<void>`，批量 `await Future.wait([...])` 或串行等待后再 reload。更根本的做法是只保留一个设置所有者：Reader 页面使用 `ReaderSettings`，旧 `ReaderHoshiSource` 只做兼容迁移，不再双写。

## 致命问题 4：静态分析门槛已经失去信号

品味评分：垃圾。

证据：

- 执行 `D:\flutter_sdk\flutter_extracted\flutter\bin\flutter.bat analyze` 返回失败，输出 `2278 issues found`。
- 主要噪音来自 `analysis_options.yaml` 开了大量高噪 lint，例如 `public_member_api_docs`、`always_put_control_body_on_new_line`、`sort_pub_dependencies`。
- 同一轮分析还反复输出桌面插件声明警告：`file_picker` 的 linux/macos/windows default plugin 声明不完整，`wakelock_linux` / `wakelock_windows` 缺失。
- 搜索 `.github` / `ci` 没找到项目级 `flutter analyze` 门禁。

影响：

分析器现在不是质量门，是噪音发生器。真正的 error/warning 会被 2000 多条 info 和插件警告埋掉，CI 也无法靠它阻止退化。

修复方向：

先砍掉无收益 lint 或降级到局部规则，把 analyzer 目标改成“0 error / 0 warning / 可接受少量 info”。桌面平台如果不支持，就在平台配置上明确收敛；如果要支持，就升级/替换 `file_picker`、`wakelock` 路径。然后把 `flutter analyze` 加进 CI。

## 致命问题 5：仓库边界脏，源码审查被生成物和第三方测试淹没

品味评分：垃圾。

证据：

- `git ls-files docs` 有 3861 个文件，基本是生成的 API HTML。
- `git ls-files hibiki/android/app/src/main/cpp/hoshidicts_external` 有 3874 个文件，包含第三方库自己的 `.github/workflows`、tests、fuzz 数据等。
- 与之相比，`git ls-files hibiki/lib` 只有 264 个文件，`hibiki/test` 只有 25 个文件。
- `hibiki/android/app/src/main/cpp/CMakeLists.txt:17-20` 只需要第三方库作为 CMake 子目录构建，不需要把上游 CI、docs、tests、fuzz corpus 全塞进主应用仓库。

影响：

`rg --files`、审查 diff、代码搜索、归档体积都会被垃圾数据污染。更坏的是，第三方库自己的工程文件会混进项目搜索结果，导致审查人员误判当前项目行为。

修复方向：

把第三方 native 依赖改成 submodule、fetch script、vendor 最小化快照，至少删除不参与 Android 构建的 upstream `.github`、docs、tests、fuzz corpus。生成 API docs 不应该在源码主线长期跟踪，除非有明确发布流程。

## 使用问题：导入失败靠固定延迟展示错误

品味评分：凑合。

证据：

- `hibiki/lib/src/models/app_model.dart:2165-2170` 和 `2296-2301` 捕获导入异常后，把 `progressNotifier.value` 设成错误字符串，等 3 秒，再改成 `import_failed`，再等 1 秒。

影响：

这不是根因处理，而是 UI 时序补丁。错误状态被硬编码延迟控制，用户慢一点看不到原始错误，自动化测试也要等固定时间。导入失败应该是明确的状态模型，不应该靠睡眠维持可见性。

修复方向：

导入流程返回结构化结果：`running / failed(error) / complete`。Dialog 负责展示错误并让用户确认关闭，不要在 model 里睡 3 秒。

## 迁移残留：旧 `reader_ttu` key 兼容合理，但命名已经开始误导维护

品味评分：凑合。

证据：

- `hibiki/lib/src/media/sources/reader_hoshi_source.dart:30-39` 新类 `ReaderHoshiSource` 的 `uniqueKey` 仍是 `reader_ttu`。
- `hibiki/lib/src/media/sources/reader_hoshi_source.dart:51-53` book uid 仍拼成 `reader_ttu/hoshi://book/$bookId`。
- `hibiki/lib/src/reader/reader_settings.dart:8-12` 明确说明继续使用旧 `ReaderTtuSource` 的 Drift preference keys。

影响：

这部分兼容本身有理由，不能粗暴改掉，否则会破坏用户历史数据。但它需要被隔离成“legacy persistence key”，而不是到处让新 reader 继续表现得像 TTU。否则后续任何人改 source key 都可能破坏历史记录、profile、书签、音频设置。

修复方向：

把 `reader_ttu` 抽成 `legacyReaderPersistenceKey` / `legacyBookUidPrefix` 常量，并集中注释兼容边界。新业务命名用 Hoshi，旧持久化 key 只在转换层出现。

## 建议修复顺序

1. 先修 `MediaSource.deletePreference()`，这是小范围真 bug。
2. 清理字典导入格式 UI 和旧 `DictionaryFormat` 导入接口，避免用户继续被假选项骗。
3. 把 Reader 设置同步改成可等待的单一状态流，消灭双写竞态。
4. 收敛 analyzer 规则，让 `flutter analyze` 重新变成可用门禁。
5. 清理仓库边界，把生成 docs 和第三方无关文件移出主审查路径。

