# 符号索引（tool/symindex）

按名字查 Dart / Rust 符号的**定义和全部引用**，替代跨目录的 `grep -rn`。结果来自语义解析（Dart 走 analyzer，Rust 走 `rust-analyzer lsif`）：同名但无关的符号、注释和字符串里的同名文字不会混进来。

```bash
python tool/symindex/sym.py def  AppModel                 # 定义
python tool/symindex/sym.py refs anki_source_hlc          # 定义 + 全部引用（按文件归并行号）
python tool/symindex/sym.py refs build --in AppModel      # 同名多处时按所属类 / 模块收窄（--kind method 等也可）
python tool/symindex/sym.py find PressScale               # 名字子串模糊找
```

## 索引旧了怎么办：改动文件自动降级

索引建在 develop 上（记录 `base_sha`）。每次查询先算当前 worktree 相对 `base_sha` 改过的文件（已提交、未提交、未跟踪都算）：

- 没改过的文件：索引结果原样给出，行号准确；
- 改过的文件：其索引结果丢掉，改为在这些文件里**实时整词搜索**，标 `[live]`（未经语义解析）；定义落在改动文件里的标「行号可能已变」；
- 索引不存在、或 `base_sha` 在本仓找不到：整体降级成 `git grep -n -w`，第一行注明 `[降级]`。

所以索引晚几个小时也不会给出错误位置，只是改动文件里的结果退回 grep 的精度。

## 构建与定时刷新

- 索引位置：`%LOCALAPPDATA%/fushi-symindex/index.sqlite`（`FUSHI_SYMINDEX_DB` 可改）。
- 手动全量：`python tool/symindex/build.py --repo <checkout>`。2026-11-21 实测全仓 11.5k 个 Dart 文件 + 10 个 crate：24.7 万符号、195 万引用，15～25 分钟（Dart 8～17 分钟，随本机负载；Rust 约 7 分钟），heavy 记录的进程树峰值约 9.5 GB，索引约 80 MB。被索引的 checkout 必须已跑过 `setup_worktree.ps1`（否则 analyzer 仍报「解析成功」但跨包引用丢一半，`build.py` 发现缺 `package_config.json` / `strings.g.dart` 会直接失败）。
- 定时：`tool/symindex/refresh.ps1` 把专用 worktree `<主 checkout>/.worktrees/symindex` 拨到最新 `origin/develop`，develop 没动就退出；动了就跑 `setup_worktree.ps1` 解析依赖，再经本机重活租约（`fushi/tool/heavy.dart`）重建。`tool/symindex/install_task.ps1` 注册每小时一次的计划任务 `FushiSymindexRefresh`，日志在 `%LOCALAPPDATA%/fushi-symindex/refresh.log`。
- 单元测试：`python3 tool/symindex/symdb_test.py`（CI：`ci-config-gate.yml`）。

## 收录范围

- Dart：根 `pubspec.yaml` 的 workspace 成员；不收局部变量、参数、类型参数、import 前缀，不收生成文件（`*.g.dart` 等）里的声明。
- Rust：`native/*/Cargo.toml` 各 crate（仓库根没有 Cargo workspace，逐个 crate 跑 lsif；被别的 crate 依赖的会在依赖方里先收到，去重）；不收局部变量。
- 不收：C++（`native/fushidicts` 等）、Kotlin / Swift / JS。

## 为什么不用向量检索 / 常驻 LSP

见 2026-11-21 的评估：子代理成本里跨目录广搜约 10%，其中多数是按标识符找定义 / 引用，精确索引比语义向量更准；常驻 Dart LSP 每个会话约 6 GB、预热约 4 分钟，几个并发会话就吃光内存，所以改成定时建一份、所有会话共用。Rust 另有常驻 LSP 插件（每会话约 1.9 GB）可选。
