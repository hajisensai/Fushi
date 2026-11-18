// 原盘会话的导航采样跟着播放位置连续跑；已解析轨道（3 次 `current-tracks/*` 读 + 一次
// 确认快照读）只在换标题 / 换轨 / 上次没解析全时才有新信息。这里钉住「什么时候必须
// 刷新」的判据，以及采样路径确实按它分流、脏源确实都接上了。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';

/// [source] 里从 [signature] 起到下一个同级成员声明之前的一段。
String _memberSource(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing $signature');
  final int next = source.indexOf('\n  }\n', start);
  expect(next, isNonNegative, reason: 'unterminated $signature');
  return source.substring(start, next);
}

void main() {
  group('VideoDiscTrackRefreshGate', () {
    test('新会话第一次采样必须刷新', () {
      final VideoDiscTrackRefreshGate gate = VideoDiscTrackRefreshGate();
      expect(
        gate.shouldRefresh(resolvedGeneration: null, titleGeneration: 1),
        isTrue,
      );
      expect(
        gate.shouldRefresh(resolvedGeneration: 1, titleGeneration: 1),
        isTrue,
      );
    });

    test('解析全了、没有轨道事件：后续采样不再刷新', () {
      final VideoDiscTrackRefreshGate gate = VideoDiscTrackRefreshGate()
        ..beginRefresh();
      for (int i = 0; i < 100; i++) {
        expect(
          gate.shouldRefresh(resolvedGeneration: 3, titleGeneration: 3),
          isFalse,
        );
      }
    });

    test('轨道事件标脏：下一次采样刷新一次，之后又不刷', () {
      final VideoDiscTrackRefreshGate gate = VideoDiscTrackRefreshGate()
        ..beginRefresh()
        ..markDirty();
      expect(
        gate.shouldRefresh(resolvedGeneration: 3, titleGeneration: 3),
        isTrue,
      );
      gate.beginRefresh();
      expect(
        gate.shouldRefresh(resolvedGeneration: 3, titleGeneration: 3),
        isFalse,
      );
    });

    test('刷新进行中来的轨道事件不丢：读完之后仍是脏的', () {
      final VideoDiscTrackRefreshGate gate = VideoDiscTrackRefreshGate()
        ..beginRefresh() // 开始读轨
        ..markDirty(); // 读的过程中又换了轨
      // 这一轮读完（已解析世代写回）后，补读那一轮仍要刷新。
      expect(
        gate.shouldRefresh(resolvedGeneration: 3, titleGeneration: 3),
        isTrue,
      );
    });

    test('换标题 / 世代 / 角度（标题世代前进）或上次没解析全：一直刷到解析全为止', () {
      final VideoDiscTrackRefreshGate gate = VideoDiscTrackRefreshGate()
        ..beginRefresh();
      // 标题世代前进，已解析世代还停在旧标题上。
      expect(
        gate.shouldRefresh(resolvedGeneration: 3, titleGeneration: 4),
        isTrue,
      );
      // 上次没解析全（音轨 / 字幕轨 id 读不到）→ 已解析世代为 null。
      gate.beginRefresh();
      expect(
        gate.shouldRefresh(resolvedGeneration: null, titleGeneration: 4),
        isTrue,
      );
      gate.beginRefresh();
      expect(
        gate.shouldRefresh(resolvedGeneration: null, titleGeneration: 4),
        isTrue,
      );
      gate.beginRefresh();
      expect(
        gate.shouldRefresh(resolvedGeneration: 4, titleGeneration: 4),
        isFalse,
      );
    });
  });

  group('采样路径接线（源码守卫）', () {
    final String source = File(
      'lib/src/media/video/video_disc_menu.part.dart',
    ).readAsStringSync();

    test('逐次采样只在判据说要刷新时才读轨道', () {
      final String read = _memberSource(source, 'Future<void> _readDiscMenu(');
      final RegExp gated = RegExp(
        r'if \(next\.isTitle &&\s*_discTrackRefreshGate\.shouldRefresh\(\s*'
        r'resolvedGeneration: _discResolvedTracksGeneration,\s*'
        r'titleGeneration: _discTitleGeneration,\s*\)\) \{\s*'
        r'if \(!await _refreshDiscResolvedTracks\(',
      );
      expect(gated.hasMatch(read), isTrue);
      expect(
        '_refreshDiscResolvedTracks('.allMatches(read),
        hasLength(1),
        reason: '采样路径上只能有这一处读轨道',
      );
    });

    test('刷新那一轮：先清脏位再读，并保留确认快照读', () {
      final String refresh = _memberSource(
        source,
        'Future<bool> _refreshDiscResolvedTracks(',
      );
      final int begin = refresh.indexOf(
        '_discTrackRefreshGate.beginRefresh();',
      );
      final int firstRead = refresh.indexOf('getPropertyAsync(');
      expect(begin, isNonNegative);
      expect(begin, lessThan(firstRead));
      expect(refresh, contains("'disc-navigation-state-json'"));
      expect(
        refresh,
        contains('videoDiscTitleIdentityMatches(expected, confirmed)'),
      );
    });

    test('脏源：track-list 与三个 current-tracks 属性的比值订阅、轨道流、盘命令、轨道归属、复位', () {
      // `track-list` 不能少：字幕 / 音轨切到「无」时 `current-tracks/*` 变为不可用，
      // 比值订阅不回调；media_kit 的轨道流按轨道 id 去重，选中状态变化也不发。真 libmpv
      // 行为钉在 test/third_party/media_kit_observe_changes_test.dart。
      expect(kVideoDiscResolvedTrackProperties, <String>[
        'track-list',
        'current-tracks/audio/id',
        'current-tracks/sub/id',
        'current-tracks/sub/codec',
      ]);
      final RegExp observers = RegExp(
        r'for \(final String property in kVideoDiscResolvedTrackProperties\) \{\s*'
        r'await native\.observePropertyChanges\(property, \(String _\) async \{\s*'
        r'if \(identical\(_player, player\) && isBlurayNavigationSession\) \{\s*'
        r'_discTrackRefreshGate\.markDirty\(\);\s*'
        r'unawaited\(_sampleDiscMenu\(player, _loadToken\)\);',
      );
      expect(observers.hasMatch(source), isTrue);
      for (final String signature in <String>[
        'void _onDiscTracksChanged(Player player) {',
        'Future<bool> _sendDiscCommand(List<String> command) async {',
        'void claimDiscTrackOwnership() {',
        'void _resetDiscMenu() {',
      ]) {
        expect(
          _memberSource(source, signature),
          contains('_discTrackRefreshGate.markDirty();'),
          reason: signature,
        );
      }
    });
  });
}
