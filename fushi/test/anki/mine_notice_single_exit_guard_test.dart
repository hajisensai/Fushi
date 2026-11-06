import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/mine_failure_notice.dart';
import 'package:fushi/src/utils/misc/toast_severity.dart';

import '../helpers/source_guard.dart';

/// 反馈 3aFpRYC6a1 / jYEPxVSrts / iH6RY1kqQn：关了「制卡提示」开关仍在弹。
///
/// `da9250e5bd` 把开关挂在 `FushiToast.showMine`，但制卡结果还有别的说出口：
/// * 阅读器 / 悬浮词典 / AppModel 悬浮导出直接 `FushiToast.show(severity:
///   mineToastSeverity(...))`——关掉成功提示后阅读时照样弹（iH6RY1kqQn）；
/// * 查词弹窗按钮旁的就地提示（`MinePopupResult.failed(message:)` → popup.js）——
///   重复卡片的「重复卡片，未导出」不经开关（3aFpRYC6a1）；
/// * 视频页 OSD 直接 `_showOsd(severity: mineToastSeverity(...))`。
///
/// 结构修复：裁决只在 [MineNotices.shown] 一处，三个出口（showMine / settle /
/// `_showMineOsd`）都先问它。这里钉行为，再扫源码防新代码绕过出口。
void main() {
  group('弹窗就地提示（MineFailureNotice.settle）过开关', () {
    final List<(String, MineToastStatus)> toasts =
        <(String, MineToastStatus)>[];

    setUp(() {
      toasts.clear();
      MineFailureNotice.debugToastSink = (String m, MineToastStatus s) =>
          toasts.add((m, s));
    });

    tearDown(() {
      MineFailureNotice.debugToastSink = null;
      MineNotices.filter = (MineToastStatus _) => true;
    });

    void configure({required bool duplicate, bool success = true}) {
      MineNotices.filter = (MineToastStatus s) =>
          mineToastShown(s, showSuccess: success, showDuplicate: duplicate);
    }

    const Map<String, Object?> duplicateReply = <String, Object?>{
      'ankiConnect': false,
      'noteId': null,
      'duplicate': true,
      'message': '重复卡片，未导出。',
    };
    const Map<String, Object?> failedReply = <String, Object?>{
      'ankiConnect': false,
      'noteId': null,
      'message': '未配置 Anki',
    };

    test('重复提示开着（默认）：弹窗在屏上 → 原样交给弹窗就地说', () {
      configure(duplicate: true);
      expect(
        MineFailureNotice.settle(duplicateReply, originOnScreen: true),
        duplicateReply,
      );
      expect(toasts, isEmpty);
    });

    test('重复提示开着：弹窗已不在 → 宿主 toast 一次', () {
      configure(duplicate: true);
      final Map<String, Object?> settled = MineFailureNotice.settle(
        duplicateReply,
        originOnScreen: false,
      );
      expect(settled.containsKey('message'), isFalse);
      expect(settled[MineFailureNotice.hostReportedKey], isTrue);
      expect(toasts, <(String, MineToastStatus)>[
        ('重复卡片，未导出。', MineToastStatus.duplicate),
      ]);
    });

    for (final bool onScreen in <bool>[true, false]) {
      test('重复提示关掉：弹窗${onScreen ? '在' : '不在'}屏上都不说，✓ 状态照旧', () {
        configure(duplicate: false);
        final Map<String, Object?> settled = MineFailureNotice.settle(
          duplicateReply,
          originOnScreen: onScreen,
        );
        expect(
          settled.containsKey('message'),
          isFalse,
          reason: '带着 message popup.js 就会在按钮旁说「重复卡片」',
        );
        expect(
          settled[MineFailureNotice.hostReportedKey],
          isTrue,
          reason:
              'hostReported = 宿主已裁决，popup.js 不画任何提示'
              '（否则缺 message 时会退回通用的「导出卡片失败」）',
        );
        expect(settled['duplicate'], isTrue, reason: '按钮仍按真实状态画 ✓');
        expect(toasts, isEmpty);
      });
    }

    test('重复提示关掉：宿主没带 message 的重复回包也静音（视频页）', () {
      configure(duplicate: false);
      final Map<String, Object?> settled = MineFailureNotice.settle(
        const <String, Object?>{'ankiConnect': false, 'duplicate': true},
        originOnScreen: true,
      );
      expect(settled[MineFailureNotice.hostReportedKey], isTrue);
    });

    test('失败恒说：两个开关都关，失败原因照样交给弹窗', () {
      configure(duplicate: false, success: false);
      expect(
        MineFailureNotice.settle(failedReply, originOnScreen: true),
        failedReply,
      );
    });

    test('mineFailureUnseen 回流的重复提示同样过开关', () {
      configure(duplicate: false);
      MineFailureNotice.reportUnseen(<String, Object?>{
        'message': '重复卡片，未导出。',
        'duplicate': true,
      });
      expect(toasts, isEmpty);
      MineFailureNotice.reportUnseen(<String, Object?>{'message': 'boom'});
      expect(toasts, <(String, MineToastStatus)>[
        ('boom', MineToastStatus.failed),
      ]);
    });
  });

  group('源码守卫：制卡结果只从过开关的出口说', () {
    /// 出现在调用实参里就说明这是一条制卡结果通知。
    const List<String> mineMarkers = <String>[
      'mineToastSeverity(',
      'mineToastPalette(',
      'describeMineOutcome(',
      'described.',
      'MineToastStatus.',
      't.card_duplicate',
      't.card_exported',
      't.card_overwritten',
      't.card_mining_pending',
      't.video_remote_mined',
      't.anki_pending_mine_queued',
    ];

    int matchingParen(String masked, int open) {
      int depth = 0;
      for (int i = open; i < masked.length; i++) {
        final String c = masked[i];
        if (c == '(') depth++;
        if (c == ')') {
          depth--;
          if (depth == 0) return i;
        }
      }
      return masked.length - 1;
    }

    /// [callee] 每一次调用的实参源码（注释与字符串内容已掩掉）。
    Iterable<({int offset, String args})> callArgs(
      String masked,
      RegExp callee,
    ) sync* {
      for (final RegExpMatch m in callee.allMatches(masked)) {
        final int open = m.end - 1;
        yield (
          offset: m.start,
          args: masked.substring(open, matchingParen(masked, open) + 1),
        );
      }
    }

    /// `_showMineOsd` 本身就是那个出口，它内部的 `_showOsd` 豁免。
    (int, int)? showMineOsdBody(String masked) {
      final int start = masked.indexOf('void _showMineOsd(');
      if (start < 0) return null;
      final int open = masked.indexOf('{', start);
      int depth = 0;
      for (int i = open; i < masked.length; i++) {
        if (masked[i] == '{') depth++;
        if (masked[i] == '}') {
          depth--;
          if (depth == 0) return (open, i);
        }
      }
      return null;
    }

    test('lib/ 下没有直接 FushiToast.show / _showOsd 说制卡结果', () {
      // `FushiToast.show(`，但不是 `showMine(`。
      final RegExp toastShow = RegExp(r'FushiToast\s*\.\s*show\s*\(');
      final RegExp osdShow = RegExp(r'(?<![\w])_showOsd\s*\(');
      final List<String> offenders = <String>[];
      int scannedToastCalls = 0;
      for (final FileSystemEntity f in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.endsWith('.g.dart')) continue;
        final String masked = maskCommentsAndStrings(f.readAsStringSync());
        final (int, int)? exempt = showMineOsdBody(masked);
        for (final (RegExp, String) callee in <(RegExp, String)>[
          (toastShow, 'FushiToast.show'),
          (osdShow, '_showOsd'),
        ]) {
          for (final ({int offset, String args}) call in callArgs(
            masked,
            callee.$1,
          )) {
            if (callee.$2 == 'FushiToast.show') scannedToastCalls++;
            if (exempt != null &&
                call.offset > exempt.$1 &&
                call.offset < exempt.$2) {
              continue;
            }
            final String? hit = mineMarkers
                .where(call.args.contains)
                .cast<String?>()
                .firstWhere((_) => true, orElse: () => null);
            if (hit != null) {
              final int line =
                  '\n'.allMatches(masked.substring(0, call.offset)).length + 1;
              offenders.add('${f.path}:$line ${callee.$2}(… $hit …)');
            }
          }
        }
      }
      expect(
        scannedToastCalls,
        greaterThan(300),
        reason: '扫描面失效（路径 / 正则变了）会让守卫恒绿',
      );
      expect(
        offenders,
        isEmpty,
        reason:
            '制卡结果通知必须走 FushiToast.showMine（toast）/ _showMineOsd（视频 OSD），'
            '它们先过「制卡提示」开关；直接 show / _showOsd 会让关掉的提示照样弹。',
      );
    });

    test('三个出口都先问 MineNotices.shown', () {
      final String toast = File(
        'lib/src/utils/misc/fushi_toast.dart',
      ).readAsStringSync();
      expect(
        toast,
        contains('if (!mineNoticeFilter(status)) return;'),
        reason: 'showMine 必须先过开关',
      );
      expect(
        compactCode(toast),
        contains('getmineNoticeFilter=>MineNotices.filter'),
        reason: 'entry point 装的闭包必须落到唯一裁决点',
      );
      final String osd = File(
        'lib/src/pages/implementations/video_fushi/volume_osd.part.dart',
      ).readAsStringSync();
      expect(
        compactCode(osd),
        contains('if(!MineNotices.shown(status))return;'),
      );
      final String notice = File(
        'lib/src/anki/mine_failure_notice.dart',
      ).readAsStringSync();
      expect(compactCode(notice), contains('!MineNotices.shown('));
    });
  });
}
