## BUG-5542 · Android 应用外查词卡（:popup）制卡到 Fushi 复习报 SrsCoreReadOnlyException

- **报告**：2026-11-27（用户：应用内反馈 cG0XybpnkA）
- **真实性**：✅ 真 bug（3.4.0 回归，复习库换代 gen4 引入）。根因
  `fushi/lib/src/models/app_model.dart` `initialiseForDictionaryPopup`（:popup / :second_screen 进程
  `_resetSrsStorageHost(isMainProcess: false)`）→ `fushi/lib/src/srs/srs_storage_host.dart` `_open`（非主进程按
  `SrsOpenMode.secondary` 只读打开 `srs4.db`）→ `fushi/lib/src/anki/anki_view_model.dart` `_readSrsMiner` 拿到的
  就是这个只读句柄，`SrsMiningAnkiRepository` 在它上面直接 `createNote` / `updateNote` / `deleteNote`，写命令在
  Rust 侧报 `READ_ONLY`（`native/fushi_fsrs/src/store/gen4/kernel.rs`）。只读是有意设计：拍板 D10
  （`docs/specs/2026-11-15-srs-gen4-g7-g11-plan.md:285`、`docs/specs/2026-11-11-srs-generation-break.md:998`）规定新代下
  弹窗进程只读、**弹窗里的制卡转交主进程**；转交这一半从未实现（全仓没有辅助进程 → 主进程的写入通道）。协议 3
  时代没有 Secondary，:popup 直接读写同一个库，所以 3.4.0 之前能用。:second_screen（第二块屏面板）同一条初始化路径，
  同样中招。
- **[x] ① 已修复**（方案 B，用户 2026-11-27 拍板：经绑定的 Service 同步转交主进程，体验不变）。只读不动，补上
  D10 的转交通道：
  - Dart：`SrsMiningAnkiRepository` 的写（制卡、覆写、回到出处改字段、撤回制卡）改经注入的 `SrsNoteWriter`，读
    （查重、同词反查、读字段、落点解析）照旧在本进程。主进程用 `LocalSrsNoteWriter` 直接写；只读打开复习库的
    Android 辅助进程用 `RelaySrsNoteWriter`（`fushi/lib/src/srs/srs_write_relay.dart`）：请求用待发队列 / 互联转发
    同一个打包器冻结（媒体读成字节写进 cache 目录下的转交文件，Binder 只带路径），连同本进程取定的配置副本
    （profile uid，含作品会话的配置）、复习落点、Anki 设置一起交给主进程；主进程的 `SrsWriteRelayHost` 按这两样
    取主进程自己的复习副本（`SrsProfileStores.minerFor`）、还原载荷、照本地制卡同一条路写，串行执行，结果
    （成功 / 重复 / 失败、句柄、牌组名、音频警告、换代分类码）原样带回——提示、覆写、撤回与主界面里一样。
    写成后主进程递增复习刷新信号（牌组列表 / 计数重读、本机推送照常）。
  - 原生：`SrsWriteRelayClient`（注册在 :popup / :second_screen 引擎上）以 `BIND_AUTO_CREATE` 绑定主进程的
    `SrsWriteRelayService`（不导出，Messenger 收发）；**主进程不在时绑定会把它拉起来**。`SrsWriteRelay`（主进程）
    把请求交给主界面的引擎（`MainActivity.configureFlutterEngine` 挂上，Dart 侧 `main.dart` 装处理器）；主界面不在
    （冷启动、主界面已被关掉而悬浮球等服务还撑着进程）时起一个无界面执行引擎（Dart 入口 `srsWriteHostMain`，
    `AppModel.initialiseForSrsWriteHost` 只开数据目录 / 主库 / 复习库 Primary / 偏好），空闲 60 秒交出主库并销毁。
  - 同一进程同一时刻只有一个 Primary：`SrsStorageHost` 加 `beforePrimaryOpen`，主界面的引擎开主库前调
    `claimPrimary`，原生先让无界面执行引擎做完手上的请求、关库、销毁才放行。
  - 失败不静默：主进程起不来 / 中途死掉 / 超时都回明确失败（「主应用中途退出，请确认卡是否已添加」等），不会
    退回只读报错或无反应。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_write_relay_test.dart`：同一测试进程对同一个库目录开 Primary
  （主进程）与 Secondary（辅助进程），传输换成同进程 JSON 往返。复现用例断言修前行为（Secondary 本地写 → 只读
  失败）；转交用例断言制卡在 Primary 写成、结果 / 句柄 / 牌组名 / 媒体都带回、辅助进程随即查重为真、转交文件
  用完即删、再挖判重复；覆写与撤回经转交生效；主进程库在换代途中带回分类码；传输失败明确报错；`MineOutcome` /
  落点编解码往返；`SrsStorageHost` 主进程开库前先等 `beforePrimaryOpen`、失败不缓存、辅助进程不等。
- **缺口**：没做真机复测（Android 悬浮窗 → 制卡 / 覆写；主界面在 / 不在 / 被划掉三种状态各一遍），原生两端
  （Messenger 绑定、无界面引擎的拉起与交接）没有自动化测试，合并前要在真机上走一遍。
- **备注**：与 BUG-5541（☆ 收藏）同报；收藏写的是 Drift 主库，:popup 可写，已单独修。主界面引擎被销毁时没有关它
  打开的 Primary 句柄（引擎直接销毁，Dart 不收尾），之后无界面引擎再开 Primary 时进程里留着一个闲置的旧句柄——
  这是 Activity 重建时本来就有的现状（新引擎同样再开一份），旧句柄不再收到任何命令，不会双写。
