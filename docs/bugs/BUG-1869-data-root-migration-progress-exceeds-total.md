## BUG-1869 · 数据迁移进度「已复制 623 / 620」超过总数：选择性搬移的顶层单文件只加分子不加分母
- **报告**：2026-08-25（用户截图「正在迁移数据 … 正在复制文件：623 / 620」）
- **真实性**：✅ 真 bug。跨盘复制进度由 `_CopyProgress` 累加：分母只在
  `_copyTreeVerified` 里 `addToTotal(await _countFilesAsync(src))` 按**子树**计入
  （`fushi/lib/src/storage/data_root_migrator.dart` 原 `_copyTreeVerified`），而 support 根走
  `_moveTreeSelective`（prefs 排除项 → `isSelective`）时，顶层**单文件**分支
  （原 `data_root_migrator.dart:535-545`）直接 `entity.copy` + `progress.fileCopied()`，从没把这
  个文件计进分母。用户 support 根顶层正是 `fushi.db` / `fushi.db-wal` / `fushi.db-shm` 三个
  文件 → 分子恰好多 3（623 / 620）；`local_audio_*.db` 等顶层大件同理。
- **[x] ① 已修复** — 顶层单文件分支先 `progress.addToTotal(1)` 再复制；同时把「copy + 字节数
  校验」抽成 `_copyFileVerified(src, dst, label)`，整树路径与顶层单文件共用一份校验口径
  （提交 `<hash>`）。
- **[x] ② 已加自动化测试** — `fushi/test/storage/data_root_migrator_test.dart`
  `BUG-1869：跨盘 copy 进度分子永不越过分母，收尾时 copied == total`：用 `seedDb`（support 顶层
  有 fushi.db + 侧车 + local_audio_1.db）+ 旧 support 顶层再放一个 `shared_preferences.json`
  逼出**选择性搬移**（没有它排除集为空、plan 走整树 copy，根本到不了出 bug 的分支——第一版
  测试就是这样在变异下假绿的）+ `debugForceCopyFallback` 强制跨盘 copy，断言每次回报
  `copied <= total`、末次 `copied == total`、且 `total == 搬移前旧根会被搬的真实文件数`。
  变异实测：注掉 `progress.addToTotal(1)` 该用例单独变红（`进度 6 / 5 分子越过分母`，与用户
  截图同形），按唯一锚点还原后 sha256 与改动前一致。
- **备注**：同盘 rename 路径不触碰进度对象（回调不会被调用），不受影响。
