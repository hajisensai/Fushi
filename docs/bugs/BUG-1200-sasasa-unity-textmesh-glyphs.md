## BUG-1200 · Sasasa Unity TextMesh 对白被拆成单字
- **报告**：2026-07-28（用户反馈：最悪なる災厄人間に捧ぐ捕获异常）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/adapters/unity_adapter.inc`
  的 Unity 文本安装被整套 AudioClip API 前置校验阻断，且旧 KEMCO 运行时实际把一句
  对白拆成多个 `UnityEngine.TextMesh.set_text` 单字调用。
- **[x] ① 已修复** — 文本能力与 AudioClip 资源能力解耦；补充
  `UnityEngine.UI.Text` / `UnityEngine.TextMesh`，并将以全角空格结束的 TextMesh
  字形批次合并为稳定的 `Unity TextMesh line` 文本线程。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/adapter_structure_test.py`
  守卫旧 Unity 类、文本先于音频安装、诊断位和字形合并边界。
- **备注**：真实 x64 样本经 Hibiki“启动并捕获”进入存档对白，环形日志从 154 个单字
  事件收敛到完整句子；同一会话再选择“当前游戏”外部窗口后，游戏 PID 与 injector PID
  均未变化。按任务要求未跑全量测试或全量构建。
