import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/reader/reader_session_remote.dart';

/// 当前书类阅读会话（EPUB / PDF / 漫画）的遥控路由（CLI：`fushi_cli reader ...`）。
///
/// 只转调阅读页登记的 [ReaderSessionRemote]（翻页键 / 浮动翻页条 / 目录跳章 / 进度条
/// 拖动背后的同一批方法）；没有打开的阅读页时回 409。定位方式按阅读器种类：
/// EPUB = `chapter`（+ 章内 `progress`）或全书 `percent`；PDF = `page`；漫画 =
/// `page`，在线作品另可 `chapter`（第几话）。打开某本书到指定位置用
/// `library open <key> --chapter/--page`。
List<CtlRoute> buildReaderCtlRoutes(
  OpContext context, {
  ReaderSessionRemoteRegistry? registry,
}) {
  final ReaderSessionRemoteRegistry remotes = registry ?? readerSessionRemotes;
  return <CtlRoute>[
    CtlRoute.get(kReaderCtlPath, (CtlCall call) async {
      final ReaderSessionRemote? remote = remotes.current.value;
      final ReaderSessionSnapshot? snapshot = remote?.snapshot();
      if (snapshot == null) return <String, Object?>{'active': false};
      return readerCtlSnapshotJson(snapshot);
    }),
    CtlRoute.post('$kReaderCtlPath/turn', (CtlCall call) async {
      final ReaderSessionRemote remote = _requireRemote(remotes);
      final String direction = call.optString('direction') ?? 'next';
      if (direction != 'next' && direction != 'prev') {
        throw const CtlFailure.badRequest('direction 只能是 next / prev');
      }
      final int count = call.optInt('count') ?? 1;
      if (count < 1 || count > kReaderCtlMaxTurns) {
        throw const CtlFailure.badRequest('count 必须在 1–$kReaderCtlMaxTurns 之间');
      }
      for (int i = 0; i < count; i++) {
        await remote.turnPage(forward: direction == 'next');
      }
      return _snapshotOrInactive(remote);
    }),
    CtlRoute.post('$kReaderCtlPath/goto', (CtlCall call) async {
      final ReaderSessionRemote remote = _requireRemote(remotes);
      final ReaderSessionSnapshot snapshot = remote.snapshot()!;
      final ReaderCtlGotoTarget target = parseReaderCtlGoto(
        snapshot,
        chapter: call.optInt('chapter'),
        page: call.optInt('page'),
        percent: _optDouble(call, 'percent'),
        progress: _optDouble(call, 'progress'),
      );
      final bool landed = switch (target) {
        ReaderCtlGotoChapter(:final int index, :final double progress) =>
          await remote.goToChapter(index, progress: progress),
        ReaderCtlGotoPage(:final int index) => await remote.goToPage(index),
        ReaderCtlGotoPercent(:final double percent) =>
          await remote.goToBookPercent(percent),
      };
      if (!landed) {
        throw CtlFailure.conflict(switch (target) {
          ReaderCtlGotoPercent() => '全书字数还没统计完，暂时不能按百分比跳转',
          _ => '跳转没有落定（阅读器正在加载或导航被打断）',
        });
      }
      return _snapshotOrInactive(remote);
    }),
  ];
}

const String kReaderCtlPath = '/api/admin/library/reader';

/// `reader next/prev --count` 上限（防一条命令把整本书翻完）。
const int kReaderCtlMaxTurns = 50;

/// `reader goto` 解析后的目标（下标全部 0 起计）。
sealed class ReaderCtlGotoTarget {
  const ReaderCtlGotoTarget();
}

class ReaderCtlGotoChapter extends ReaderCtlGotoTarget {
  const ReaderCtlGotoChapter(this.index, this.progress);
  final int index;

  /// 章内分数 0–1（漫画忽略）。
  final double progress;
}

class ReaderCtlGotoPage extends ReaderCtlGotoTarget {
  const ReaderCtlGotoPage(this.index);
  final int index;
}

class ReaderCtlGotoPercent extends ReaderCtlGotoTarget {
  const ReaderCtlGotoPercent(this.percent);
  final double percent;
}

