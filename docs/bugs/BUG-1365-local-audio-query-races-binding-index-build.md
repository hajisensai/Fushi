## BUG-1365 · 桌面本地音频查询与绑定期建索引竞态：撞锁被吞成 null＝「暂无发音」（CI flaky）
- **报告**：2026-08-02（用户：看板 TODO-2514，APK 门偶发红）
- **真实性**：✅ 真 bug（功能真坏，不是判据坏；只改生产代码即可稳定绿，测试断言一个字没动）。

  CI 现场（run `30686295664`，headSha `2703ef22eb`，Build Release APK / Run unit tests，16382 tests completed）：

  ```
  desktop TtsChannel local-audio behavior (real sqlite via Isolate.run) queryLocalAudio honors dbIndex bounds
    Expected: not null
      Actual: <null>
    test/utils/misc/local_audio_query_offload_test.dart 191:7
  ```

  根因链（全在生产代码里）：

  1. `hibiki/lib/src/utils/misc/tts_channel.dart:88` —— `setLocalAudioDbs` 对每个库
     `unawaited(LocalAudioDb.ensureIndexes(cfg.path))`。那是**我们自己**对同一个库文件开的
     `OpenMode.readWrite` 连接（`hibiki/lib/src/utils/misc/local_audio_db.dart:146`），跑两条 `CREATE INDEX`。
  2. `hibiki/lib/src/utils/misc/tts_channel.dart:129` —— `queryLocalAudio` 与那个写连接**完全无序**：
     绑定一返回就能发查询，两条连接在同一 inode 上抢锁。
  3. `hibiki/lib/src/utils/misc/local_audio_db.dart:193` —— 只读连接只有
     `PRAGMA busy_timeout = 3000` 这一道赌注；`CREATE INDEX` 提交阶段持独占锁，赌输就 `SQLITE_BUSY`。
  4. `hibiki/lib/src/utils/misc/local_audio_db.dart:229` —— `queryMeta` 的
     `catch (e, stack) { ...; return null; }` 把 BUSY 吞成 `null`，与「库里真没这个词」完全同形。
     用户侧＝查词「暂无发音」；CI 侧＝上面那条 `Expected not null`。

  两条本地实测证据（Windows，`flutter test`）：

  - **无序窗口 100% 存在**：20 万行库，绑定后立刻查询，查询返回时 `idx_entries_expr_read`
    尚未建出 —— 修前 **6/6 轮**命中该窗口。
  - **撞上就必吐 null**：让一个写者持有 EXCLUSIVE 5s（＝真实十万行库上 `CREATE INDEX` 提交的量级），
    生产 `TtsChannel.queryLocalAudio` 在 3153ms 后返回 `null`，报错形态与 CI 逐字一致
    （`Expected: not null / Actual: <null>`）。

  注：CI 那次红是 1 行 tiny DB 上的偶发，需要写者在提交窗口被调度器拖住；本机 Windows
  20 次顺序跑 + 320 轮争用跑都没自然撞出（负载敏感，且 Linux POSIX 锁语义与 Windows 不同）。
  因此本条按「无序契约」定性与修复，而不是按时间赛跑修。

- **[x] ① 已修复** —— `hibiki/lib/src/utils/misc/tts_channel.dart`：`queryLocalAudio` /
  `extractLocalAudio` 在把查询交给 `Isolate.run` **之前**，先
  `await LocalAudioDb.waitForPendingIndexing(<该库路径>)`，把读端确定性地排在自家 in-flight 写端之后。
  用的是 `ensureIndexes` 早就发布的 per-path 完成信号（`local_audio_manager.dart:286` 删库前已在用同一个原语），
  **没有加延迟、重试、sleep 或特例分支**；无在途任务时是一次立即完成的 Future，零额外成本。
  `setLocalAudioDbs` 仍保持 `unawaited`（绑定不阻塞）。

- **[x] ② 已加自动化测试** —— `hibiki/test/utils/misc/local_audio_query_offload_test.dart`：
  - 行为守卫 `BUG-1365: queries are ordered after our own index build` →
    `queryLocalAudio does not return while indexing is still in flight`：20 万行库绑定后立刻查询，
    断言查询返回时索引**已经**建好。变异实测：把 `await Future.wait([... waitForPendingIndexing ...])`
    换成 `await Future<void>.value()` 后，该用例是**唯一**变红的（`Expected: true / Actual: <false>`），
    源码守卫仍绿 —— 说明行为守卫不与字符串守卫重复。
  - 源码守卫 `desktop queryLocalAudio / extractLocalAudio waits out the binding-time index build`：
    两处方法体必须含 `LocalAudioDb.waitForPendingIndexing(`，且其位置必须早于 `Isolate.run(`（等在后面等于没等）。

- **备注**：残留边界 —— 弹窗词典跑在**独立 isolate**，`_pendingIndexing` 是 per-isolate 静态，
  跨 isolate 的「A isolate 建索引 / B isolate 查询」仍只有 `busy_timeout` 兜底。这是本次修复之前
  就存在的行为，未扩大；要根治需把在途登记提升到跨 isolate 共享（或让绑定只发生在主 isolate），另开条目。
