import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/src/anki/mined_state_signal.dart';

/// iOS 上查词的 ✓ 是否由本账本决定（调用方先判 `Platform.isIOS`）：改用了
/// AnkiConnect 时直接问 Anki；「制卡到服务器」时查重问的是 host。只有剩下这种
/// 情况，「导入 Anki 备份」才有意义。
bool ankiMobileLedgerIsDuplicateSource({
  required bool useAnkiConnectOnMobile,
  required bool mineToServer,
}) => !useAnkiConnectOnMobile && !mineToServer;

/// AnkiMobile 后端「这个词是不是已经制过卡」的**唯一真值来源**。
///
/// 为什么非得自己记一份：AnkiMobile 的 `anki://x-callback-url` 一共只有 `addnote`
/// / `infoForAdding` / `search` / `sync` 四个入口（官方手册 URL Schemes 一节），
/// **没有任何回读 collection 的通道**——AnkiConnect 的
/// `canAddNotesWithErrorDetail`、AnkiDroid 的 ContentProvider `findDuplicateNotes`
/// 在 iOS 上都没有对应物。所以 iOS 上的 ✓ 只能建立在「Fushi 自己确认加成功过的卡」
/// 之上，别无第二条路；此前 `isDuplicate` 恒 `false`，iOS 用户永远看不到 ✓。
///
/// 落账时机是 **AnkiMobile 回跳的 `x-success`**，而不是「我们把 addnote URL 打开
/// 了」：手册对 `x-success` 的定义是「use to automatically return to another app
/// **after the note is added**」——它送达等价于 AnkiMobile 确认这张卡进了库；而
/// URL 被打开只说明 AnkiMobile 被拉起来了（用户可能直接退出、`profile=` 对不上、
/// 或被 AnkiMobile 自己按 `dupes` 拦下）。拿「打开了」当「制卡了」会画出骗人的 ✓。
///
/// 匹配口径 = **expression 全等**（仅 trim），与 AnkiConnect 的 `isDuplicate` 对齐
/// ——那条也只把第一字段发给 Anki 问，不带 reading。不拿 reading 做二次过滤是有意
/// 的：同一个词在不同词典里的读音标注常有出入（送假名、清浊、别读），拿它当必要条件
/// 会把「明明制过卡」判成没制过。两种错的代价不对称：false ✗ 只是少画一个提示，
/// 用户照常制卡；false ✓ 会让用户以为卡已经有了而跳过。
///
/// **能力边界（别在文案里吹成「判重」）**：账本只知道**本机经 Fushi 制成**的卡。
/// 直接在 Anki 里加的、别的设备上加的、装 Fushi 之前加的，以及用户事后在 Anki 里
/// 删掉的，账本一概不知道——iOS 上没有任何通道能去核对（用户事后删掉的那一类另有
/// [forget] 作**显式**纠正出口：点 ✓ 的操作单里由用户说「我已经删了」，仍然不是自动
/// 核对，只是把不可检测的事实交还给唯一知道答案的人）。这不是本类的缺陷，是
/// AnkiMobile URL scheme 的边界；有回读通道的那天（或用户改用 AnkiConnect）应当
/// 直接问 Anki，而不是加厚这份账本。
///
/// 持久化跟着 anki 仓库层既有的 SharedPreferences 走（设置串 `fushi_anki_settings`
/// 就在那儿），不为一个 iOS 专属的降级账本动 Drift schema。
///
/// **导入快照**（[replaceImported]）：用户从 Anki 导出的备份里读出的全部第一字段，
/// 对齐 Hoshi Reader iOS 的「Import Anki Backup」。它补的是上面能力边界里「别处加的、
/// 装 Fushi 之前加的」那一大块。与回跳落账分两份存：
/// * 快照是**某一时刻整个 collection** 的样子，重新导入就整份替换——备份之后在 Anki
///   里删掉的卡借此自然消失；回跳落账是「备份之后本机又制的卡」，不能被替换冲掉
///   （Hoshi 整体覆盖，导入一次就把回跳记下的词全丢了）。
/// * 快照动辄数万条，不进 SharedPreferences（iOS 上整份 plist 启动即读），落应用
///   支持目录下的独立 JSON 文件，也不受 [limit] 约束。
/// 查询取两者之并；[forget] 两边一起划。
class AnkiMobileMinedLedger {
  AnkiMobileMinedLedger({
    this.limit = defaultLimit,
    Future<String> Function()? importedSnapshotPath,
  }) : _importedSnapshotPath =
           importedSnapshotPath ?? _defaultImportedSnapshotPath;

