import 'dart:math' as math;

import 'package:fushi/src/utils/misc/download_plan.dart';

/// 多来源分片下载的**选源账本**：记录每个来源的实测吞吐与失败，回答「下一片派给谁」。
///
/// 为什么需要它：分片下载器原来按 `(片序号 + 重试次数) % 来源数` 选源——片和源**静态
/// 绑定**。3 个来源、39 片，就是每个来源固定 13 片。哪怕 Cloudflare 比 GitHub 快三倍，
/// 慢的那 13 片也只能慢慢下，整包时长被最慢的来源决定；快来源的 worker 提前空转，
/// 回到队列取下一片时，那片仍然绑死在慢来源上。
///
/// 所以选源不能是**片的属性**，只能是**取片那一刻的运行时决策**：谁现在快，谁多拿片。
/// 本类就是那个决策的唯一依据，纯内存、不碰 IO，因此可以单测。
///
/// 三条规则，按序：
/// 1. **没测过的先测**。没有样本就没法比较；每个来源至少要拿到一次实测。样本过期
///    （[probeAfter]）也算没测过——开局慢的来源后来可能变快，不能被永久打入冷宫。
/// 2. **谁快派给谁**。有样本就取吞吐 EWMA 最高的。
/// 3. **但不许独占**。单来源在飞请求数有上限（见 [pick] 的 `perSourceLimit`），到顶就
///    退给次快的。这既是摊开带宽（多源并拉的总吞吐是各源之和），也是保住规则 1 的
///    采样机会——全部 worker 挤在一个来源上，别的来源就再也拿不到新样本了。
///
/// 失败的来源进冷却（指数退避），冷却期内不再派片。这一层是**跨片**的：下载器自身的
/// 重试退避只影响当前那一片，而一个来源挂了，别的片也不该再撞上去。
class SourceSpeedLedger {
  SourceSpeedLedger({
    this.smoothing = 0.3,
    this.minSampleBytes = 1 << 20,
    this.probeAfter = const Duration(minutes: 2),
    this.maxCooldown = const Duration(seconds: 16),
  })  : assert(smoothing > 0 && smoothing <= 1, 'smoothing 取值 (0, 1]'),
        assert(minSampleBytes > 0, 'minSampleBytes 必须为正');

  /// 新样本在 EWMA 里的权重。0.3 = 认过去、但一轮明显变慢/变快能在两三片内跟上。
  final double smoothing;

  /// 小于这个字节数的样本不计入吞吐。续传尾巴可能只有几十 KB，连接建立开销会把它
  /// 的「吞吐」算得极低，据此把一个好来源打成慢来源。
  final int minSampleBytes;

  /// 样本多久算过期。过期后该来源重新被当成「没测过」，拿回一次探测机会。
  final Duration probeAfter;

  /// 失败冷却的上限（指数退避封顶）。
  final Duration maxCooldown;

  final Map<String, _SourceStat> _stats = <String, _SourceStat>{};

  /// 当前在飞（已 [pick] 未 [release]）的请求数。
  int inFlightOf(String url) => _stats[url]?.inFlight ?? 0;

  /// 该来源的吞吐 EWMA（字节/秒）；还没有有效样本时为 null。
  double? speedOf(String url) => _stats[url]?.bytesPerSecond;

  /// 该来源当前是否在失败冷却中。
  bool isCoolingDown(String url, {DateTime? now}) {
    final DateTime? until = _stats[url]?.cooldownUntil;
    return until != null && (now ?? DateTime.now()).isBefore(until);
  }

