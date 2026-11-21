## BUG-4905 · 小说和漫画 AI 标注未应用系列用词替换表
- **报告**：2026-11-17（用户：用词替换应覆盖 AI 输入，随后明确页图中的对应文字也要改）
- **真实性**：✅ 真 bug（按用户本次明确的预期）：替换表原先仅供朗读/cue 输出使用；小说两遍提示词、漫画三遍提示词与页图上传路径没有消费系列替换表。
  - 根因：`fushi/lib/src/media/audiobook/tts/studio/tts_cast_annotator.dart:127` 的两遍请求只传原始 chunk；`packages/fushi_engine/lib/tts/manga_audio/manga_audio_annotate_runner.dart:244` 的角色提取、逐页与整场复核只传原始 OCR/台词；`fushi/lib/src/ai/ai_manga_audio_assistant.dart:156` 的页图准备只缩图/转码。
- **[x] ① 已修复** — 请求构造阶段套用同一张启用规则表；正文/OCR/上下文按最长优先一次替换，角色名字/别名/描述与上下文说话人也做请求投影；撞名/空名使用稳定临时 ID，回复恢复持久化角色与声音身份，不向 AI 发送原词对照表。结构化行号、坐标与枚举不替换。漫画上传副本在命中的整块 OCR 区域盖住旧字并重绘替换文本，支持横排/竖排、OCR 与实际像素尺寸差异、行多边形/字格外扩范围；Flutter 排字，Rust 一次合成与编码。源文件与手填 `say` 不改，替换失败不回发原图。提交见本文件 Git 历史。
- **[x] ② 已增加自动化测试** — `fushi/test/media/audiobook/tts/studio/tts_cast_annotator_test.dart`、`packages/fushi_engine/test/tts/manga_audio/manga_audio_annotate_runner_test.dart` 检查真实提示词/请求内容；`fushi/test/media/manga/audio/manga_audio_substitution_image_test.dart` 检查覆盖层与最终 JPEG 像素；`native/fushi_compute/src/image/composite.rs` 原生单测、`packages/fushi_compute/test/image_composite_test.dart` 真 FFI 契约测试。
- **验证**：小说提示词 33 项、引擎角色投影/漫画流程/相邻提示词 33 项；Rust 合成 7 项；FFI 与缓冲生命周期 5 项；Windows release DLL 构建及 132 项导出符号核对通过；页图像素 4 项通过。最终全量 `flutter analyze --no-pub` 在 self-mac 通过（exit 0，No issues found，快照 `e756e749b98d`）。
- **备注**：不属于阅读器排版/播放/导入变更。上传副本已用日文字体生成并肉眼核对（横排与竖排的「セーラー服」→「制服」），证据在本 worktree `.codex-test/substitution-images/source.png` 与 `upload.jpg`；未向真实 AI 提供商发付费请求。遮盖范围依赖已有 OCR；OCR 没识别到的文字不会凭空定位或改动。

- **基线已有守卫失败**：本次加跑的 5 个结构守卫共执行 27 项，26 项通过、`import_cycle_guard_test.dart` 的最大环上限一项失败（656 > 640）。按该守卫相同的 import/part/export 解析及 Tarjan 判据，对基线 `f1bf425db5fe48edbe32d0ebbec696847bf13b4e` 与修改后完整 `fushi/lib` 图比较，最大环均为 656，成员增减均为空；不是本次引入，未调大门槛。比较证据 `.codex-test/import-cycle-comparison.json`。
