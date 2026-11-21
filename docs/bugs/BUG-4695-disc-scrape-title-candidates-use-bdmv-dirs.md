## BUG-4695 · 原盘作品拿 `PLAYLIST` / `BDMV` 和带卷标的盘名去搜，换回一屏无关候选
- **报告**：2026-11-15（用户：待确认列表里三张原盘各有 31～40 个候选，「AI 判断不够确定」）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/video/metadata/video_source_scrape_coordinator.dart` 的 `videoScrapeTitleCandidates` 对所有文件一律取「作品标题 + 文件名解析 + 父目录 + 祖父目录」。原盘成员是 `<盘根>/BDMV/PLAYLIST/00001.mpls`，父 / 祖父目录恒为 `PLAYLIST` / `BDMV`；作品标题是 `魔女の旅々　上巻 - 02`（带卷标和标题序号）。真正带作品名的发布目录 `Majo no Tabitabi [BDMV]` 在盘根 `Disc 1` 再往上一层，从不进候选。运行记录（run 3793）：40 个候选，AI 判对了（TV 版）但置信度 0.80 < 0.85，没自动采用。另一处：单标题盘的作品形态按文件名 `00001.mpls` 解出的「集号」猜，与盘的实际结构无关。
- **[x] ① 已修复** — 原盘标题的候选改为：盘名去掉 ` - NN` 序号、再去掉尾部卷标（`上巻` / `下巻` / `第N巻` / `Vol.N` / `Disc N`，`前編` / `後編` 是片名不剥），以及盘根往上第一层不是 `Disc 1` / `BD` / `BDROM` 这类介质目录的发布目录名（去掉外层书名号）；不再取 `PLAYLIST` / `BDMV`。单标题蓝光盘的形态看播放列表本身（`blurayPlaylistLooksEpisodic`：串着 ≥ 2 段各 ≥ 10 分钟、时长相近的片段 = 剧集，否则电影）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/metadata/video_scrape_title_candidates_test.dart`（原盘候选三例，两种分隔符）；`fushi/test/media/video/bluray_disc_test.dart`（「串着几集的播放列表判剧集形状」）。
- **备注**：用户真盘实测候选：`[魔女の旅々, 魔女の旅々 上巻, 魔女の旅々　上巻, Majo no Tabitabi, Majo no Tabitabi [BDMV]]`。AI 自动采用门槛 0.85 没动——候选干净之后离线标题索引就能唯一精确命中，不需要靠降门槛。同一发布的多张盘（上巻 / 下巻）目前仍是两个作品单元，各自绑到同一部作品。
