import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';
import 'package:isar/isar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

/// 有声书数据访问层，封装所有 Isar 查询。
///
/// 查询 **优先** 走 `.where().bookUidEqualTo(...)` 命中 hash 索引；失败时回退
/// 到 "遍历 id → 逐条 get" 的扫描（同 [sweepCorrupt] 的兜底手段）：
///
/// 1. `.filter().bookUidEqualTo(...)` 是全表扫描 + 内存反序列化，只要 Isar
///    里存在一条字段字节损坏的旧记录（历史导入流程写脏的），扫到它就会抛
///    `FormatException: Unexpected extension byte`，整个查询 ErrorWidget。
///    所以不能用 filter。
/// 2. 实测 Isar hash 索引在 bookUid 是 "URL + 日文长串" 这类字符串时 **put
///    写得进但 `bookUidEqualTo` 查不到**（写入时和查询时对同一字符串算出的
///    hash 不一致，疑似 Isar 停止维护遗留的 bug）。只靠 where 会回到 "Audiobook
///    已保存但永远找不到" 的状态。
/// 3. 回退路径用 `idProperty()` 拿 id 列表（不反序列化记录体），对每个 id
///    单独 `get(id)` 读出对象，读失败（脏记录）的静默跳过，读成功后比 bookUid。
///    既避开索引 bug，也避开某一条脏记录把整次查询带崩。
class AudiobookRepository {
  /// 绑定一个已经打开的 [Isar] 实例供后续查询使用。
  const AudiobookRepository(this._isar);

  final Isar _isar;

  /// 按书的 uniqueKey 查找挂载的 [Audiobook]，未找到返回 null。
  ///
  /// 先 hash 索引，失败走 id 遍历兜底（见类注释）。
  Audiobook? findByBookUid(String bookUid) {
    final Audiobook? byIndex =
        _isar.audiobooks.where().bookUidEqualTo(bookUid).findFirstSync();
    if (byIndex != null) {
      return byIndex;
    }
    return _findByBookUidScanSync(bookUid);
  }

  /// "遍历 id → 逐条 get" 回退查找。仅在 [findByBookUid] 同步路径里用；
  /// 写事务路径当前没有读-改-写的需求（Follow audio / 健康度都不再落 Isar）。
  Audiobook? _findByBookUidScanSync(String bookUid) {
    final List<int> ids =
        _isar.audiobooks.where().idProperty().findAllSync();
    debugPrint('[hibiki-audiobook] findByBookUid scan: target.len=${bookUid.length} '
        'target.hash=${bookUid.hashCode} ids=$ids');
    for (final int id in ids) {
      try {
        final Audiobook? row = _isar.audiobooks.getSync(id);
        if (row == null) continue;
        final bool match = row.bookUid == bookUid;
        if (!match) {
          debugPrint('[hibiki-audiobook] findByBookUid scan: id=$id no-match '
              'row.len=${row.bookUid.length} row.hash=${row.bookUid.hashCode}');
          if (row.bookUid.length == bookUid.length) {
            // 逐字符对比，找首个差异位置
            for (int i = 0; i < bookUid.length; i++) {
              if (row.bookUid.codeUnitAt(i) != bookUid.codeUnitAt(i)) {
                debugPrint('[hibiki-audiobook]   first diff @$i: '
                    'row=U+${row.bookUid.codeUnitAt(i).toRadixString(16)} '
                    'target=U+${bookUid.codeUnitAt(i).toRadixString(16)}');
                break;
              }
            }
          }
        }
        if (match) {
          debugPrint('[hibiki-audiobook] findByBookUid: index miss, '
              'recovered via id scan id=$id');
          return row;
        }
      } catch (e) {
        debugPrint('[hibiki-audiobook] findByBookUid scan: id=$id READ FAILED: $e');
      }
    }
    return null;
  }

  /// 查询指定书+章节的所有 [AudioCue]（已按 sentenceIndex 排序）。
  List<AudioCue> cuesForChapter({
    required String bookUid,
    required String chapterHref,
  }) {
    return _isar.audioCues
        .where()
        .bookUidEqualTo(bookUid)
        .filter()
        .chapterHrefEqualTo(chapterHref)
        .sortBySentenceIndex()
        .findAllSync();
  }

