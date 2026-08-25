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

  group('isExternalSubtitleFilePathForMenu', () {
    test('普通档案路径收下——含 provider 可能给出的非白名单扩展名', () {
      // BUG-1861：Jimaku / OpenSubtitles 的 fileName 只经 safeSubtitleFileName 防路径
      // 逃逸，不做扩展名白名单。拿扩展名当登记门 = 这些档下完之后在列表里彻底消失。
      for (final String path in <String>[
        '/docs/video_subtitles/a.srt',
        '/docs/video_subtitles/a.ass',
        '/docs/video_subtitles/a.sup',
        '/docs/video_subtitles/a.smi',
        '/docs/video_subtitles/a.ttml',
        '/docs/video_subtitles/A.SRT',
        '/docs/video_subtitles/no-extension-at-all',
      ]) {
        expect(isExternalSubtitleFilePathForMenu(path), isTrue, reason: path);
      }
    });

    test('源指针 / 哨兵 / 空串不收', () {
      expect(isExternalSubtitleFilePathForMenu('embedded:2'), isFalse);
      expect(isExternalSubtitleFilePathForMenu('off:'), isFalse);
      expect(isExternalSubtitleFilePathForMenu(''), isFalse);
      expect(isExternalSubtitleFilePathForMenu('   '), isFalse);
    });

    test('与 isImportedExternalSubtitlePath 是两件事，不得互相取代', () {
      // 后者判的是「一条**持久化值**能不能按路径直接重放」，扩展名是它的必要条件；
      // 它在换集恢复链路上还有消费方，这条测试钉住两者的行为差异不被合并掉。
      expect(isImportedExternalSubtitlePath('/d/a.sup'), isFalse);
      expect(isExternalSubtitleFilePathForMenu('/d/a.sup'), isTrue);
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
      // 扩展名同样不得成为登记的前置条件：provider 给的 fileName 不受白名单约束，
      // `.sup` / `.smi` / `.ttml` 一样落进 video_subtitles/，被扩展名门吃掉就等于
      // 「下完之后列表里连名字都看不到」，与两个调用点「坏档也该列出来」的约定矛盾。
      expect(body.contains('isImportedExternalSubtitlePath'), isFalse,
          reason: '登记不按扩展名门控（BUG-1861）；那条判据是给「持久化值能否按路径'
              '重放」用的，两者不得互相取代');
      expect(body.contains('isExternalSubtitleFilePathForMenu(path)'), isTrue,
          reason: '登记只滤掉源指针 / 哨兵 / 空串（BUG-1861）');
    });

    test('登记首行判 mounted（四个调用点全在 await 之后）', () {
      final String body = region(
        'void _registerImportedSubtitleSource(String path) {',
        '/// 字幕轨 / 副字幕轨行共用',
      );
      final int mountedGate = body.indexOf('if (!mounted) return;');
      expect(mountedGate, greaterThanOrEqualTo(0),
          reason: '_rebuild 是裸 setState；BUG-1861 去掉 _isRemote 早退后，远端两条导入'
              '路径首次成为可达的 setState 路径，await 期间退页即 setState-after-dispose');
      final int firstRebuild = body.indexOf('_rebuild(');
      expect(firstRebuild, greaterThan(mountedGate),
          reason: 'mounted 判必须在任何 _rebuild 之前');
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

    test('远端主 / 副字幕轨列表都给本机导入档留了行', () {
      // 只断「语料里有这一行」不够：主字幕那半修了、副字幕那半没修，`contains` 照样绿。
      // 两处各自切窗口断，再用总数钉死不多不少。
      const String row =
          'for (final SubtitleSource source in _importedSubtitleSources)';
      expect(row.allMatches(code).length, 2,
          reason: '远端主字幕轨行 + 远端副字幕轨行，各一处（BUG-1861）');
      final String primary = region(
        'Widget _buildSubtitleTrackRows(',
        'List<Widget> _buildSecondarySubtitleRows(',
      );
      expect(primary.contains(row), isTrue,
          reason: '远端主字幕行原本只有 YouTube 轨 / host sidecar / host 内封轨，本机'
              '下载的档案没有任何行能承载它——应用上了却在列表里找不到（BUG-1861）');
      final String secondary = region(
        'List<Widget> _buildSecondarySubtitleRows(',
        '/// 弹「字幕源」菜单',
      );
      expect(secondary.contains(row), isTrue,
          reason: '远端**副**字幕行是同一个洞的另一半：导入成功、副字幕生效、列表里'
              '找不到它也切不回来（BUG-1861）');
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
      final String remoteSecondaryImport = region(
        'Future<void> _pickAndImportRemoteSecondarySubtitle(',
        'Future<void> _clearRemoteSecondarySubtitle(',
      );
      expect(
        remoteSecondaryImport
            .contains('_registerImportedSubtitleSource(applyPath)'),
        isTrue,
        reason: '远端**副**字幕手动导入同样拷进 video_subtitles/，同样要登记，否则'
            '副字幕列表里没有承载它的行（BUG-1861）',
      );
    });

    test('换视频源时导入档一并清空（本地换源 + 远端换集两条路径）', () {
      const String clear = '_importedSubtitleSources = const <SubtitleSource>[]';
      // 计数必须**排除字段声明**：`List<SubtitleSource> _importedSubtitleSources =
      // const <SubtitleSource>[];` 也含这个子串。不排除的话声明本身就占掉一个名额，
      // `>= 2` 在「本地那处清空被整段删掉」时照样成立——这条断言就成了空转
      // （审查变异实测：删掉本地清空，全组依旧全绿）。
      const String decl = 'List<SubtitleSource> $clear';
      final int clears =
          clear.allMatches(code).length - decl.allMatches(code).length;
      expect(clears, 2,
          reason: '恰好两处清空：本地 _applyLoad 的换源分支 + 远端 _loadRemoteEpisode；'
              '多了说明又长出第三份作用域，少了说明有一条换源路径漏清（BUG-1861）');

      // 本地：清空必须落在 `clipExportSourceChanged` 那个块里（与枚举缓存同一作用域），
      // 而不是块外的某处——块外清等于每次 load 都清，同一视频重载也会把刚下的档冲掉。
      final String localReset = region(
        'if (clipExportSourceChanged) {',
        '_currentSubtitleSource = externalSubtitlePath ?? _currentSubtitleSource;',
      );
      expect(localReset.contains('_subtitleMenuSourcesPath = null;'), isTrue,
          reason: '窗口自校验：切出来的必须是 BUG-939 那个换源复位块，否则下面这条'
              '断言读的根本不是它（空操作变异）');
      expect(localReset.contains(clear), isTrue,
          reason: '本地换源必须清导入档，否则同页重载（_relinkMissingResource）后上一个'
              '源的档案会继续挂在列表上（BUG-1861）');

      final String remote = region(
        '_remoteSubtitleUserDismissed = false;',
        'final int initialPositionMs =',
      );
      expect(remote.contains(clear), isTrue,
          reason: '远端换集必须清导入档（远端 _currentVideoPath 恒 null，走不到本地换源'
              '分支的那次清空）');
    });
  });
}
