## BUG-1452 · 未选择台词线程时仍显示正在监听与句级音频
- **报告**：2026-08-02（用户反馈）
- **真实性**：✅ 真 bug。`texthooker_page.dart:1875-1883`（修复前）仅按
  `state.isActive` 显示“正在监听”，并无条件拼入音频后端；
  `home_game_page.dart:249-253`（修复前）同样把活跃会话直接送进带音频信息的详情。
  两处都没有读取 `selectedTextThreadKey`，因此音频采集源就绪被错误等同为已有可归属的
  句级音频。
- **[x] ① 已根因修复** — `a483436e8`：新增统一的工作台 readiness 判定；引擎会话未选
  线程时显示“等待选择台词线程”，隐藏“本句音轨”和会话音轨入口。游戏启动后发现候选
  线程时弹出线程/音轨设置大弹窗，选中线程自动关闭，也可手动关闭。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/game_shared_readiness_test.dart` 覆盖未选/已选线程状态、WebSocket
  兼容路径、弹窗单会话去重，以及工作台/状态带/音轨入口对 readiness 的真实消费接线；
  `hibiki/test/pages/home_game_page_test.dart` 覆盖游戏顶部设置页签与诊断页的保留入口。
- **备注**：真实 Windows 游戏启动、LunaHook 线程发现及音轨试听尚未做设备验收；本 PR
  按用户要求只完成静态分析与聚焦自动化测试，能力状态为 `implemented_unverified`。
