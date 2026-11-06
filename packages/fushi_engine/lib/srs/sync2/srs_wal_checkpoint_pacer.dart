/// 收段（`SrsDbStore.sync2IngestBatch` / `sync2IngestFinish`）各片之后多久在写锁外并回一次 WAL。
///
/// 每片都并回（以前的做法）时，同一批热页（索引、投影表）每片都被拷回主库一遍：真实数据（65 万条操作）的
/// 新设备追赶里，前 6 段 173 次并回合计 17.9 s，占投递的 36%；每 8 片一次只要 3.0 s。整批都不并又会让 WAL 随
/// 片数涨到几百 MB（每读一页都要逐段查 wal-index，越读越慢）。
///
/// 这里按实测的增长定节奏：每次并回时内核回报 WAL 里的帧数（`log`），除以距上次并回投了几片，得到每片写多少页，
/// 下一次就攒到约 [targetPages] 页再并。目标取写连接自动 checkpoint 阈值（大批写入期间 16384 页）的一半，
/// 并回在写锁外完成，写连接自己不会在提交时并。第一片之后先并一次，用来量出每片的量。
class SrsWalCheckpointPacer {
  SrsWalCheckpointPacer({this.targetPages = 8192, this.maxEvery = 64});

  /// 两次并回之间 WAL 最多攒到的页数（缺省页大小 4 KB 下约 32 MB）。
  final int targetPages;

  /// 每片写得很少时最多隔几片并一次。
  final int maxEvery;

  int _since = 0;
  int _every = 1;

  /// 现在的间隔（片）。
  int get every => _every;

  /// 投完一片（之后还有）：返回这时要不要并回。
  bool afterSlice() => ++_since >= _every;

  /// 并回过一次，[logPages] 是内核回报的 WAL 帧数（`wal_checkpoint` 的 `log`）。
  ///
  /// 有读者挡着 WAL 回绕时 `log` 是累计的，估出来的每片量偏大，间隔只会变短（更勤地并），不会让 WAL 失控。
  void checkpointed(int logPages) {
    final int slices = _since == 0 ? 1 : _since;
    _since = 0;
    final int perSlice = logPages ~/ slices;
    _every = perSlice <= 0
        ? maxEvery
        : (targetPages ~/ perSlice).clamp(1, maxEvery);
  }
}