  /// 查询指定书的所有 [AudioCue]，跨章节汇总。
  ///
  /// Sasayaki 路径下 cue 的位置信息编码在 textFragmentId 上（sectionIndex +
  /// normChar 偏移），与原始 chapterHref 无关，需要不分章节地取全部 cue 供
  /// 音频控制器跨章节追踪。
  List<AudioCue> cuesForBook(String bookUid) {
    return _isar.audioCues
        .where()
        .bookUidEqualTo(bookUid)
        .sortBySentenceIndex()
        .findAllSync();
  }

  /// 查找指定书+章节+句序对应的 [AudioCue]，未找到返回 null。
  AudioCue? findCue({
    required String bookUid,
    required String chapterHref,
    required int sentenceIndex,
  }) {
    return _isar.audioCues
        .where()
        .bookUidEqualTo(bookUid)
        .filter()
        .chapterHrefEqualTo(chapterHref)
        .and()
        .sentenceIndexEqualTo(sentenceIndex)
        .findFirstSync();
  }

  /// 批量写入 [AudioCue] 列表（先清除同书同章节的旧数据）。
  Future<void> saveCues({
    required String bookUid,
    required String chapterHref,
    required List<AudioCue> cues,
  }) async {
    await _isar.writeTxn(() async {
      // 删除旧数据
      final List<int> oldIds = await _isar.audioCues
          .where()
          .bookUidEqualTo(bookUid)
          .filter()
          .chapterHrefEqualTo(chapterHref)
          .idProperty()
          .findAll();
      await _isar.audioCues.deleteAll(oldIds);
      // 写入新数据
      await _isar.audioCues.putAll(cues);
    });
  }

  /// 保存 [Audiobook] 元数据。
  Future<void> saveAudiobook(Audiobook audiobook) async {
    final int id = await _isar.writeTxn(() async {
      final int newId = await _isar.audiobooks.put(audiobook);
      return newId;
    });
    debugPrint('[hibiki-audiobook] saveAudiobook put id=$id '
        'bookUid.len=${audiobook.bookUid.length} hash=${audiobook.bookUid.hashCode}');
    try {
      final Audiobook? readBack = await _isar.audiobooks.get(id);
      debugPrint('[hibiki-audiobook] saveAudiobook readback id=$id '
          'ok=${readBack != null} bookUid.hash=${readBack?.bookUid.hashCode}');
    } catch (e) {
      debugPrint('[hibiki-audiobook] saveAudiobook readback id=$id THREW: $e');
    }
  }

  /// Follow audio 开关的 Hive key 前缀。
  ///
  /// 不再落 Isar 字段：长 CJK bookUid 的记录第二次 `put` 会把 matchRatePct
  /// 等字节写坏（曾见过 pct=33554526 的回读值）。改用 Hive KV，导入后 Isar
  /// 记录就不再被 put。`Audiobook.followAudio` 字段作为 Isar schema 兼容
  /// 保留，只在导入时一次性写入默认值。
  static const String _kFollowAudioKeyPrefix = 'audiobook_follow_';

  Box? _prefsBox() {
    if (!Hive.isBoxOpen('appModel')) return null;
    return Hive.box('appModel');
  }

  /// 读取 Follow audio 开关，未设置回退 false。
  bool readFollowAudio(String bookUid) {
    final Object? raw = _prefsBox()?.get('$_kFollowAudioKeyPrefix$bookUid');
    return raw is bool ? raw : false;
  }

  /// 写入 Follow audio 开关。Hive 未就绪时静默跳过。
  Future<void> updateFollowAudio({
    required String bookUid,
    required bool value,
  }) async {
    final Box? box = _prefsBox();
    if (box == null) return;
    await box.put('$_kFollowAudioKeyPrefix$bookUid', value);
  }

