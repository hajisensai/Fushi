import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_lua_script_manager.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;

AudioCue _cue(int startMs, int endMs, String text) {
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

void main() {
  group('listLuaScriptFilesIn', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('lua_scripts_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('只收顶层 .lua（扩展名不分大小写），按路径排序', () {
      File(p.join(dir.path, 'b_second.lua')).writeAsStringSync('-- b');
      File(p.join(dir.path, 'a_first.LUA')).writeAsStringSync('-- a');
      File(p.join(dir.path, 'readme.txt')).writeAsStringSync('not a script');
      File(p.join(dir.path, 'osc.lua.bak')).writeAsStringSync('not a script');
      // 子目录不递归：脚本自己的模块/资源不当独立脚本装载。
      final Directory sub = Directory(p.join(dir.path, 'modules'))
        ..createSync();
      File(p.join(sub.path, 'dep.lua')).writeAsStringSync('-- dep');

      final List<String> out = listLuaScriptFilesIn(dir);

      expect(out, <String>[
        p.join(dir.path, 'a_first.LUA'),
        p.join(dir.path, 'b_second.lua'),
      ]);
    });

    test('目录不存在返回空列表', () {
      final Directory missing = Directory(p.join(dir.path, 'nope'));
      expect(listLuaScriptFilesIn(missing), isEmpty);
    });

    test('空目录返回空列表', () {
      expect(listLuaScriptFilesIn(dir), isEmpty);
    });
  });

  group('buildLoadScriptCommands', () {
    test('每个路径一条 load-script 命令，保持输入顺序', () {
      final List<List<String>> cmds = buildLoadScriptCommands(<String>[
        r'C:\a\x.lua',
        r'C:\a\y.lua',
      ]);
      expect(cmds, <List<String>>[
        <String>['load-script', r'C:\a\x.lua'],
        <String>['load-script', r'C:\a\y.lua'],
      ]);
    });

    test('空输入产生空命令序列（调用方零下发）', () {
      expect(buildLoadScriptCommands(const <String>[]), isEmpty);
    });
  });

  group('buildLuaHostBaselineProperties', () {
    test('关掉内置 ytdl_hook：网络流不许绕开 Dart 解析链路去拉 yt-dlp', () {
      expect(buildLuaHostBaselineProperties(), <String, String>{'ytdl': 'no'});
    });
  });

  group('importLuaScriptFileTo', () {
    late Directory src;
    late Directory dst;

    setUp(() {
      src = Directory.systemTemp.createTempSync('lua_import_src_');
      dst = Directory.systemTemp.createTempSync('lua_import_dst_');
    });

    tearDown(() {
      for (final Directory d in <Directory>[src, dst]) {
        if (d.existsSync()) d.deleteSync(recursive: true);
      }
    });

    test('复制进目标目录并返回文件名；重名覆盖', () {
      final File source = File(p.join(src.path, 'auto_profile.lua'))
        ..writeAsStringSync('-- v1');
      expect(importLuaScriptFileTo(dst, source.path), 'auto_profile.lua');
      expect(
        File(p.join(dst.path, 'auto_profile.lua')).readAsStringSync(),
        '-- v1',
      );

      source.writeAsStringSync('-- v2');
      importLuaScriptFileTo(dst, source.path);
      expect(
        File(p.join(dst.path, 'auto_profile.lua')).readAsStringSync(),
        '-- v2',
      );
    });

    test('目标目录不存在时创建', () {
      final Directory nested = Directory(p.join(dst.path, 'nested'));
      final File source = File(p.join(src.path, 's.lua'))
        ..writeAsStringSync('-- s');
      importLuaScriptFileTo(nested, source.path);
      expect(File(p.join(nested.path, 's.lua')).existsSync(), isTrue);
    });
  });

  // #2014：Fushi 的字幕由 overlay 画、libmpv sid 恒为 no，sub-text 类脚本永远收不到
  // 字幕；装了脚本时把主字幕 cue 镜像成一条隐藏 SRT 轨。
  group('buildLuaSubtitleMirrorSrt', () {
    test('按开始时间排序编号，时间戳为 HH:MM:SS,mmm', () {
      final String srt = buildLuaSubtitleMirrorSrt(<AudioCue>[
        _cue(3723004, 3725500, '二句目'),
        _cue(1000, 2500, '一句目'),
      ]);
      expect(
        srt,
        '1\n00:00:01,000 --> 00:00:02,500\n一句目\n\n'
        '2\n01:02:03,004 --> 01:02:05,500\n二句目\n\n',
      );
    });

    test('正文空行会把 SRT 条目拆开：压掉空行、统一换行', () {
      final String srt = buildLuaSubtitleMirrorSrt(<AudioCue>[
        _cue(0, 1000, '上の行\r\n\r\n下の行  '),
      ]);
      expect(srt, '1\n00:00:00,000 --> 00:00:01,000\n上の行\n下の行\n\n');
    });

    // mpv 0.41 实测：sub-start/sub-end 不含 sub-delay，调轴必须烘进时间戳，
    // 脚本拿 sub-end 判句尾才与 overlay（posMs - delayMs 落在 cue 内）同一刻。
    test('调轴烘进时间戳；负偏移截到 0，整句落到片头前的丢掉', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(200, 800, '消える'),
        _cue(1000, 2500, '一句目'),
      ];
      expect(
        buildLuaSubtitleMirrorSrt(cues, delayMs: 500),
        '1\n00:00:00,700 --> 00:00:01,300\n消える\n\n'
        '2\n00:00:01,500 --> 00:00:03,000\n一句目\n\n',
      );
      expect(
        buildLuaSubtitleMirrorSrt(cues, delayMs: -1200),
        '1\n00:00:00,000 --> 00:00:01,300\n一句目\n\n',
      );
    });

    test('零时长 / 倒置 / 空正文的 cue 不进镜像', () {
      expect(
        buildLuaSubtitleMirrorSrt(<AudioCue>[
          _cue(1000, 1000, 'a'),
          _cue(2000, 1500, 'b'),
          _cue(3000, 4000, '   '),
        ]),
        isEmpty,
      );
    });
  });

  group('isLuaSubtitleMirrorTrack', () {
    test('只认镜像标题，用户的真实轨不受影响', () {
      expect(
        isLuaSubtitleMirrorTrack(
          const SubtitleTrack('5', kLuaSubtitleMirrorTrackTitle, null),
        ),
        isTrue,
      );
      expect(
        isLuaSubtitleMirrorTrack(const SubtitleTrack('1', '日本語', 'jpn')),
        isFalse,
      );
      expect(isLuaSubtitleMirrorTrack(SubtitleTrack.no()), isFalse);
    });
  });

  // BUG-3325 审查：`sub-add … select` 后按 track-list 末尾认 id，TS / 网络流中途动态
  // 加流时认不回来，孤儿镜像轨越积越多；改为认当前选中的主字幕轨。
  group('resolveLuaSubtitleMirrorTrackId', () {
    test('当前选中轨就是镜像：记下它的 id', () {
      expect(
        resolveLuaSubtitleMirrorTrackId(
          selectedId: '7',
          selectedTitle: kLuaSubtitleMirrorTrackTitle,
        ),
        '7',
      );
    });

    test('选中的是别的轨（例如中途追加的 DVB 轨被选中）：不记', () {
      expect(
        resolveLuaSubtitleMirrorTrackId(
          selectedId: '9',
          selectedTitle: 'DVB subtitle',
        ),
        isNull,
      );
      expect(
        resolveLuaSubtitleMirrorTrackId(selectedId: '9', selectedTitle: ''),
        isNull,
      );
    });

    test('属性不可用 / 没有选中轨：不记', () {
      expect(
        resolveLuaSubtitleMirrorTrackId(
          selectedId: '',
          selectedTitle: kLuaSubtitleMirrorTrackTitle,
        ),
        isNull,
      );
      expect(
        resolveLuaSubtitleMirrorTrackId(
          selectedId: 'no',
          selectedTitle: kLuaSubtitleMirrorTrackTitle,
        ),
        isNull,
      );
    });
  });

  // BUG-3325 审查：写盘与 dispose / 换 Player 交错会把镜像 SRT 留在临时目录。
  group('discardLuaSubtitleMirrorFile', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('lua_mirror_discard_test_');
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('删除文件', () async {
      final File file = File(p.join(dir.path, 'm.srt'))
        ..writeAsStringSync('1\n');
      await discardLuaSubtitleMirrorFile(file);
      expect(file.existsSync(), isFalse);
    });

    test('等 after（Player 释放）完成后才删', () async {
      final File file = File(p.join(dir.path, 'm.srt'))
        ..writeAsStringSync('1\n');
      final Completer<void> released = Completer<void>();
      final Future<void> discarding = discardLuaSubtitleMirrorFile(
        file,
        after: released.future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(file.existsSync(), isTrue, reason: 'libmpv 还持有句柄时不能先删');
      released.complete();
      await discarding;
      expect(file.existsSync(), isFalse);
    });

    test('after 失败也照删；文件已不存在不抛', () async {
      final File file = File(p.join(dir.path, 'm.srt'))
        ..writeAsStringSync('1\n');
      await discardLuaSubtitleMirrorFile(
        file,
        after: Future<void>.error(StateError('dispose failed')),
      );
      expect(file.existsSync(), isFalse);
      await discardLuaSubtitleMirrorFile(file);
    });
  });

  group('shouldMirrorSubtitlesForLua', () {
    bool decide({
      bool scripts = true,
      bool cues = true,
      bool graphic = false,
      bool decoded = false,
      bool bluray = false,
    }) => shouldMirrorSubtitlesForLua(
      hasLoadedScripts: scripts,
      hasTextCues: cues,
      graphicSubtitleActive: graphic,
      playerDecodedSubtitleActive: decoded,
      blurayNavigationSession: bluray,
    );

    test('装了脚本 + Dart 侧文本 cue 才挂镜像', () {
      expect(decide(), isTrue);
      expect(decide(scripts: false), isFalse, reason: '没脚本零开销');
      expect(decide(cues: false), isFalse, reason: '没字幕没东西可镜像');
    });

    test('libmpv 已有真实 sid 时不挂（否则抢走图形轨 / 回流轨的选中）', () {
      expect(decide(graphic: true), isFalse);
      expect(decide(decoded: true), isFalse);
      expect(decide(bluray: true), isFalse, reason: '蓝光导航的轨归碟片菜单');
    });
  });
}
