import 'package:test/test.dart';

import 'package:fushi/src/media/import/import_inbox.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart' show pickSidecar;
import 'package:path/path.dart' as p;

/// HBK-AUDIT-019 复审：[ImportInbox.planRootAdoption] 是纯函数，iOS（APFS 区分大小写）
/// 上才可能出现的「只差大小写的两个文件并存」在任何宿主文件系统上都能钉住。
void main() {
  List<String> plan(List<String> root, [List<String> existing = const []]) =>
      ImportInbox.planRootAdoption(rootNames: root, existingNames: existing);

  Set<String> lower(Iterable<String> names) => <String>{
    for (final String n in names) n.toLowerCase(),
  };

  test('只差大小写的两个视频不会被分到同一个目标名（rename 会无声覆盖）', () {
    final List<String> targets = plan(<String>['EP01.mkv', 'ep01.mkv']);
    expect(lower(targets), hasLength(2));
    expect(targets.first, 'EP01.mkv');
  });

  test('只差大小写的两个字幕也不会落到同一个目标名', () {
    final List<String> targets = plan(<String>[
      'EP01.mkv',
      'EP01.srt',
      'ep01.srt',
    ]);
    expect(lower(targets), hasLength(3));
    expect(targets.sublist(0, 2), <String>['EP01.mkv', 'EP01.srt']);
  });

  test('已有条目只差大小写也算占用：整组换 stem，不与旧视频交叉配对', () {
    expect(
      plan(<String>['EP01.mkv', 'EP01.srt'], <String>['ep01.MKV']),
      <String>['EP01 (2).mkv', 'EP01 (2).srt'],
    );
  });

  test('先分配的组占用的名字后面的组也避开', () {
    expect(
      plan(<String>['EP01 (2).mkv', 'EP01.mkv'], <String>['EP01.mkv']),
      <String>['EP01 (2).mkv', 'EP01 (3).mkv'],
    );
  });

  test('结果与输入一一对应、同序', () {
    expect(plan(<String>['b.srt', 'a.mkv', 'b.mkv', 'a.ja.srt']), <String>[
      'b.srt',
      'a.mkv',
      'b.mkv',
      'a.ja.srt',
    ]);
  });

  group('HBK-AUDIT-220：导入计划与播放器实际选字幕同一归属（最长主干认领）', () {
    /// 搬完后的目录里，每个视频按播放器规则（[pickSidecar]，学日语）选到的字幕必须
    /// 是它自己这一组带来的（或目录里原本就配它的），不能是别的视频的。
    void expectNoCrossPick({
      required List<String> root,
      List<String> existing = const <String>[],
      required Map<String, String?> ownSubtitleOf,
    }) {
      final List<String> targets = plan(root, existing);
      // 最长主干认领下这几种组合都不交叉，原名搬入、不出「(2)」。
      expect(targets, root, reason: '目标名');
      final List<String> dir = <String>[...existing, ...targets];
      final Map<String, String> targetOf = <String, String>{
        for (int i = 0; i < root.length; i++) root[i]: targets[i],
      };
      String nameAfter(String n) => targetOf[n] ?? n;
      ownSubtitleOf.forEach((String video, String? subtitle) {
        expect(
          pickSidecar(
            p.basenameWithoutExtension(nameAfter(video)),
            dir,
            langCode: 'ja',
          ),
          subtitle == null ? isNull : nameAfter(subtitle),
          reason: '$video 选中的字幕（目录：$dir）',
        );
      });
    }

    test('同一批：EP01.ja.mkv 带 EP01.ja.srt，EP01.mkv 带 EP01.srt', () {
      expectNoCrossPick(
        root: <String>['EP01.ja.mkv', 'EP01.ja.srt', 'EP01.mkv', 'EP01.srt'],
        ownSubtitleOf: <String, String?>{
          'EP01.ja.mkv': 'EP01.ja.srt',
          'EP01.mkv': 'EP01.srt',
        },
      );
    });

    test('同一批：较短 stem 的视频没有字幕时也不能选上别人的日语字幕', () {
      expectNoCrossPick(
        root: <String>['EP01.ja.mkv', 'EP01.ja.srt', 'EP01.mkv'],
        ownSubtitleOf: <String, String?>{
          'EP01.ja.mkv': 'EP01.ja.srt',
          'EP01.mkv': null,
        },
      );
    });

    test('已有 EP01.mkv：新来的 EP01.ja.mkv + EP01.ja.srt 不让旧视频配上新字幕', () {
      expectNoCrossPick(
        root: <String>['EP01.ja.mkv', 'EP01.ja.srt'],
        existing: <String>['EP01.mkv'],
        ownSubtitleOf: <String, String?>{
          'EP01.mkv': null,
          'EP01.ja.mkv': 'EP01.ja.srt',
        },
      );
    });

    test('已有 EP01.ja.mkv + EP01.ja.srt：新来的 EP01.mkv 不配走旧视频的字幕', () {
      expectNoCrossPick(
        root: <String>['EP01.mkv'],
        existing: <String>['EP01.ja.mkv', 'EP01.ja.srt'],
        ownSubtitleOf: <String, String?>{
          'EP01.mkv': null,
          'EP01.ja.mkv': 'EP01.ja.srt',
        },
      );
    });
  });
  test('同 stem 不同容器的旧视频带字幕：新视频整组改名（两个视频会同时认领）', () {
    expect(
      plan(
        <String>['EP01.mkv', 'EP01.srt'],
        <String>['EP01.mp4', 'EP01.ja.srt'],
      ),
      <String>['EP01 (2).mkv', 'EP01 (2).srt'],
    );
  });

  test('新组的字幕会被更长 stem 的旧视频认领时整组改名', () {
    // 旧 `EP01.ja.mkv` 会认领新来的 `EP01.ja.srt`（它对 `EP01` 也成立，但归最长的）。
    expect(
      plan(<String>['EP01.mkv', 'EP01.ja.srt'], <String>['EP01.ja.mkv']),
      <String>['EP01 (2).mkv', 'EP01 (2).ja.srt'],
    );
  });
}
