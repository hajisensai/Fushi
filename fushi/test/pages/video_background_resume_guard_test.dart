import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 窗口模式与全屏路由各自构造 media_kit [Video] 的文件（两处都得显式声明生命周期策略）。
const Map<String, String> kVideoConstructionSites = <String, String>{
  'lib/src/pages/implementations/video_fushi/layout.part.dart': '窗口模式',
  'lib/src/pages/implementations/video_fushi/fullscreen.part.dart': '全屏路由',
};

/// media_kit vendored fork 里 `Video` 的定义（默认值就长在这儿）。
const String kMediaKitVideoPath =
    '../third_party/media_kit_video/lib/src/video/video_texture.dart';

/// BUG-2544：视频切到后台被暂停后，回前台不自动续播（用户：「视频切屏会暂停，切回来没续上」）。
///
/// 根因是一条**不对称**的链：vendored media_kit 的 `Video` 默认
/// `pauseUponEnteringBackgroundMode: true` + `resumeUponEnteringForegroundMode: false`，
/// 于是它在 `paused`/`detached` 把正在播的视频停掉、把「暂停前在播」记进自己的私有字段，
/// 回前台那一支却被默认 false 整个跳过；而本页的 `resumed` 分支按「真后台不暂停播放」
/// 的旧假设写成，只重启计时器 / 刷解码链 / 收焦点，既不 play 也读不到那个私有字段。
/// 两边各自自洽，合起来就是「停了没人管」。
///
/// 修复是把这套策略从第三方收归页面（两处 `Video` 显式关掉自带的那套），故这里测两层：
/// 纯判据真值表 + 接线守卫。media_kit/libmpv 在测试宿主起不来，视频页没法 headless
/// widget 测（与 `video_resume_decode_refresh_guard_test.dart` 同一理由）；行为级证据由
/// `integration_test/video_background_resume_test.dart` 在真 app + 真 libmpv 上出。
void main() {
  group('shouldPauseForBackground', () {
    test('正在播 + 真播放器 → 进后台暂停', () {
      expect(
        VideoFushiPage.shouldPauseForBackground(
          isPlaying: true,
          hasNativePlayer: true,
        ),
        isTrue,
      );
    });

    test('进后台前本就暂停 → 不接管', () {
      // 这一条同时决定「回来要不要续播」：用户自己按了暂停再切走的，回来必须仍是
      // 暂停。不置标记是唯一的实现方式——反过来（无条件置位 + 回来判当前播放态）在
      // 后台期间无从区分「我们停的」和「用户停的」。
      expect(
        VideoFushiPage.shouldPauseForBackground(
          isPlaying: false,
          hasNativePlayer: true,
        ),
        isFalse,
      );
    });

    test('网页播放器（无真 Player）→ 不接管', () {
      // WebView2 里由站点自己播：pause/play 都是 no-op，接管只会记下一个永远兑现
      // 不了的标记。见 [VideoPlayerController.hasNativePlayer]。
      expect(
        VideoFushiPage.shouldPauseForBackground(
          isPlaying: true,
          hasNativePlayer: false,
        ),
        isFalse,
      );
    });

    test('两条都不成立 → 不接管', () {
      expect(
        VideoFushiPage.shouldPauseForBackground(
          isPlaying: false,
          hasNativePlayer: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldResumeAfterBackground', () {
    test('是我们因进后台停的 → 回前台续播', () {
      expect(
        VideoFushiPage.shouldResumeAfterBackground(
          pausedForBackground: true,
          pausedForLookup: false,
        ),
        isTrue,
      );
    });

    test('没被我们停过 → 不续播', () {
      // 覆盖「进后台前本就暂停」与「压根没进过后台」两种情形：两者都不置标记。
      expect(
        VideoFushiPage.shouldResumeAfterBackground(
          pausedForBackground: false,
          pausedForLookup: false,
        ),
        isFalse,
      );
    });

    test('查词/选词光标仍持有暂停 → 不续播', () {
      // 两条暂停源各自记账、各自恢复（那条的判据是 [shouldResumeAfterLookupDismiss]）。
      // 浮层还开着就把视频播起来，cue 会换掉、查词锚点当场失锚。
      expect(
        VideoFushiPage.shouldResumeAfterBackground(
          pausedForBackground: true,
          pausedForLookup: true,
        ),
        isFalse,
      );
    });

    test('查词持有暂停且没被我们停过 → 不续播', () {
      expect(
        VideoFushiPage.shouldResumeAfterBackground(
          pausedForBackground: false,
          pausedForLookup: true,
        ),
        isFalse,
      );
    });
  });

  group('BUG-2544 接线契约', () {
    final String src = readVideoFushiSource();
    final String code = maskCommentsAndScriptLines(src);

    String region(String startSig, String endSig) {
      final int start = src.indexOf(startSig);
      expect(start, greaterThanOrEqualTo(0), reason: 'missing $startSig');
      final int end = src.indexOf(endSig, start + startSig.length);
      expect(end, greaterThan(start),
          reason: 'missing $endSig after $startSig');
      return code.substring(start, end);
    }

    test('只有 paused 暂停播放，hidden 不暂停', () {
      final String body = region(
        'void didChangeAppLifecycleState(AppLifecycleState state) {',
        'case AppLifecycleState.resumed:',
      );
      // `hidden` 在移动端只是 `paused` 前的过渡态，在桌面却是「窗口最小化」的终态——
      // 桌面最小化历来不暂停视频（media_kit 那套也只认 paused/detached，桌面根本到
      // 不了）。共用一个 case body 时必须靠这条 `state ==` 门把两者分开，否则接管会
      // 顺手改掉桌面行为。
      expect(
        body.contains(
          'if (state == AppLifecycleState.paused) _pauseForBackground();',
        ),
        isTrue,
        reason: '真后台暂停必须只在 paused 触发，不能连 hidden 一起（BUG-2544）',
      );
    });

    test('resumed 分支续播，且排在解码链刷新之后', () {
      final String body = region(
        'case AppLifecycleState.resumed:',
        'case AppLifecycleState.detached:',
      );
      final int refresh = body.indexOf('_refreshDecodeAfterResumeIfNeeded()');
      final int resume = body.indexOf('_resumeAfterBackgroundIfNeeded()');
      expect(resume, greaterThanOrEqualTo(0),
          reason: '回前台必须走一次续播判断，否则就是 BUG-2544 本身');
      expect(refresh, greaterThanOrEqualTo(0));
      // 先 seek 重建解码链再 play：反过来用户会看见一小段用残缺参考帧解出的灰画面
      // （BUG-1863），随即被 seek 打断。
      expect(resume, greaterThan(refresh),
          reason: '续播要排在解码链刷新之后（BUG-1863 + BUG-2544）');
    });

    test('续播标记无条件清除，不会攒到下一次 resume', () {
      final String body = region(
        'void _resumeAfterBackgroundIfNeeded() {',
        'Future<void> _flushAllForProcessExit() async {',
      );
      final int read = body.indexOf('final bool pausedForBackground =');
      final int clear = body.indexOf('_pausedForBackground = false');
      expect(read, greaterThanOrEqualTo(0), reason: '必须先取快照再清');
      expect(clear, greaterThan(read));
      // 清除必须在任何 return 之前：塞进「判据成立」分支里，某次不满足条件的 resume
      // 就会把标记留到下一次，变成「某次切窗后视频莫名自己播起来」。
      final int firstReturn = body.indexOf('return');
      expect(firstReturn, greaterThan(clear),
          reason: '标记要在第一个 return 之前就清掉（BUG-2544）');
    });

    test('判据不在页面里被重新实现一遍', () {
      expect(code.contains('VideoFushiPage.shouldPauseForBackground('), isTrue,
          reason: '暂停判据是页面上的纯函数（可单测），不得另写一份（BUG-2544）');
      expect(
          code.contains('VideoFushiPage.shouldResumeAfterBackground('), isTrue,
          reason: '续播判据是页面上的纯函数（可单测），不得另写一份（BUG-2544）');
    });
  });

  group('BUG-2544 media_kit 生命周期参数', () {
    /// 匹配 media_kit `Video(` 构造（排除 `VideoController(` / `VideoState(` 等同前缀名）。
    final RegExp videoCtor = RegExp(r'(?<![A-Za-z0-9_$])Video\(');

    test('每一个 Video 构造点都显式声明了后台暂停策略', () {
      // 正向枚举而非只查已知两处：新增构造点（再开一个全屏/画中画路由之类）不写这个
      // 参数就会悄悄退回「后台暂停、回来不续」的构造器默认值，本条即为此而设。
      final List<String> sites = <String>[];
      final List<String> missing = <String>[];
      for (final FileSystemEntity entity
          in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String path = entity.path.replaceAll(r'\', '/');
        // 生成文件不归这类守卫管（Slang 的 strings.g.dart 里恰好有个同名 getter）。
        if (path.endsWith('.g.dart')) continue;
        final String raw = entity.readAsStringSync();
        // 先廉价子串预筛再掩码：lib/ 上千个文件，全量掩码要一分钟。
        if (!raw.contains('Video(')) continue;
        // 只看真正拿得到 media_kit `Video` 的文件：直接 import 的，或视频页的 part
        // （part 自己不写 import，符号来自主壳）。
        final bool importsMediaKit = raw.contains('media_kit_video');
        final bool isVideoPagePart =
            path.startsWith('lib/src/pages/implementations/video_fushi/');
        if (!importsMediaKit && !isVideoPagePart) continue;
        final String text =
            maskCommentsAndScriptLines(raw.replaceAll('\r\n', '\n'));
        if (!videoCtor.hasMatch(text)) continue;
        sites.add(path);
        if (!text.contains('pauseUponEnteringBackgroundMode:')) {
          missing.add(path);
        }
      }
      expect(sites, isNotEmpty, reason: '一个 Video 构造点都没扫到，扫描逻辑失效了');
      expect(missing, isEmpty,
          reason: '这些 Video 构造点没显式声明 pauseUponEnteringBackgroundMode，'
              '会退回 media_kit「后台暂停、回前台不恢复」的默认值（BUG-2544）：$missing');
      expect(sites.toSet(), kVideoConstructionSites.keys.toSet(),
          reason: 'Video 构造点集合变了。新增的那处要先确认生命周期策略与这里一致，'
              '再把它登记进 kVideoConstructionSites（BUG-2544）');
    });

    for (final MapEntry<String, String> site
        in kVideoConstructionSites.entries) {
      test('${site.value}的 Video 关掉了 media_kit 自带的后台暂停', () {
        final String text = maskCommentsAndScriptLines(
          File(site.key).readAsStringSync().replaceAll('\r\n', '\n'),
        );
        expect(text.contains('pauseUponEnteringBackgroundMode: false'), isTrue,
            reason: '生命周期暂停/续播由页面接管，自带的那套要整个关掉（BUG-2544）');
      });
    }

    test('vendored media_kit 的默认值仍是「暂停了不恢复」', () {
      // 这条不是要求上游改，而是钉住「为什么必须显式传」的前提：哪天 vendor 升级把
      // 默认值改成对称的，这里会红，提醒回来复核页面接管是否还有必要。
      final File file = File(kMediaKitVideoPath);
      expect(file.existsSync(), isTrue, reason: 'missing $kMediaKitVideoPath');
      final String text = maskCommentsAndScriptLines(
        file.readAsStringSync().replaceAll('\r\n', '\n'),
      );
      expect(
          text.contains('this.pauseUponEnteringBackgroundMode = true'), isTrue,
          reason: '默认仍是「进后台暂停」');
      expect(text.contains('this.resumeUponEnteringForegroundMode = false'),
          isTrue,
          reason: '默认仍是「回前台不恢复」——BUG-2544 的不对称就出在这里');
    });
  });
}
