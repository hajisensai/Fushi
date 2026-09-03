## BUG-2070 · KiriKiri Z + wuopus 语音（ATRI）整句音频恒降级为系统混音
- **报告**：2026-09-03（ceshi 批量适配：ATRI -My Dear Moments- Steam 版，KiriKiri Z 1.2.0.3，`plugin/wuopus.dll` + `wuvorbis.dll`，exe SHA-256 `4705821E76FC9A1B275C719D5ECD2C700ED58DA9779EEBDF1E390D53A58A48E3`，x86，DARKSiDERS Steam 模拟）
- **真实性**：✅ 真 bug（适配缺口，未定根因）。真机：Fushi 2.2.4-debug.13075 从库内启动（早注入、已转区 CP932、音频模式「游戏资源音频」），TextRender 线程正文正常、游戏内单击查词弹卡正常、点卡外关闭不推进；但 75 条台词里 74 条「有音频」全部是 `system_loopback · 5.00s · engine_utterance_unavailable`，包括アトリ的有声台词「……はい」——资源流（`kirikiri_resource_stream`）没有配对到语音文件，引擎 PCM 也没切出本句 utterance。活跃音轨面板只有两条 DirectSound 轨：44.1 kHz 一条连续（BGM）、48 kHz 一条稀疏且「这句时刻没有声音」。制出的卡（note 1788380145993）SentenceAudio 是 5 s 混音。yaml 里 `kirikiri_z` 的 verified 样本是 wuvorbis（OGG）游戏；ATRI 语音走 Opus（wuopus），资源分类 / 解码回调 hook 很可能只覆盖 vorbis 边界。
- **[ ] ① 未修复** — 需要 native 侧（`native/galgame_hook/hook/adapters/kirikiri_adapter.inc`）核实：TVPCreateIStream 资源事件对 `.opus` 条目的分类、wuopus 解码回调是否被当作 PCM 来源、48 kHz 轨为何在语音时刻无段。按「一引擎一任务、一独立 worktree」另开。
- **[ ] ② 未加自动化测试** —
- **备注**：同一局观察到的另一个现象（Ctrl 快进时多句被折成一条超长台词）与本条无因果关系，已按「一 bug 一文件」拆到 **BUG-2078**，那边同时把「根因已定」下调为「现象已观察、根因未定」——本轮没抓到快进期间的原始快照序列，分不出是引擎发累积串还是折叠判据误判。