  /// 导入快照的文件名（应用支持目录下）。
  static const String importedSnapshotFileName =
      'ankimobile_imported_expressions.json';

  static Future<String> _defaultImportedSnapshotPath() async {
    final Directory dir = await getApplicationSupportDirectory();
    return '${dir.path}/$importedSnapshotFileName';
  }

  final Future<String> Function() _importedSnapshotPath;

  /// 导入快照的内存索引；与 [_entries] 同一次载入。
  Set<String> _imported = <String>{};

  static final AnkiMobileMinedLedger instance = AnkiMobileMinedLedger();

  /// SharedPreferences 键。
  static const String prefsKey = 'fushi_ankimobile_mined_expressions';

  /// 账本条数上限，超出后淘汰「最久没再制过」的那些。
  ///
  /// 有上限是因为这份账本活在 SharedPreferences（iOS 上是一份 plist，进程启动时
  /// 整份读进内存）里，不能无界长。5000 条纯词条 JSON 约 50 KB 量级，对 plist
  /// 无压力，又足够覆盖绝大多数人的制卡史。溢出后最老的词会不再画 ✓——这是**静默
  /// 降级**，但方向是安全的那一边（少画提示，不误报）。
  static const int defaultLimit = 5000;

  /// 本实例的上限；生产恒 [defaultLimit]，测试注入小值以便驱动淘汰路径。
  final int limit;

  /// 内存索引。Dart 的默认 `Set` 是 `LinkedHashSet`（按插入序），所以 [first] 就是
  /// 「最久没再制过」的那条，trim 直接从头淘汰。`null` = 还没从持久层读过。
  Set<String>? _entries;
  Future<void>? _loading;

  /// 账本里的词条数（已载入时才有意义，供测试与诊断）。
  @visibleForTesting
  int get length => _entries?.length ?? 0;

  /// AnkiMobile 确认这张卡已经加进库了，落账。
  ///
  /// 重复制同一个词时把它挪到队尾：trim 该淘汰的是真正最久没再碰过的词，而不是
  /// 「第一次制卡时间最早」的词。
  Future<void> record(String expression) async {
    final String key = _normalize(expression);
    if (key.isEmpty) return;
    await _ensureLoaded();
    final Set<String> entries = _entries!;
    entries.remove(key);
    entries.add(key);
    while (entries.length > limit) {
      entries.remove(entries.first);
    }
    await _persist(entries);
    // 落账是**界面之外**发生的（`x-success` 回跳时用户刚从 AnkiMobile 切回来），
    // 正在显示 ✓ 的弹窗早就探测完了。不回头通知，iOS 上「刚制完的卡」就永远等到
    // 下一次重新查这个词才亮 ✓。发在这里而不是调用点：任何新的落账路径都不会漏。
    MinedStateSignal.instance.notifyWord(key);
  }

  /// 用户声明「这张卡我已经在 Anki 里删了」，把它从账本划掉（✓ → +）。
  ///
  /// 为什么这条得由用户来说：账本是 iOS 上的**唯一**真值来源，而 AnkiMobile 的 URL
  /// scheme 没有回读通道——「这张卡还在不在」在 iOS 上没有任何自动核对的办法（类注释
  /// 的能力边界那段）。其余后端每次查词都真问 Anki，删掉的卡下一次查词就自动变回 +；
  /// iOS 若不给出口，账本会把一个**已经不存在**的卡永久画成 ✓，↗ 也会去开一个搜不到
  /// 东西的界面（用户报「卡片删掉也不会检测是否还存在」）。
  ///
  /// 返回是否真的划掉了（账本里本来就没有 → `false`，供调用方决定要不要提示）。
  Future<bool> forget(String expression) async {
    final String key = _normalize(expression);
    if (key.isEmpty) return false;
    await _ensureLoaded();
    final Set<String> entries = _entries!;
    // 两份都要划：只划回跳账本的话，导入快照里还躺着同一个词，✓ 照亮。
    final bool fromRecorded = entries.remove(key);
    final bool fromImported = _imported.remove(key);
    if (!fromRecorded && !fromImported) return false;
    if (fromRecorded) await _persist(entries);
    if (fromImported) await _persistImported(_imported);
    MinedStateSignal.instance.notifyWord(key);
    return true;
  }

