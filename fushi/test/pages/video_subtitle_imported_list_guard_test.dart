import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// BUG-1861：「获取的字幕能被应用上，但不会出现在列表里」。
///
/// BUG-1329 已经把「下载完当场并入列表」接上了，但那条并入路径带着一个前置门
/// （`_subtitleMenuSourcesPath != videoPath` → 直接 return，且 `_isRemote` 整个跳过）。
/// 于是三种情况下新档仍被静默丢弃：枚举在途（大容器 ffprobe 要数秒到数十秒）、枚举
/// 失败（缓存 key 永远不写）、换集后没再进过字幕分类。远端模式更彻底——字幕轨行只覆盖
/// YouTube 轨 / host sidecar / host 内封轨，本机下载的档案根本没有能承载它的行。
///
/// 修法是把两件事拆成两份独立真相：`_subtitleMenuSources` 只装枚举结果，
/// `_importedSubtitleSources` 装本会话落盘的档案，渲染时由
/// [mergeImportedSubtitleSourcesForMenu] 合并。下面一半是纯函数行为测试，一半是调用点
/// 静态守卫（media_kit 跑不了 headless，字幕轨行渲染进不了 widget 测试）。
void main() {
  group('mergeImportedSubtitleSourcesForMenu', () {
    SubtitleSource ext(String path) =>
        SubtitleSource.external(externalPath: path, label: path);

    test('导入档排在枚举结果之前', () {
      final List<SubtitleSource> merged = mergeImportedSubtitleSourcesForMenu(
        <SubtitleSource>[
          const SubtitleSource.embedded(streamIndex: 0, label: '内封 0'),
          ext('/videos/ep01.ja.srt'),
        ],
        <SubtitleSource>[ext('/docs/video_subtitles/jimaku.srt')],
      );
      expect(merged.length, 3);
      expect(merged.first.externalPath, '/docs/video_subtitles/jimaku.srt');
    });

    test('枚举结果为空（无内封轨 / 无 sidecar）时导入档仍然可见', () {
      // 这是用户报的那一屏：生肉视频枚举恒空，列表里就该只有刚下载的那一条。
      final List<SubtitleSource> merged = mergeImportedSubtitleSourcesForMenu(
        const <SubtitleSource>[],
        <SubtitleSource>[ext('/docs/video_subtitles/jimaku.srt')],
      );
      expect(merged.length, 1);
      expect(merged.single.externalPath, '/docs/video_subtitles/jimaku.srt');
    });

    test('同一路径不重复列出（导入档同时是视频同目录 sidecar）', () {
      final List<SubtitleSource> merged = mergeImportedSubtitleSourcesForMenu(
        <SubtitleSource>[ext('/videos/ep01.srt')],
        <SubtitleSource>[ext('/videos/./ep01.srt')],
      );
      expect(merged.length, 1);
    });

    test('导入档之间也按路径去重', () {
      final List<SubtitleSource> merged = mergeImportedSubtitleSourcesForMenu(
        const <SubtitleSource>[],
        <SubtitleSource>[
          ext('/docs/video_subtitles/a.srt'),
          ext('/docs/video_subtitles/./a.srt'),
        ],
      );
      expect(merged.length, 1);
    });

    test('无导入档时原样返回枚举结果（不复制、不重排）', () {
      final List<SubtitleSource> enumerated = <SubtitleSource>[
        const SubtitleSource.embedded(streamIndex: 0, label: '内封 0'),
      ];
      expect(
        identical(
          mergeImportedSubtitleSourcesForMenu(
            enumerated,
            const <SubtitleSource>[],
          ),
          enumerated,
        ),
        isTrue,
      );
    });

    test('内封源（无 externalPath）混进导入列表时被忽略而不是崩', () {
      final List<SubtitleSource> merged = mergeImportedSubtitleSourcesForMenu(
        const <SubtitleSource>[],
        <SubtitleSource>[
          const SubtitleSource.embedded(streamIndex: 1, label: '内封 1'),
        ],
      );
      expect(merged, isEmpty);
    });
  });

  group('sameSubtitleFilePath', () {
    test('归一化 `..` 与冗余分隔符后视为同一档案', () {
      expect(
        sameSubtitleFilePath('/a/b/../b/x.srt', '/a/b/x.srt'),
        isTrue,
      );
    });

    test('不同档案不误判', () {
      expect(sameSubtitleFilePath('/a/x.srt', '/a/y.srt'), isFalse);
    });
  });

  group('BUG-1861 调用点契约', () {
    final String src = readVideoFushiSource();
    final String code = maskCommentsAndScriptLines(src);

    String region(String startSig, String endSig) {
      final int start = src.indexOf(startSig);
      expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
      final int end = src.indexOf(endSig, start + startSig.length);
      expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
      return code.substring(start, end);
    }

    test('登记新档没有任何前置门', () {
      final String body = region(
        'void _registerImportedSubtitleSource(String path) {',
        '/// 字幕轨 / 副字幕轨行共用',
      );
      // 「这个档案就在盘上、刚被应用」不依赖枚举是否跑过、跑成没跑成，也不分本地/远端。
      // 任一符号回到这里都意味着又给登记加回了一个会静默丢档的前置条件（BUG-1861）。
      for (final String gate in <String>[
        '_subtitleMenuSourcesPath',
        '_currentVideoPath',
        '_isRemote',
      ]) {
        expect(body.contains(gate), isFalse,
            reason: '$gate 不得成为登记的前置条件：枚举在途 / 枚举失败 / 换集失配 / 远端'
                '四种情况下它都会把用户刚下载的字幕静默丢掉（BUG-1861）');
      }
      expect(body.contains('_importedSubtitleSources = <SubtitleSource>['),
          isTrue,
          reason: '新档写进独立的导入档列表，而不是枚举缓存——后到的枚举结果会整体覆盖'
              '枚举缓存，写那里等于让新档随时可能被冲掉（BUG-1861）');
    });

    test('本地字幕轨行与副字幕行都读合并后的列表', () {
      // 裸 `_subtitleMenuSources` 只有枚举结果，导入档不在里面。两处渲染都必须走
      // `_menuSubtitleSources`（= 枚举 ∪ 导入），否则下载的字幕在对应那一栏里消失。
      expect(
        'for (final SubtitleSource source in _menuSubtitleSources)'
            .allMatches(code)
            .length,
        2,
        reason: '主字幕轨行 + 副字幕轨行两处都要读合并列表（BUG-1861 / BUG-900）',
      );
      expect(
        code.contains('for (final SubtitleSource source in _subtitleMenuSources)'),
        isFalse,
        reason: '渲染不得再直接遍历纯枚举结果，那样导入档永远不显示（BUG-1861）',
      );
    });

    test('远端字幕轨列表给本机导入档留了行', () {
      expect(
        code.contains(
            'for (final SubtitleSource source in _importedSubtitleSources)'),
        isTrue,
        reason: '远端行原本只有 YouTube 轨 / host sidecar / host 内封轨，本机下载的档案'
            '没有任何行能承载它——应用上了却在列表里找不到（BUG-1861）',
      );
    });

    test('远端下载 / 导入两条落盘路径都登记', () {
      final String jimaku = region(
        'Future<void> _openJimakuDialog(VideoPlayerController controller) async {',
        'Future<void> _pickAndImportSubtitle(',
      );
      final int remoteBranch = jimaku.indexOf('await _applyRemoteSubtitle(');
      expect(remoteBranch, greaterThanOrEqualTo(0),
          reason: 'missing remote branch');
      expect(
        jimaku
            .substring(0, remoteBranch)
            .contains('_registerImportedSubtitleSource(downloaded)'),
        isTrue,
        reason: '远端 Jimaku 下载也要登记（BUG-1861）',
      );
      final String remoteImport = region(
        'Future<void> _pickAndImportRemoteSubtitle(',
        'Future<void> _applyRemoteSubtitle(',
      );
      expect(
        remoteImport.contains('_registerImportedSubtitleSource(applyPath)'),
        isTrue,
        reason: '远端手动导入也要登记（BUG-1861）',
      );
    });

    test('换视频源时导入档一并清空（本地换源 + 远端换集两条路径）', () {
      expect(
        '_importedSubtitleSources = const <SubtitleSource>[]'
            .allMatches(code)
            .length,
        greaterThanOrEqualTo(2),
        reason: '本地 _applyLoad 换源分支与远端 _loadRemoteEpisode 都要清，否则上一集'
            '下载的档案会挂在新集的字幕轨列表上（BUG-1861）',
      );
      final String remote = region(
        '_remoteSubtitleUserDismissed = false;',
        'final int initialPositionMs =',
      );
      expect(
        remote.contains('_importedSubtitleSources = const <SubtitleSource>[]'),
        isTrue,
        reason: '远端换集必须清导入档（远端 _currentVideoPath 恒 null，走不到本地换源'
            '分支的那次清空）',
      );
    });
  });
}
