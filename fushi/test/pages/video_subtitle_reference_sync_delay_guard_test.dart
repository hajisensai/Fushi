import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 「按内嵌字幕轨对齐」与调轴的契约（#1714 接替 PR，所有者 2026-09-28 拍板：对齐后
/// 调轴归零，系列级 delay 对已对齐字幕不生效）。
///
/// media_kit 跑不了 headless，这里锁调用点契约（注释已掩掉，注释掉调用点骗不过）：
///  - 选源写入点 `_currentSubtitleSource` 是 setter，每次改写都重算对齐判据；
///  - 首开 / 换集在应用调轴前按本次实际选中的档重算；
///  - 对齐产物生效期间的微调不落盘（落盘会写进系列级，推歪同系列其它集）；
///  - 手动入口登记对齐产物、换集后不落结果、确认弹窗走 guardOverlay + showAppDialog。
void main() {
  final String src = readVideoFushiSource();
  final String code = maskCommentsAndScriptLines(src);

  String region(String startSig, String endSig) {
    final int start = src.indexOf(startSig);
    expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
    final int end = src.indexOf(endSig, start + startSig.length);
    expect(end, greaterThan(start), reason: 'missing $endSig after $startSig');
    return code.substring(start, end);
  }

  test('选源写入点是 setter：每次改写都重算「对齐产物 → 调轴归零」', () {
    final String setter = region(
      'set _currentSubtitleSource(String? value)',
      'String? _currentSubtitleSourceValue;',
    );
    expect(setter, contains('_currentSubtitleSourceValue = value;'));
    expect(setter, contains('_refreshPrimarySubtitleAlignment(value)'));
    // 只能有一个真字段，别的地方不许绕过 setter 直写。
    expect(
      RegExp(r'String\?\s+_currentSubtitleSource\s*;').hasMatch(code),
      isFalse,
    );
  });

  test('重算：对齐产物 → 暂存持久化调轴并归零；换回别的档 → 恢复', () {
    final String body = region(
      'Future<void> _refreshPrimarySubtitleAlignment(String? source)',
      '\n  }\n',
    );
    expect(body, contains('isSubtitleAlignmentProduct(source)'));
    expect(body, contains('generation != _subtitleAlignmentCheckGeneration'));
    expect(body, contains('_delayBeforeAlignedSubtitleMs = _delayMs;'));
    expect(body, contains('_delayMs = 0;'));
    expect(body, contains('_delayMs = _delayBeforeAlignedSubtitleMs;'));
    expect(body, contains('_controller?.setDelayMs(_delayMs);'));
  });

  test('首开 / 换集：应用调轴之前按本次选中的档重算', () {
    final int refresh = code.indexOf(
      'await _refreshPrimarySubtitleAlignment(\n'
      '      externalSubtitlePath ?? _currentSubtitleSource,',
    );
    final int apply = code.indexOf('controller.setDelayMs(_delayMs);');
    expect(refresh, greaterThan(0));
    expect(apply, greaterThan(refresh));
    // 按持久化值重设调轴前作废旧结论与在途检查。
    final String load = region(
      '_currentAudioTrackId = row.audioTrackId;',
      '_delayMs = row.delayMs;',
    );
    expect(load, contains('_primarySubtitleAligned = false;'));
    expect(load, contains('_subtitleAlignmentCheckGeneration++;'));
  });

  test('对齐产物生效期间的微调不落盘（不写系列级 / 本集）', () {
    final String body = region(
      'Future<void> _setDelayMs(int delayMs) async {',
      'Future<void> _setSecondaryDelayMs(',
    );
    final int guard = body.indexOf('if (_primarySubtitleAligned) {');
    expect(guard, greaterThan(0));
    expect(body.indexOf('updateCollectionSubtitleDelayMs'), greaterThan(guard));
    expect(body.indexOf('updateDelayMs(_activeBookUid'), greaterThan(guard));
    expect(body.indexOf('videoRemoteDelayPrefKey'), greaterThan(guard));
  });

  test('手动入口：登记对齐产物后导入并重算；抽轨 / 确认后换了集就不落结果', () {
    final String body = region(
      'Future<void> _alignSubtitleFileToEmbeddedTracks(',
      'String? _currentExternalSubtitlePath()',
    );
    final int save = body.indexOf(
      'saveSubtitleAlignmentOriginal(original: bytes, aligned: aligned)',
    );
    final int import = body.indexOf('_importSubtitleVariant(');
    final int refresh = body.indexOf(
      '_refreshPrimarySubtitleAlignment(_currentSubtitleSource)',
    );
    expect(save, greaterThan(0));
    expect(import, greaterThan(save));
    expect(refresh, greaterThan(import));
    expect(
      RegExp(r'_stillOnVideo\(videoPath\)').allMatches(body).length,
      greaterThanOrEqualTo(3),
    );
  });

  test('确认弹窗：guardOverlay + showAppDialog，不裸调 showDialog', () {
    final String body = region(
      'Future<bool> _confirmReferenceSync({',
      'bool _stillOnVideo(String videoPath)',
    );
    expect(body, contains('_focusOwnership.guardOverlay('));
    expect(body, contains('showAppDialog<bool>('));
    expect(body, isNot(contains('showDialog<')));
  });
}
