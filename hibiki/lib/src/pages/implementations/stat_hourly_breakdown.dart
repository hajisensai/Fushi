import 'package:hibiki_core/hibiki_core.dart';

/// 时段图一天的桶数（0-23 时）。
const int kStatHourlyBuckets = 24;

/// 阅读时段图的**分带身份**：统计 UI 自己的值域，与 [BookFormat] 分开。
///
/// 前三带一一对应三个阅读面。[unattributed] 不是第四种书，而是「这段时长在**写入
/// 那一刻**就没有存身份、现在拆不开」这一事实本身：
/// - v67 之前 `reading_hourly_logs` 没有 `format` 列，同一小时的 EPUB / PDF / 漫画
///   时长在写入时就被加成了一行，信息已经丢了，事后没有任何依据能把它分开；
/// - 云聚合从不带 format 的旧端拿到的逐时差额同样无法归因，落在 `''` 桶
///   （`addUnattributedHourlyReadingTime`）。
///
/// 这些行**不得**被默默归进任何一个阅读面。把它们算进 EPUB 只是让图好看，代价是
/// 给用户编造一个数据里根本不存在的归属。UI 的义务是把它单独画出来、并写明它是
/// 未区分的历史合计。
enum StatHourlyFormatBand {
  /// 文字书（EPUB / TextToEpub / 有声书配对壳）。
  epub,

  /// PDF 阅读器。
  pdf,

  /// 漫画阅读器。
  manga,

  /// 未区分的历史合计。声明序即堆叠序与图例序，它排在最后 ⇒ 画在柱子**最上层**，
  /// 紧挨图例，用户一眼能看见「这一截不属于任何一类」。
  unattributed;

  /// `reading_hourly_logs.format` 列 → 分带身份。
  ///
  /// 解析走 [BookFormat.tryParse] 而**不是** [BookFormat.parseOrEpub]：宽松解析把
  /// 未知串按 EPUB 处理，那条回退对「阅读器路由」是对的（总得打开一个阅读器），
  /// 对这里是错的——它会把 `''` 的历史行伪装成 EPUB 的真实读书时长。
  static StatHourlyFormatBand ofDbValue(String raw) {
    final BookFormat? format = BookFormat.tryParse(raw);
    if (format == null) return StatHourlyFormatBand.unattributed;
    return switch (format) {
      BookFormat.epub => StatHourlyFormatBand.epub,
      BookFormat.pdf => StatHourlyFormatBand.pdf,
      BookFormat.manga => StatHourlyFormatBand.manga,
    };
  }
}

/// 今日 0-23 时、按 [StatHourlyFormatBand] 分带的时长（毫秒）。
///
/// 只保存**分带**值，不另存一份合计：合计随时可由分带求和得到，多存一份就多一个
/// 会漂开的真相源。
class StatHourlyBreakdown {
  StatHourlyBreakdown();

  final Map<StatHourlyFormatBand, List<int>> _byBand =
      <StatHourlyFormatBand, List<int>>{};

  /// 累加一行日志。同一 (band, hour) 可能有多行（云同步合并后），故是累加不是赋值。
  /// 越界 [hour] 直接丢弃（DB 列无 CHECK 约束，脏值不该把图画坏）。
  void addMs({
    required StatHourlyFormatBand band,
    required int hour,
    required int ms,
  }) {
    if (hour < 0 || hour >= kStatHourlyBuckets) return;
    _byBand.putIfAbsent(
        band, () => List<int>.filled(kStatHourlyBuckets, 0))[hour] += ms;
  }

  /// 某一带的 24 小时值；该带无数据时返回全零（调用方不必判空）。
  List<int> valuesOf(StatHourlyFormatBand band) => List<int>.unmodifiable(
      _byBand[band] ?? List<int>.filled(kStatHourlyBuckets, 0));

  /// 当日真的有非零时长的带，按枚举声明序。堆叠与图例共用这一个顺序，两边天然一致。
  List<StatHourlyFormatBand> get activeBands => StatHourlyFormatBand.values
      .where((StatHourlyFormatBand band) =>
          (_byBand[band] ?? const <int>[]).any((int ms) => ms > 0))
      .toList(growable: false);

  /// 当日总时长（毫秒）。
  int get totalMs => _byBand.values.fold<int>(
      0,
      (int sum, List<int> values) =>
          sum + values.fold<int>(0, (int s, int ms) => s + ms));

  /// 当日无任何时长。
  bool get isEmpty => activeBands.isEmpty;
}