  /// 挑一个来源并把它的在飞数 +1。**返回的来源必须配一次 [release]**。
  ///
  /// [exclude] 是本片已经失败过的来源（重试时排除）。[perSourceLimit] 是单来源在飞
  /// 上限。两个约束都是「尽量满足」——候选被排空时宁可重用，也不能返回 null 让一片
  /// 无源可下：候选表非空时本方法必定返回其中之一。
  DownloadSource pick(
    List<DownloadSource> candidates, {
    required int perSourceLimit,
    Set<String> exclude = const <String>{},
    DateTime? now,
  }) {
    if (candidates.isEmpty) {
      throw ArgumentError.value(candidates, 'candidates', '至少要有一个来源');
    }
    final DateTime at = now ?? DateTime.now();

    List<DownloadSource> pool = candidates
        .where((DownloadSource s) => !exclude.contains(s.url))
        .toList(growable: false);
    if (pool.isEmpty) pool = candidates;

    pool = _preferring(
      pool,
      (DownloadSource s) => !isCoolingDown(s.url, now: at),
    );
    pool = _preferring(
      pool,
      (DownloadSource s) => inFlightOf(s.url) < perSourceLimit,
      // 都到顶时不是随便挑一个，而是挑最闲的那个。
      fallbackKey: (DownloadSource s) => inFlightOf(s.url).toDouble(),
    );

    final DownloadSource chosen = _bestOf(pool, at);
    _statOf(chosen.url).inFlight += 1;
    return chosen;
  }

  /// 归还一次 [pick] 占用的在飞名额。
  void release(String url) {
    final _SourceStat? stat = _stats[url];
    if (stat == null) return;
    stat.inFlight = math.max(0, stat.inFlight - 1);
  }

  /// 记一次成功传输。[bytes] 是**本次实收**字节（不含续传前已有的部分）。
  void recordSuccess(
    String url, {
    required int bytes,
    required Duration elapsed,
    DateTime? now,
  }) {
    final _SourceStat stat = _statOf(url);
    stat.probes += 1;
    stat.consecutiveFailures = 0;
    stat.cooldownUntil = null;
    // 样本太小或计时器没走满一格，算不出可信吞吐——只清失败状态，不动速度。
    if (bytes < minSampleBytes || elapsed <= Duration.zero) return;
    final double sample = bytes / (elapsed.inMicroseconds / 1e6);
    final double? previous = stat.bytesPerSecond;
    stat.bytesPerSecond = previous == null
        ? sample
        : previous * (1 - smoothing) + sample * smoothing;
    stat.sampledAt = now ?? DateTime.now();
  }

  /// 记一次失败：进指数退避冷却，冷却期内不再派片给它。
  void recordFailure(String url, {DateTime? now}) {
    final _SourceStat stat = _statOf(url);
    stat.probes += 1;
    stat.consecutiveFailures += 1;
    final int shift = math.min(stat.consecutiveFailures - 1, 4);
    final Duration backoff = Duration(seconds: 1 << shift);
    stat.cooldownUntil = (now ?? DateTime.now()).add(
      backoff > maxCooldown ? maxCooldown : backoff,
    );
  }

  /// 单来源在飞上限：允许快来源占到大约 [shareFactor] 倍的均分额度，但**不许把并发
  /// 占满**。
  ///
  /// 均分（`并发 / 来源数`）会把慢来源也钉满场，尾巴被它拖住；完全不限则相反——两家
  /// 速度 100 与 99 时，快的那家每次都赢、占满全部并发，我们于是白白丢掉另一家将近
  /// 一半的带宽，而且它再也拿不到新样本，「后来变快」永远发现不了。
  ///
  /// 所以两头都要夹：份额取 [shareFactor] 倍均分，再封顶到 `并发 - 1`。
  /// 4 并发 2 来源 → 3；4 并发 3 来源 → 3；4 并发 4 来源 → 2。
  ///
  /// 封顶留的是**一条给别家整体**，不是「给每一家各留一条」。后者写成
  /// `并发 - (来源数 - 1)`，在 `来源数 >= 并发` 时恒 ≤ 1 —— 而那正是本模块最常见的
  /// 部署形状：清单切片线路每片的来源数是 `分片基址数 + 主 URL + 镜像数`，两个切片
  /// 基址 + 主 URL + 一个镜像就是 4，默认并发也是 4。上限塌成 1 之后选源退化成纯
  /// 轮转，「按实测吞吐把片派给最快的那家」这半个卖点在生产配置下等于没做。
  /// 留一条就够了：它保证的是「不会有人独占全部并发」——别家永远排得进去、拿得到
  /// 新样本，一家卡住也不会把整轮堵死。谁在剩下的名额里，交给冷启动与过期重探的
  /// 排序规则决定，不需要在这里再预留。
  static int perSourceLimitFor({
    required int concurrency,
    required int sourceCount,
    int shareFactor = 2,
  }) {
    if (sourceCount <= 1) return math.max(1, concurrency);
    final int share = (concurrency * shareFactor / sourceCount).ceil();
    return math.max(1, math.min(share, concurrency - 1));
  }