/// 按当前阅读器种类校验 `goto` 参数（用户输入 1 起计、百分比 0–100）。
/// 不合法抛 [CtlFailure.badRequest]。
ReaderCtlGotoTarget parseReaderCtlGoto(
  ReaderSessionSnapshot snapshot, {
  int? chapter,
  int? page,
  double? percent,
  double? progress,
}) {
  final int given = <Object?>[
    chapter,
    page,
    percent,
  ].where((Object? v) => v != null).length;
  if (given != 1) {
    throw const CtlFailure.badRequest('chapter / page / percent 只给一个');
  }
  if (progress != null && chapter == null) {
    throw const CtlFailure.badRequest('progress 只配合 chapter 使用');
  }
  switch (snapshot.kind) {
    case ReaderSessionKind.epub:
      if (page != null) {
        throw const CtlFailure.badRequest('EPUB 没有固定页码，用 chapter 或 percent');
      }
    case ReaderSessionKind.pdf:
      if (page == null) throw const CtlFailure.badRequest('PDF 只能按 page 跳转');
    case ReaderSessionKind.manga:
      if (percent != null || progress != null) {
        throw const CtlFailure.badRequest('漫画按 page 跳转（在线作品可用 chapter 切话）');
      }
      if (chapter != null && snapshot.chapterCount == null) {
        throw const CtlFailure.badRequest('本地漫画卷没有「话」，只用 page');
      }
  }
  if (chapter != null) {
    final int count = snapshot.chapterCount ?? 0;
    if (chapter < 1 || chapter > count) {
      throw CtlFailure.badRequest('章号超出范围：共 $count 章 / 话，收到 $chapter');
    }
    if (progress != null && (progress < 0 || progress > 100)) {
      throw const CtlFailure.badRequest('progress 是章内百分比 0–100');
    }
    return ReaderCtlGotoChapter(chapter - 1, (progress ?? 0) / 100);
  }
  if (page != null) {
    final int count = snapshot.pageCount ?? 0;
    if (page < 1 || page > count) {
      throw CtlFailure.badRequest('页码超出范围：共 $count 页，收到 $page');
    }
    return ReaderCtlGotoPage(page - 1);
  }
  if (percent! < 0 || percent > 100) {
    throw const CtlFailure.badRequest('percent 是全书百分比 0–100');
  }
  return ReaderCtlGotoPercent(percent);
}

ReaderSessionRemote _requireRemote(ReaderSessionRemoteRegistry remotes) {
  final ReaderSessionRemote? remote = remotes.current.value;
  if (remote == null || remote.snapshot() == null) {
    throw const CtlFailure.conflict('没有打开的阅读器（先 library open）');
  }
  return remote;
}

Map<String, Object?> _snapshotOrInactive(ReaderSessionRemote remote) {
  final ReaderSessionSnapshot? snapshot = remote.snapshot();
  return snapshot == null
      ? <String, Object?>{'active': false}
      : readerCtlSnapshotJson(snapshot);
}

double? _optDouble(CtlCall call, String name) {
  final Object? raw = call.body[name] ?? call.query[name];
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  final double? parsed = double.tryParse('$raw'.trim());
  if (parsed == null) throw CtlFailure.badRequest('$name 必须是数字');
  return parsed;
}

/// 快照 → 线上 JSON（章号 / 页码 1 起计，百分比 0–100；不适用的字段不出现）。
Map<String, Object?> readerCtlSnapshotJson(ReaderSessionSnapshot s) =>
    <String, Object?>{
      'active': true,
      'kind': s.kind.name,
      'key': 'book:${s.bookKey}',
      if (s.title != null) 'title': s.title,
      if (s.chapterIndex != null) 'chapter': s.chapterIndex! + 1,
      if (s.chapterCount != null) 'chapterCount': s.chapterCount,
      if (s.chapterProgress != null)
        'chapterProgress': (s.chapterProgress! * 1000).round() / 10,
      if (s.bookPercent != null) 'percent': s.bookPercent,
      if (s.pageIndex != null) 'page': s.pageIndex! + 1,
      if (s.pageCount != null) 'pageCount': s.pageCount,
      'ready': s.contentReady,
    };