  /// 这个词在本机经 Fushi 制过卡，或出现在最近一次导入的 Anki 备份里吗。
  Future<bool> contains(String expression) async {
    final String key = _normalize(expression);
    if (key.isEmpty) return false;
    await _ensureLoaded();
    return _entries!.contains(key) || _imported.contains(key);
  }

  /// 用一份 Anki 备份读出的第一字段集合**整份替换**导入快照（为什么是替换而不是
  /// 合并见类注释）。回跳落账不受影响。返回快照条数。
  ///
  /// 所有已渲染弹窗的 ✓ 都可能变，所以广播「范围未知」的刷新。
  Future<int> replaceImported(Iterable<String> expressions) async {
    await _ensureLoaded();
    final Set<String> next = <String>{};
    for (final String expression in expressions) {
      final String key = _normalize(expression);
      if (key.isNotEmpty) next.add(key);
    }
    await _persistImported(next, throwOnFailure: true);
    _imported = next;
    MinedStateSignal.instance.notifyAll();
    return next.length;
  }

  /// 导入快照当前条数（设置页显示「已导入 N 个词」）。
  Future<int> importedCount() async {
    await _ensureLoaded();
    return _imported.length;
  }

  /// 丢掉内存索引，下次访问重新从持久层读。测试用（单例跨用例复用）。
  @visibleForTesting
  void resetForTesting() {
    _entries = null;
    _imported = <String>{};
    _loading = null;
  }

  /// 与 `isDuplicate` 的提问口径必须是同一条：两边都只 trim，不做大小写折叠，也不
  /// 碰任何 Unicode 归一化——制卡与查词拿到的是同一个词典词头，逐字相等才算同一个词。
  static String _normalize(String expression) => expression.trim();

  Future<void> _ensureLoaded() {
    final Future<void>? loading = _loading;
    if (loading != null) return loading;
    final Future<void> future = _load();
    _loading = future;
    return future;
  }

  /// 载入恒成功：读不到 / 读坏了一律当空账本继续（fail-soft）。查重在弹窗渲染的热
  /// 路径上，绝不能因为账本坏了就把制卡链路搞崩；最坏结果是 ✓ 少画。
  Future<void> _load() async {
    Set<String> decoded = <String>{};
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      decoded = _decode(prefs.getString(prefsKey));
    } catch (e, stack) {
      debugPrint('AnkiMobileMinedLedger load failed: $e\n$stack');
    }
    Set<String> imported = <String>{};
    try {
      final File file = File(await _importedSnapshotPath());
      if (await file.exists()) {
        imported = _decode(await file.readAsString());
      }
    } catch (e, stack) {
      debugPrint('AnkiMobileMinedLedger imported load failed: $e\n$stack');
    }
    _entries = decoded;
    _imported = imported;
  }

  /// 先写临时文件再改名：写到一半被杀掉时旧快照还在，不会留下半截 JSON。
  ///
  /// [throwOnFailure]：用户手动导入时写失败必须报出来（否则设置页说「导入了 N 个」
  /// 而下次启动全没了）；[forget] 顺带改写时沿用账本的 fail-soft。
  Future<void> _persistImported(
    Set<String> imported, {
    bool throwOnFailure = false,
  }) async {
    try {
      final File file = File(await _importedSnapshotPath());
      await file.parent.create(recursive: true);
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(imported.toList()), flush: true);
      await tmp.rename(file.path);
    } catch (e, stack) {
      if (throwOnFailure) rethrow;
      debugPrint('AnkiMobileMinedLedger imported persist failed: $e\n$stack');
    }
  }

  static Set<String> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <String>{};
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      return <String>{};
    }
    if (parsed is! List) return <String>{};
    final Set<String> entries = <String>{};
    for (final Object? item in parsed) {
      if (item is! String) continue;
      final String key = _normalize(item);
      if (key.isEmpty) continue;
      entries.add(key);
    }
    return entries;
  }

  Future<void> _persist(Set<String> entries) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, jsonEncode(entries.toList()));
    } catch (e, stack) {
      // 写失败只影响「下次启动还记不记得」，本次会话的内存索引已经更新，✓ 照画。
      debugPrint('AnkiMobileMinedLedger persist failed: $e\n$stack');
    }
  }
}