  _SourceStat _statOf(String url) =>
      _stats.putIfAbsent(url, () => _SourceStat());

  /// 满足 [test] 的子集；一个都没有时退回原表（可选按 [fallbackKey] 取最小的那个）。
  List<DownloadSource> _preferring(
    List<DownloadSource> pool,
    bool Function(DownloadSource) test, {
    double Function(DownloadSource)? fallbackKey,
  }) {
    final List<DownloadSource> kept = pool.where(test).toList(growable: false);
    if (kept.isNotEmpty) return kept;
    if (fallbackKey == null) return pool;
    double best = double.infinity;
    for (final DownloadSource s in pool) {
      best = math.min(best, fallbackKey(s));
    }
    return pool
        .where((DownloadSource s) => fallbackKey(s) == best)
        .toList(growable: false);
  }

  /// 规则 1（没测过/样本过期的先测）+ 规则 2（谁快派给谁）。同分时按 url 定序，
  /// 让选择在测试里是确定的。
  DownloadSource _bestOf(List<DownloadSource> pool, DateTime at) {
    final List<DownloadSource> unmeasured = pool.where((DownloadSource s) {
      final _SourceStat? stat = _stats[s.url];
      if (stat?.bytesPerSecond == null) return true;
      final DateTime? sampledAt = stat!.sampledAt;
      return sampledAt == null || at.difference(sampledAt) >= probeAfter;
    }).toList(growable: false);
    if (unmeasured.isNotEmpty) {
      // 探测阶段按「试过几次」摊开，**不是**按有没有速度样本摊开：样本可能因为太小
      // （[minSampleBytes]）被丢掉，那时每家都永远算「没测过」，若再拿 url 定序当
      // 兜底，所有片会一直压在字典序最小的那家身上。次数是永远有的。
      return _minBy(
        unmeasured,
        // 先比试过的次数，同次数再比在飞数；两者都是小整数，合成一个键即可。
        (DownloadSource s) =>
            (_stats[s.url]?.probes ?? 0) * 1e6 + inFlightOf(s.url),
      );
    }
    return _minBy(pool, (DownloadSource s) => -(speedOf(s.url) ?? 0));
  }

  DownloadSource _minBy(
    List<DownloadSource> pool,
    double Function(DownloadSource) key,
  ) {
    DownloadSource best = pool.first;
    double bestKey = key(best);
    for (final DownloadSource candidate in pool.skip(1)) {
      final double candidateKey = key(candidate);
      if (candidateKey < bestKey ||
          (candidateKey == bestKey && candidate.url.compareTo(best.url) < 0)) {
        best = candidate;
        bestKey = candidateKey;
      }
    }
    return best;
  }
}

class _SourceStat {
  /// 这个来源被真正试过几次（成功或失败）。冷启动摊开用它排序。
  int probes = 0;

  double? bytesPerSecond;
  DateTime? sampledAt;
  int consecutiveFailures = 0;
  DateTime? cooldownUntil;
  int inFlight = 0;
}
