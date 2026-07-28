## BUG-1201 · Sasasa Unity 资源音频已解码但未写入音频环
- **报告**：2026-07-28（用户反馈：游戏运行途中窗口消失，且音频获取不到）
- **真实性**：✅ 真 bug。`native/galgame_hook/injector/injector_main.cpp:531`
  的 `ExtractUnityVoice` 只验证解码后的 WAV 存在并设置资源诊断位，
  `ProcessUnityVoiceEvents` 没有把 WAV PCM、格式和 `VoiceClip` 索引发布到共享内存；
  真机探针因此同时出现“资源提取成功”与 `voice_clips=0 / total_written=0`。
- **[x] ① 已修复** — 在 injector worker 解析 RIFF/WAVE，按音频环容量和帧边界有界读取，
  通过原子预留写入主 PCM 环并最后提交 `VoiceClip.seq`；同时补齐旧 Unity 松散
  `resources.assets` 的资源提取运行时和“窗口出现前不调用 IL2CPP API”的生命周期门。
- **[x] ② 已加自动化测试** —
  `native/galgame_hook/tests/adapter_structure_test.py:144` 守卫 WAV 校验、容量/帧对齐、
  原子环写入、clip 完成标记顺序及提取成功必须提交 PCM 的契约。
- **备注**：按用户要求未跑全量测试或全量构建。真实 x64 游戏由 Hibiki“启动并捕获”，
  再从“选择目标窗口”绑定外部游戏；探针观察到对白资源 `09_leader1123` 产生
  504,576 字节、44.1 kHz/双声道/16-bit 的 5.72 秒 clip，Hibiki 将对应台词标成
  `game_resource · 音频就绪`，游戏进程保持响应。
