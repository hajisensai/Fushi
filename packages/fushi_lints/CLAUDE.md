# fushi_lints

仓库自己的 analyzer 插件（`analysis_server_plugin`，Dart 3.10 起的官方插件机制）。把「纯语法 / 纯 import / 纯调用形状」的代码不变式写成 lint 规则，随 `flutter analyze` / `dart analyze` 与 IDE 一起报，取代 `fushi/test` 下读源码文本的守卫测试。

## 怎么生效

- 挂载点：`fushi/analysis_options.yaml` 与 `packages/{fushi_core,fushi_audio,fushi_engine,fushi_server}/analysis_options.yaml` 顶层的 `plugins: fushi_lints: path: ../…/fushi_lints`。规则一律 `registerWarningRule`，挂上插件即全部生效，不用逐条打开。
- 分析服务器会把本包当路径依赖装进 `~/.dartServer/.plugin_manager/<hash>/` 并自己 `pub get`（跟 workspace 的 lock 无关），**需要能访问 pub.dev 或本机 pub 缓存里已有对应版本**。装不上时分析器不报错、只是没有插件诊断（静默变绿），改了依赖版本后先在本机跑一次 `dart analyze` 确认诊断能出来。
- 改了规则后 IDE 要重启 Dart Analysis Server 才会加载新代码。
- `analysis_server_plugin` 的版本由当前 SDK 的分析服务器决定（Dart 3.14 生成的入口写的是 `^0.3.21-dev`）；它和 `analyzer_testing` 都把 `analyzer` 钉成精确版本，升级 Flutter 时三者一起挪，workspace 里 build_runner 一族也跟着同一个 `analyzer`。

## 加一条规则

1. 在 `lib/src/rules/` 写一个 `RatchetedRule` 子类：`appliesTo`（作用域，按仓库相对路径）、`collect`（按 AST / element 找命中，**判静态类型或解析出的元素，不判名字字面量**）、`allowances`（现存违规的精确豁免）。
2. 在 `lib/src/rules.dart` 的 `fushiRules()` 里登记。
3. 在 `test/` 写 `FushiRuleTest` 子类的单测：正例、反例、豁免恰好用满、超额、过期各一条。`allowance_table_test.dart` 会核对每条豁免指向的文件真实存在、在作用域内、带理由。
4. 删掉它取代的文本守卫与只为它存在的说明，并改掉引用旧守卫的注释 / 文档。

## 豁免（棘轮）

- 豁免是 `Allowance(仓库相对路径, kind, 个数, 理由)`，写在规则源码里，**不用 `// ignore:` 在业务代码里铺**。
- 某文件某 kind 的命中数多于登记数：这个文件该 kind 的每一处都报（新增即红）；少于登记数：在文件头报 `<规则名>_stale_allowance`，把数字调小或删行。所以豁免只减不增。
- 「组件实现层」这种本职就要构造原控件的位置（例如设计系统包装目录）不走豁免，在规则里按前缀声明，不计数。

## 规则管不到的

单个库之外的不变式（跨文件注册一一对应、i18n 引用、YAML / CMake / pbxproj 等非 Dart 文件）不做成 lint；它们应由登记源生成，或留作文本守卫。

## 测试

`dart test`（CI 的包测试 runner 用 `flutter test` 跑同一批文件）。
