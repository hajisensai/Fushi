// 提交页草稿：写到一半退出（返回、切页面、app 被杀）时保留下来，下次打开提交页自动恢复。
//
// 只存一份——提交页同一时间只有一个，多份草稿还要配一个「选哪份」的列表，徒增步骤；
// 新写的覆盖旧的。落在 `<数据根>/feedback/draft/`（与 tickets.json 同级的 feedback
// 目录下）：`draft.json` 存文字与选项，截图各存一个文件。不进 Drift、不同步、不进备份。
//
// 写入：先整份写到 `draft.tmp/`，再删旧目录、把临时目录改名过去；读到一半坏掉的草稿
// （缺文件 / JSON 损坏）当作没有草稿，不抛给页面。所有读写串行执行。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:path/path.dart' as p;

/// 提交页的一份草稿。
class FeedbackComposeDraft {
  const FeedbackComposeDraft({
    required this.category,
    required this.title,
    required this.body,
    required this.contact,
    required this.includeLogs,
    required this.includeDevice,
    required this.linkAccount,
    required this.screenshots,
    required this.savedAt,
  });

  final FeedbackCategory category;
  final String title;
  final String body;
  final String contact;
  final bool includeLogs;
  final bool includeDevice;
  final bool linkAccount;
  final List<Uint8List> screenshots;

  /// 保存时刻（毫秒）。
  final int savedAt;
}

class FeedbackDraftStore {
  FeedbackDraftStore(this.supportRoot);

  final Directory supportRoot;

  Directory get dir => Directory(p.join(supportRoot.path, 'feedback', 'draft'));

  Directory get _tmp =>
      Directory(p.join(supportRoot.path, 'feedback', 'draft.tmp'));

  Future<void> _queue = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() op) {
    final Future<T> next = _queue.then((_) => op());
    _queue = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// 读草稿；没有 / 损坏返回 null。
  Future<FeedbackComposeDraft?> read() => _serial(() async {
    final File json = File(p.join(dir.path, 'draft.json'));
    if (!json.existsSync()) return null;
    try {
      final Map<String, dynamic> j =
          (jsonDecode(await json.readAsString()) as Map<Object?, Object?>)
              .cast<String, dynamic>();
      final List<Uint8List> shots = <Uint8List>[
        for (final Object? name
            in (j['screenshots'] as List<Object?>? ?? const <Object?>[]))
          await File(
            p.join(dir.path, p.basename(name! as String)),
          ).readAsBytes(),
      ];
      return FeedbackComposeDraft(
        category: FeedbackCategory.fromWire(j['category']),
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        contact: j['contact'] as String? ?? '',
        includeLogs: j['includeLogs'] as bool? ?? true,
        includeDevice: j['includeDevice'] as bool? ?? true,
        linkAccount: j['linkAccount'] as bool? ?? true,
        screenshots: shots.take(FeedbackLimits.screenshots).toList(),
        savedAt: (j['savedAt'] as num?)?.toInt() ?? 0,
      );
    } on Object {
      return null;
    }
  });

  /// 整份覆盖写入。
  Future<void> write(FeedbackComposeDraft draft) => _serial(() async {
    final Directory tmp = _tmp;
    if (tmp.existsSync()) await tmp.delete(recursive: true);
    await tmp.create(recursive: true);
    final List<String> names = <String>[];
    for (int i = 0; i < draft.screenshots.length; i++) {
      final String name = 'shot_$i.img';
      await File(
        p.join(tmp.path, name),
      ).writeAsBytes(draft.screenshots[i], flush: true);
      names.add(name);
    }
    await File(p.join(tmp.path, 'draft.json')).writeAsString(
      jsonEncode(<String, dynamic>{
        'version': 1,
        'category': draft.category.wire,
        'title': draft.title,
        'body': draft.body,
        'contact': draft.contact,
        'includeLogs': draft.includeLogs,
        'includeDevice': draft.includeDevice,
        'linkAccount': draft.linkAccount,
        'screenshots': names,
        'savedAt': draft.savedAt,
      }),
      flush: true,
    );
    final Directory target = dir;
    if (target.existsSync()) await target.delete(recursive: true);
    await tmp.rename(target.path);
  });

  /// 删掉草稿（提交成功 / 用户丢弃 / 内容清空）。
  Future<void> clear() => _serial(() async {
    for (final Directory d in <Directory>[dir, _tmp]) {
      if (d.existsSync()) await d.delete(recursive: true);
    }
  });
}
