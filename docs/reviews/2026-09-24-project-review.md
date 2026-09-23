# 2026-09-24 PR #1626 审查

## Scope

- 上游：`hajisensai/hibiki#1626`，作者 `W1ght`，目标 `develop`。
- 审查提交：`bc11e911179b2b4816d7dfa26beff8f4bd727e7b...762be5b89fcbf7fcbec96720caece3409ef7440e`，71 个文件。
- 分工：托管 CUDA 安装/资产/子进程/取消；非 CUDA 预处理/识别/批处理；模型设置/缓存/任务调度/服务生命周期；主审复核集成、CI、测试和发现的可达性。
- 测试在独立 worktree `codex/review-pr-1626` 执行。真机性能和准确率仅引用 PR 中已有证据，本轮不把它们写成重新实测。

## Findings

### HBK-AUDIT-001：非本地引擎下的 CUDA 导入安装状态被隐藏

- severity：P2。
- status：两条 widget 行为测试已复现并修复；27 项 UI 测试通过。
- 位置：`fushi/lib/src/media/manga/manga_ocr_settings_section.dart:896` 的 `_buildLocalModelArea`、`:1126` 的 `_deleteButton`。
- 根因：完整导入刷新了 `hasAnyFiles` 后启动安装，但非本地引擎的已有文件分支优先展示闲置模型区，活动安装状态只在无文件分支得到处理；删除按钮也没有安装/导入互斥条件。
- 影响：默认 Google Lens 下预备 CUDA 模型时，安装进度与取消入口不可见，删除入口仍可对安装目录操作。
- 修复建议：活动下载/安装先于引擎与磁盘状态决定展示区；文件操作互斥直到取消完成。
- 验证方式：widget 测试驱动完整 CUDA 导入，保持安装 stream 活动，断言进度可见、取消可操作、清理确认前删除不可用、清理完成后退出安装态；另一条覆盖导入未完成期间删除禁用。测试通过显式取消清理 Future 验证异步互斥契约。

### HBK-AUDIT-002：提前抑制嵌套框会丢失小字号正文

- severity：P2。
- status：受控推理输出复现并修复，单框/批处理及组合回归通过；未据此推断真实漫画中的发生频率。
- 位置：`packages/fushi_engine/lib/ocr/text_detector.dart` 的 `applyClassAwareNms`；`routing_ocr_recognizer.dart` 的 `_recognizeHorizontalBlock`。
- 根因：新增的几何包含抑制在识别前删掉小框，假定父段落的 PP 切行会覆盖所有文字。但既有 `filterThinLines` 按块内 p75 行厚度过滤振假名，也会过滤与大标题共处一框的小字号正文；标题非空使整框 fallback 不触发。
- 证据：同一套 detector/line session 输出经过真实 `TextDetector → MangaOcrPipeline → RoutingOcrRecognizer`，基底输出 `TITLE` 和 `BODY`，PR 输出只有 `TITLE`。纯 Dart 复现与结果位于 `.codex-test/algorithm-pr1626/`。
- 修复建议：保留低 IoU 子框的识别机会，在识别结果层同时要求几何包含、较高父框分数及完整文本覆盖后去重；不放宽既有振假名过滤。
- 验证方式：组合行为回归、文本覆盖与不覆盖的正反例，以及单框/批处理路径。
- 实施：`manga_ocr_pipeline.dart:69` 在识别后删除已被完整文本覆盖的内框；经典、Baberu、CUDA 三种模型缓存均包含共同的 `v4-antialias-text-dedup` 修订，避免继续读取旧的漏字结果。

### HBK-AUDIT-003：非 8 位灰度页缺少全管线归一化

- severity：P2。
- status：既有问题，本轮不作为新增回归；后续需在共同页图入口统一修复。
- 位置：`packages/fushi_engine/lib/ocr/manga_ocr_folder_job.dart` 的 `decodeMangaPageFile`，以及 detector/识别预处理。
- 证据：真实 PNG 编解码后运行生产页加载路径，1/2/4 位灰度白色仍为 1/3/15，基底检测张量和经典识别张量已经按 255 归一化错误；本 PR 的 Baberu 同样受影响。8 位对照正常。16 位输入的检测张量在基底也越界。
- 边界：这不是本 PR 引入的首次失效，原 PR 的 BUG-2643 已明确未覆盖低位深/16 位非索引 PNG。测试固定文字区域用于观察识别输入，另直接检查真实 detector 预处理张量；没有使用真实 ONNX 推理宣称准确率。

### 安装器候选问题复核

- 撤回“重装失败后旧 runtime 未保留”的 P2 定级：此前只证明没有回滚，未证明会损失仍能通过应用门控的可用安装。正常已就绪安装直接返回；模型修复/worker 更新复用 runtime，不走删除旧目录分支。`_runtimeInstalled == false` 对应 marker、环境指纹或必需文件失效，且应用启动 OCR 前统一检查 ready。环境指纹不受用户模型偏好或普通导入改变影响。它仅保留为未来运行库升级的恢复性建议，本次不作为阻塞项。

## Verification

- 原 PR 与最终修复后的全量 `flutter analyze --no-pub` 均通过，0 issue；最终日志为主 checkout `.codex-tmp/pr1626-ready-analyze.log`。
- `git diff --check upstream/develop...HEAD`：通过。
- 按变更映射与相邻场景选定测试，共覆盖 537 个不同测试文件；同一文件以最后完整运行结果计数，4,678 通过、4 跳过、1 项既有失败，无缺失或空 suite。唯一失败为 `settings_schema_coverage_test.dart` 的 `interconnect/Allow remote launch` 效果探针登记；原作者已在未含该 PR 的 `5511e4e0561` 复现，且本轮未修改相关功能。
- 修复后 OCR/设置专项覆盖 32 个文件、398 项通过（31 个文件 371 项与 UI 单文件 27 项串行验证）。原始 JSON 与汇总位于独立 worktree `.codex-test/pr1626-*`；主 checkout `.codex-tmp/pr1626-*` 保存命令结果。
- 合并后另在合并提交上执行 52 个目录枚举守卫文件，结果保存在 `.codex-test/pr1626-postmerge-guards-{1,2}/`，该步骤不复用合并前的结果。
- 复核已有 Windows CUDA 真机证据：原工作树的 `fushi/.codex-test/windows-itest/manga-cuda-real-pages-20260923/command.log` 明确记录 `OCR_REQUIRE_CUDA=true` 与 `+2: All tests passed!`；页报告记录 `MangaOcrAcceleration(CPU/CUDA)`。此证据对应原 PR，不能充当本轮去重修订的真机复测或速度证明。
- 原 PR CI 的 Linux torrent FFI 测试失败：`embedded_pipeline_test.dart:336` 的 `ip_filter blocks the seeder...` 期望 peer 下载字节数大于 0，实际为 0（34 通过、1 失败）。该测试、`packages/fushi_torrent`、`native/fushi_torrent`、工作流及依赖锁文件在本 PR 中均无差异；记录为与改动无关的未解决 CI 失败，不宣称 CI 全绿。日志：主 checkout `.codex-tmp/pr1626-ci-linux.log`。
- 原 PR 的 Android、iOS、macOS、Windows 构建、作者门和 Sonar 检查通过；完整 app 单测工作流尚未结束。修复提交将重新触发 CI，不能用旧提交的绿灯代替新提交结果。

## Next Scope

- 非 8 位灰度页的共同入口归一化；修订后整页性能与更大漫画样本真机复测。
- 继续跟踪独立的设置探针登记和 Linux torrent CI 失败，不将它们归因于此次 OCR 修订。