  /// 删除指定书的所有有声书数据（元数据 + 所有 cue）。
  ///
  /// 优先走 `.where().bookUidEqualTo(...).idProperty()` 只取 id，绕开目标
  /// 记录可能存在的字段反序列化失败 —— 脏记录照样能删掉。
  ///
  /// 索引命中失败时（见类注释里那条 Isar hash-index bug：URL+日文 bookUid
  /// 写得进查不出）回退到 id 扫描，逐条 get 比对 bookUid，匹配的收集进
  /// deleteAll。不然 deleteAll([]) 默默成功，用户看到"点了移除还在"。
  Future<void> deleteAudiobook(String bookUid) async {
    await _isar.writeTxn(() async {
      List<int> abIds = await _isar.audiobooks
          .where()
          .bookUidEqualTo(bookUid)
          .idProperty()
          .findAll();
      if (abIds.isEmpty) {
        abIds = await _scanIdsByBookUidAsync<Audiobook>(
          ids: await _isar.audiobooks.where().idProperty().findAll(),
          bookUid: bookUid,
          getById: _isar.audiobooks.get,
          uidOf: (row) => row.bookUid,
          label: 'audiobook',
        );
      }
      await _isar.audiobooks.deleteAll(abIds);

      List<int> cueIds = await _isar.audioCues
          .where()
          .bookUidEqualTo(bookUid)
          .idProperty()
          .findAll();
      if (cueIds.isEmpty) {
        cueIds = await _scanIdsByBookUidAsync<AudioCue>(
          ids: await _isar.audioCues.where().idProperty().findAll(),
          bookUid: bookUid,
          getById: _isar.audioCues.get,
          uidOf: (row) => row.bookUid,
          label: 'audioCue',
        );
      }
      await _isar.audioCues.deleteAll(cueIds);
    });
  }

  /// 索引未命中时按 id 列表逐条 get，收集 bookUid 匹配的 id。
  /// 读失败（脏记录）静默跳过。
  Future<List<int>> _scanIdsByBookUidAsync<T>({
    required List<int> ids,
    required String bookUid,
    required Future<T?> Function(int id) getById,
    required String Function(T row) uidOf,
    required String label,
  }) async {
    final List<int> hit = [];
    for (final int id in ids) {
      try {
        final T? row = await getById(id);
        if (row == null) continue;
        if (uidOf(row) == bookUid) {
          hit.add(id);
        }
      } catch (_) {
        // skip corrupt
      }
    }
    if (hit.isNotEmpty) {
      debugPrint('[hibiki-audiobook] deleteAudiobook: index miss for $label, '
          'recovered via id scan ids=$hit');
    }
    return hit;
  }

  /// 扫全表清理反序列化失败的脏记录。
  ///
  /// 场景：历史版本（v1 embedding 补丁期、或某次异常中断的导入）可能把
  /// 字段字节写坏。正常查询用 `.where()` 能绕开它们，但用户一旦想"移除"
  /// 那条坏记录（bookUid 本身已不可读），普通 bookUid 查不到。这里按 id
  /// 逐条 get，失败的直接 delete。
  ///
  /// 调用时机建议：app 启动时 or 用户触发"清理有声书数据"按钮。返回删除
  /// 的脏记录条数。
  Future<int> sweepCorrupt() async {
    int removed = 0;
    final List<int> allAbIds =
        await _isar.audiobooks.where().idProperty().findAll();
    final List<int> badAbIds = [];
    for (final int id in allAbIds) {
      try {
        await _isar.audiobooks.get(id);
      } catch (e) {
        debugPrint('[hibiki-audiobook] sweepCorrupt: audiobook id=$id '
            'unreadable, will delete: $e');
        badAbIds.add(id);
      }
    }
    final List<int> allCueIds =
        await _isar.audioCues.where().idProperty().findAll();
    final List<int> badCueIds = [];
    for (final int id in allCueIds) {
      try {
        await _isar.audioCues.get(id);
      } catch (e) {
        debugPrint('[hibiki-audiobook] sweepCorrupt: audioCue id=$id '
            'unreadable, will delete: $e');
        badCueIds.add(id);
      }
    }
    if (badAbIds.isEmpty && badCueIds.isEmpty) {
      return 0;
    }
    await _isar.writeTxn(() async {
      await _isar.audiobooks.deleteAll(badAbIds);
      await _isar.audioCues.deleteAll(badCueIds);
    });
    removed = badAbIds.length + badCueIds.length;
    debugPrint('[hibiki-audiobook] sweepCorrupt: removed $removed records '
        '(${badAbIds.length} audiobooks, ${badCueIds.length} cues)');
    return removed;
  }
}
