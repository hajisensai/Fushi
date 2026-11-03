// Xt3RCTPKhX：远端视频字幕的状态模型——后端默认字幕（`_remoteSubtitlePath`）与本机
// 落盘字幕档（按集持久化）是两份互不覆盖的真相；主 / 副字幕菜单与手机遥控字幕列表
// 统一经 remoteSubtitleFileEntries 拼行。
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/media/video/remote_subtitle_catalog.dart';

SubtitleSource _local(String path) =>
    SubtitleSource.external(externalPath: path, label: path.split('/').last);

void main() {
  group('remoteSubtitleFileEntries', () {
    test('后端默认字幕一行（不可删）+ 每个本机档一行（可删）', () {
      final List<RemoteSubtitleFileEntry> rows = remoteSubtitleFileEntries(
        backendDefaultPath: '/tmp/host_ep1.srt',
        localFiles: <SubtitleSource>[
          _local('/docs/video_subtitles/a.srt'),
          _local('/docs/video_subtitles/b.ass'),
        ],
      );
      expect(
        rows.map((RemoteSubtitleFileEntry e) => e.kind),
        <RemoteSubtitleFileKind>[
          RemoteSubtitleFileKind.backendDefault,
          RemoteSubtitleFileKind.localFile,
          RemoteSubtitleFileKind.localFile,
        ],
      );
      expect(rows.first.deletable, isFalse);
      expect(
        rows.skip(1).every((RemoteSubtitleFileEntry e) => e.deletable),
        isTrue,
      );
    });

    test('后端默认与本机档同路径：只留可删的本机行（此前反过来，删不掉）', () {
      final List<RemoteSubtitleFileEntry> rows = remoteSubtitleFileEntries(
        backendDefaultPath: '/docs/video_subtitles/a.srt',
        localFiles: <SubtitleSource>[_local('/docs/video_subtitles/a.srt')],
      );
      expect(rows, hasLength(1));
      expect(rows.single.kind, RemoteSubtitleFileKind.localFile);
      expect(rows.single.local, isNotNull);
    });

    test('无后端默认字幕时不出「服务端字幕」行', () {
      final List<RemoteSubtitleFileEntry> rows = remoteSubtitleFileEntries(
        backendDefaultPath: null,
        localFiles: <SubtitleSource>[_local('/docs/video_subtitles/a.srt')],
      );
      expect(
        rows.where(
          (RemoteSubtitleFileEntry e) =>
              e.kind == RemoteSubtitleFileKind.backendDefault,
        ),
        isEmpty,
      );
    });
  });

  group('按集持久化的本机档列表', () {
    test('登记新的在前、按路径去重；移除只去掉那一条', () {
      List<String> paths = const <String>[];
      paths = addRemoteLocalSubtitleFile(paths, '/s/a.srt');
      paths = addRemoteLocalSubtitleFile(paths, '/s/b.srt');
      paths = addRemoteLocalSubtitleFile(paths, '/s/a.srt');
      expect(paths, <String>['/s/a.srt', '/s/b.srt']);
      expect(removeRemoteLocalSubtitleFile(paths, '/s/a.srt'), <String>[
        '/s/b.srt',
      ]);
    });

    test('重建只留磁盘上还在的档，顺序保持', () {
      final List<SubtitleSource> restored = restoreRemoteLocalSubtitleFiles(
        const <String>['/s/a.srt', '/s/gone.srt', '/s/b.srt', ''],
        exists: (String path) => path != '/s/gone.srt',
      );
      expect(restored.map((SubtitleSource s) => s.externalPath), <String>[
        '/s/a.srt',
        '/s/b.srt',
      ]);
    });

    test('PreferencesRepository 跨实例记住、按集隔离、空列表删 key', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final PreferencesRepository repo = PreferencesRepository(db);
      await repo.loadFromDb();
      addTearDown(repo.dispose);

      expect(repo.remoteSubtitleFiles('bk', episodeIndex: 1), isEmpty);
      await repo.setRemoteSubtitleFiles('bk', 1, <String>[
        '/s/a.srt',
        '/s/b.srt',
      ]);
      await repo.setRemoteSubtitleFiles('bk', 2, <String>['/s/c.srt']);

      final PreferencesRepository reloaded = PreferencesRepository(db);
      await reloaded.loadFromDb();
      addTearDown(reloaded.dispose);
      expect(reloaded.remoteSubtitleFiles('bk', episodeIndex: 1), <String>[
        '/s/a.srt',
        '/s/b.srt',
      ], reason: '切走再切回 / 退出重进要能重建本集下过的全部字幕');
      expect(reloaded.remoteSubtitleFiles('bk', episodeIndex: 2), <String>[
        '/s/c.srt',
      ]);

      await reloaded.setRemoteSubtitleFiles('bk', 1, const <String>[]);
      expect(reloaded.remoteSubtitleFiles('bk', episodeIndex: 1), isEmpty);
      expect(reloaded.remoteSubtitleFiles('bk', episodeIndex: 2), isNotEmpty);
    });
  });

  group('播放页接线（源码守卫）', () {
    final String page = File(
      'lib/src/pages/implementations/video_fushi_page.dart',
    ).readAsStringSync();
    final String subtitle = File(
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    ).readAsStringSync();
    final String remote = File(
      'lib/src/pages/implementations/video_fushi/playback_remote.part.dart',
    ).readAsStringSync();

    String loadRemoteEpisodeBody() {
      final int start = page.indexOf('Future<void> _loadRemoteEpisode(');
      expect(start, greaterThanOrEqualTo(0));
      final int end = page.indexOf('_separatedAudio.runLoad', start);
      expect(end, greaterThan(start));
      return page.substring(start, end);
    }

    test('换集 / 重进从持久化重建本机档列表，不再清空了事；后端默认槽先清空', () {
      final String body = loadRemoteEpisodeBody();
      expect(body, contains('_remoteSubtitlePath = null;'));
      final String compact = body.replaceAll(RegExp(r'\s+'), '');
      const String restore =
          'finalList<SubtitleSource>restoredLocalSubtitles=await_restoreRemoteLocalSubtitleFiles(index);';
      const String staleGate = 'if(seq!=_episodeLoadSeq||!mounted)return;';
      const String assign = '_importedSubtitleSources=restoredLocalSubtitles;';
      final int restoreAt = compact.indexOf(restore);
      expect(restoreAt, greaterThanOrEqualTo(0), reason: '按本集持久化重建');
      // 作废门必须夹在 await 与落列表之间：快速连切时较早那集的 `File.exists` 可能晚回，
      // 先落再判会把它那集的档覆盖到当前集列表上。
      final int gateAt = compact.indexOf(staleGate, restoreAt);
      expect(gateAt, greaterThan(restoreAt));
      expect(compact.indexOf(assign, gateAt), greaterThan(gateAt));
      expect(
        compact.contains('_importedSubtitleSources=await'),
        isFalse,
        reason: '不得在集序号校验之前直接落列表',
      );
      expect(
        body.contains('_importedSubtitleSources = const <SubtitleSource>[];'),
        isFalse,
      );
    });

    test('重放上次选的本机档不写进后端默认槽（不再变成删不掉的「服务端字幕」行）', () {
      final String body = loadRemoteEpisodeBody();
      expect(body.contains('_remoteSubtitlePath = persistedSub;'), isFalse);
      // 唯一保留的写入点是后端默认字幕下载分支。
      expect(
        '_remoteSubtitlePath = '.allMatches(body).length,
        2,
        reason: '一处起播清空 + 一处后端默认字幕下载',
      );
      expect(body, contains('t.video_subtitle_restore_failed('));
    });

    test('主 / 副字幕菜单与手机遥控列表都走同一份行模型，不再各自按路径去重', () {
      expect(
        '_remoteSubtitleFileRows'.allMatches(subtitle).length,
        greaterThanOrEqualTo(3),
      );
      expect(remote, contains('_state._remoteSubtitleFileRows'));
      expect(
        subtitle.contains('!sameExternalSubtitlePathForMenu(source, hostSub)'),
        isFalse,
      );
      expect(
        remote.contains('sameExternalSubtitlePathForMenu(source, hostSub)'),
        isFalse,
      );
    });

    test('登记 / 删除本机档同步写按集持久化列表', () {
      final String compact = subtitle.replaceAll(RegExp(r'\s+'), '');
      expect(
        compact,
        contains('_persistRemoteLocalSubtitleFile(path,add:true,'),
      );
      expect(
        compact,
        contains('_persistRemoteLocalSubtitleFile(path,add:false,'),
      );
    });
  });
}
