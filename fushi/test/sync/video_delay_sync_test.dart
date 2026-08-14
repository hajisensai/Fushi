import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';

/// BUG-1620：互联远端视频字幕调轴跨设备同步的纯逻辑守卫。
///
/// - [resolveDelayLww]：「严格较新时间戳者胜、平局保守取 a 侧」。与
///   [resolvePositionLww] 分开的原因（位置的平局规则「取较大位置」对可负调轴
///   无意义）见函数 doc。
/// - 键公式冻结：`video_remote_delay_<uid>` / `video_remote_delay_at_<uid>`
///   已是持久化 wire 契约，改动即破坏已存数据（与
///   position_pref_keys_guard_test.dart 同角色）。
void main() {
  group('resolveDelayLww', () {
    test('严格较新时间戳者胜（双向），负值保真', () {
      expect(
        resolveDelayLww(
          aDelayMs: -1500,
          aUpdatedAtMs: 100,
          bDelayMs: 2000,
          bUpdatedAtMs: 200,
        ),
        (delayMs: 2000, updatedAtMs: 200),
      );
      expect(
        resolveDelayLww(
          aDelayMs: -1500,
          aUpdatedAtMs: 300,
          bDelayMs: 2000,
          bUpdatedAtMs: 200,
        ),
        (delayMs: -1500, updatedAtMs: 300),
      );
    });

    test('平局（含两侧都无戳的旧数据）保守取 a 侧——不适用位置的「较大者胜」', () {
      // 两侧都无戳：a = host 下发值（client 起播决议时），保留 BUG-996 跟随行为。
      expect(
        resolveDelayLww(
          aDelayMs: -700,
          aUpdatedAtMs: 0,
          bDelayMs: 0,
          bUpdatedAtMs: 0,
        ),
        (delayMs: -700, updatedAtMs: 0),
      );
      // 相同非零戳：a = host 已存值（收 PUT 时），仅严格较新才覆盖。
      expect(
        resolveDelayLww(
          aDelayMs: 111,
          aUpdatedAtMs: 500,
          bDelayMs: 999,
          bUpdatedAtMs: 500,
        ),
        (delayMs: 111, updatedAtMs: 500),
      );
    });
  });

  group('delay prefs 键公式冻结（wire/持久化契约）', () {
    test('键字符串逐字节冻结', () {
      expect(
          videoRemoteDelayPrefKey('video/u1'), 'video_remote_delay_video/u1');
      expect(
        videoRemoteDelayAtPrefKey('video/u1'),
        'video_remote_delay_at_video/u1',
      );
    });

    test('从值键反解 uid 时排除时间戳键（PositionPrefKeys 同款坑守卫）', () {
      expect(
        videoRemoteDelayPrefKeys.idFromPositionKey('video_remote_delay_abc'),
        'abc',
      );
      expect(
        videoRemoteDelayPrefKeys.idFromPositionKey('video_remote_delay_at_abc'),
        isNull,
        reason: '时间戳键更长前缀必须被排除，否则会解出以 at_ 开头的假 uid',
      );
    });

    test('clamp 界冻结（页面滑条 / host PUT 共用）', () {
      expect(kVideoSubtitleDelayLimitMs, 600000);
    });
  });

  group('RemoteVideoInfo delayUpdatedAtMs（wire 契约）', () {
    test('json 往返保真；旧 host 缺键回退 0（向后兼容）', () {
      const RemoteVideoInfo info = RemoteVideoInfo(
        id: 'video/x',
        title: 'X',
        delayMs: -1500,
        delayUpdatedAtMs: 1700000000000,
      );
      final RemoteVideoInfo back = RemoteVideoInfo.fromJson(info.toJson());
      expect(back.delayMs, -1500);
      expect(back.delayUpdatedAtMs, 1700000000000);
      // 旧 host 的 json 没有 delayUpdatedAtMs 键。
      final RemoteVideoInfo legacy = RemoteVideoInfo.fromJson(
          <String, Object?>{'id': 'video/x', 'title': 'X', 'delayMs': -1500});
      expect(legacy.delayMs, -1500);
      expect(legacy.delayUpdatedAtMs, 0,
          reason: '缺键 = host 无新主张，client 带戳本地值应在 LWW 胜出');
    });

    test('copyWith 透传新字段', () {
      const RemoteVideoInfo info = RemoteVideoInfo(id: 'a', title: 'A');
      final RemoteVideoInfo updated =
          info.copyWith(delayMs: 250, delayUpdatedAtMs: 42);
      expect(updated.delayMs, 250);
      expect(updated.delayUpdatedAtMs, 42);
      expect(info.copyWith().delayUpdatedAtMs, 0);
    });
  });
}
