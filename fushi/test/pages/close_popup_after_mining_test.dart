import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/after_mining_popup_action.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

/// 拍板台 8ldy3d8XFA（取代用户建议 q16Apecgbg 的全局开关）：「制卡后行为」按模块
/// 单选——留弹窗 / 关弹窗不续播 / 关弹窗并续播，视频默认关弹窗并续播。
/// [closePopupAfterAcceptedMine] 是两条弹窗车道（阅读器 base_source_page / 视频等
/// DictionaryPageMixin）唯一的关窗判据。
void main() {
  group('closePopupAfterAcceptedMine', () {
    /// 返回宿主收到的调用序列（'drop' = 撤查词暂停标记，'close' = 关栈；没动 = 空表）。
    Future<List<String>> run(
      MinePopupResult result,
      AfterMiningPopupAction action,
    ) async {
      final List<String> calls = <String>[];
      final Future<MinePopupResult> Function(Map<String, String>) wrapped =
          closePopupAfterAcceptedMine(
            (Map<String, String> f) async => result,
            action: () => action,
            dropPauseMark: () => calls.add('drop'),
            closeAll: () => calls.add('close'),
          );
      final MinePopupResult got = await wrapped(<String, String>{});
      expect(identical(got, result), isTrue, reason: '结果必须原样回传给 popup.js');
      return calls;
    }

    const MinePopupResult landed = MinePopupResult(ankiConnect: true);

    test('留弹窗：成功也不关', () async {
      expect(await run(landed, AfterMiningPopupAction.keepOpen), isEmpty);
    });

    test('关弹窗：先撤暂停标记再关栈（不续播）', () async {
      expect(await run(landed, AfterMiningPopupAction.close), <String>[
        'drop',
        'close',
      ]);
    });

    test('关弹窗并续播：只关栈，暂停标记留给关栈汇聚点续播', () async {
      expect(await run(landed, AfterMiningPopupAction.closeAndResume), <String>[
        'close',
      ]);
    });

    test('进了待发队列 / 后台也算收下', () async {
      expect(
        await run(
          const MinePopupResult.queued(),
          AfterMiningPopupAction.closeAndResume,
        ),
        <String>['close'],
      );
    });

    test('失败 / 重复不关（用户还要看提示、可能重试）', () async {
      for (final AfterMiningPopupAction action
          in AfterMiningPopupAction.values) {
        expect(await run(const MinePopupResult(), action), isEmpty);
        expect(
          await run(const MinePopupResult(duplicate: true), action),
          isEmpty,
        );
      }
    });

    test('关栈发生在制卡落地之后，不提前（BUG-2627：提前关栈会清掉草稿）', () async {
      final Completer<MinePopupResult> landing = Completer<MinePopupResult>();
      int closed = 0;
      bool hostEntered = false;
      final Future<MinePopupResult> pending = closePopupAfterAcceptedMine(
        (Map<String, String> f) {
          hostEntered = true;
          return landing.future;
        },
        action: () => AfterMiningPopupAction.close,
        dropPauseMark: () {},
        closeAll: () => closed++,
      )(<String, String>{});
      // BUG-2634：宿主的同步前缀在包装返回前已经跑完。
      expect(hostEntered, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(closed, 0);
      landing.complete(landed);
      await pending;
      expect(closed, 1);
    });
  });

  group('制卡后行为：按模块解析（8ldy3d8XFA）', () {
    AfterMiningPopupAction resolve(
      ModuleId module, {
      String? stored,
      bool legacy = false,
    }) => resolveAfterMiningPopupAction(
      module,
      stored: stored,
      legacyCloseAfterMining: legacy,
    );

    test('视频默认关弹窗并续播，不管旧开关', () {
      expect(resolve(ModuleId.video), AfterMiningPopupAction.closeAndResume);
      expect(
        resolve(ModuleId.video, legacy: true),
        AfterMiningPopupAction.closeAndResume,
      );
    });

    test('其余模块没开过旧开关 = 留弹窗（原默认）', () {
      for (final ModuleId module in kAfterMiningPopupModules) {
        if (module == ModuleId.video) continue;
        expect(
          resolve(module),
          AfterMiningPopupAction.keepOpen,
          reason: '$module',
        );
      }
    });

    test('开过旧开关：有播放的模块关并续播，没播放的模块只关', () {
      for (final ModuleId module in <ModuleId>[
        ModuleId.books,
        ModuleId.music,
      ]) {
        expect(
          resolve(module, legacy: true),
          AfterMiningPopupAction.closeAndResume,
          reason: '$module',
        );
      }
      for (final ModuleId module in <ModuleId>[
        ModuleId.manga,
        ModuleId.games,
        ModuleId.lookup,
      ]) {
        expect(
          resolve(module, legacy: true),
          AfterMiningPopupAction.close,
          reason: '$module',
        );
      }
    });

    test('用户选过的值优先于默认，视频也能改成留弹窗', () {
      expect(
        resolve(ModuleId.video, stored: 'keep'),
        AfterMiningPopupAction.keepOpen,
      );
      expect(
        resolve(ModuleId.video, stored: 'close'),
        AfterMiningPopupAction.close,
      );
      expect(
        resolve(ModuleId.books, stored: 'close_resume'),
        AfterMiningPopupAction.closeAndResume,
      );
    });

    test('未知值 / 该模块不给的档位回落默认', () {
      expect(
        resolve(ModuleId.video, stored: 'bogus'),
        AfterMiningPopupAction.closeAndResume,
      );
      expect(
        resolve(ModuleId.games, stored: 'close_resume'),
        AfterMiningPopupAction.keepOpen,
      );
      expect(
        afterMiningPopupOptions(ModuleId.games),
        isNot(contains(AfterMiningPopupAction.closeAndResume)),
      );
      expect(
        afterMiningPopupOptions(ModuleId.video),
        AfterMiningPopupAction.values,
      );
    });

    test('不属于任何一行的宿主归查词那行', () {
      expect(afterMiningPopupModuleFor(null), ModuleId.lookup);
      expect(afterMiningPopupModuleFor(ModuleId.srs), ModuleId.lookup);
      expect(afterMiningPopupModuleFor(ModuleId.video), ModuleId.video);
      expect(
        afterMiningPopupPrefKey(ModuleId.srs),
        afterMiningPopupPrefKey(ModuleId.lookup),
      );
    });

    test('偏好键与持久化串冻结，每行一个键', () {
      expect(
        <String>[
          for (final ModuleId module in kAfterMiningPopupModules)
            afterMiningPopupPrefKey(module),
        ],
        <String>[
          'after_mining_popup_books',
          'after_mining_popup_manga',
          'after_mining_popup_video',
          'after_mining_popup_music',
          'after_mining_popup_games',
          'after_mining_popup_lookup',
        ],
      );
      expect(
        <String>[
          for (final AfterMiningPopupAction action
              in AfterMiningPopupAction.values)
            action.wireName,
        ],
        <String>['keep', 'close', 'close_resume'],
      );
    });
  });

  group('两条弹窗车道接线', () {
    test('制卡回调都经 closePopupAfterAcceptedMine，按宿主模块取行为', () {
      for (final String path in <String>[
        'lib/src/pages/base_source_page.dart',
        'lib/src/pages/implementations/dictionary_page_mixin.dart',
      ]) {
        final String src = File(path).readAsStringSync();
        expect(
          RegExp(
            r'onMineEntry:\s*(cardCreationEnabled\s*\?\s*)?'
            r'closePopupAfterAcceptedMine\([\s\S]{0,240}?'
            r'action:\s*\(\)\s*=>\s*afterMiningPopupAction,',
          ).hasMatch(src),
          isTrue,
          reason: '$path 的 onMineEntry 必须包 closePopupAfterAcceptedMine 并读宿主行为',
        );
        expect(
          RegExp(
            r'dropPauseMark:\s*\(\)\s*\{\s*if \(mounted\) dropLookupPauseMark\(\);',
          ).hasMatch(src),
          isTrue,
          reason: '$path：「关弹窗不续播」要经宿主的 dropLookupPauseMark 撤查词暂停标记',
        );
        expect(
          src.contains('afterMiningPopupModuleFor(lookupHostModule)'),
          isTrue,
          reason: '$path：行为按宿主模块取，不再读全局开关',
        );
      }
    });

    test('会因查词暂停播放的查词宿主都覆写 dropLookupPauseMark（目录枚举）', () {
      // 宿主 = 混入 DictionaryPageMixin / 继承 BaseSourcePageState 的文件（连同它的
      // part 文件）；「会因查词暂停播放」= 持有查词暂停标记（pausedForLookup）或发出
      // 悬浮歌词查词的关卡续播信号（notifyLookupClosed）。漏覆写 = 「关闭、不续播」
      // 照样续播（审查发现的悬浮歌词漏洞即此类）。
      final RegExp hostDecl = RegExp(
        r'with DictionaryPageMixin|extends BaseSourcePageState<',
      );
      final RegExp pauses = RegExp(r'pausedForLookup|notifyLookupClosed\(\)');
      final RegExp override = RegExp(
        r'@override\s+void dropLookupPauseMark\(\)',
      );
      final List<String> checked = <String>[];
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String src = entity.readAsStringSync();
        if (!hostDecl.hasMatch(src)) continue;
        final StringBuffer all = StringBuffer(src);
        for (final RegExpMatch m in RegExp(
          r"^part '([^']+)';",
          multiLine: true,
        ).allMatches(src)) {
          final File part = File('${entity.parent.path}/${m.group(1)}');
          if (part.existsSync()) all.write(part.readAsStringSync());
        }
        final String text = all.toString();
        if (!pauses.hasMatch(text)) continue;
        checked.add(entity.path.replaceAll(r'\', '/'));
        expect(override.hasMatch(text), isTrue, reason: entity.path);
      }
      // 枚举本身别空转：已知会暂停的宿主必须都被扫到。
      for (final String known in <String>[
        'lib/src/pages/implementations/video_fushi_page.dart',
        'lib/src/pages/implementations/web_video_fushi_page.dart',
        'lib/src/pages/implementations/reader_fushi_page.dart',
        'lib/src/pages/implementations/music/music_lyrics_page.dart',
        'lib/src/media/audiobook/floating_lyric_lookup_host.dart',
      ]) {
        expect(checked, contains(known));
      }
    });

    test('悬浮歌词查词请求带来源模块：音乐桌面歌词归音乐', () {
      final String model = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      expect(
        RegExp(
          r'lookupPause\.lookupStarted\(\);\s*'
          r'FloatingLyricLookupNotifier\.instance\.requestLookup\([\s\S]{0,300}?'
          r'hostModule: ModuleId\.music,',
        ).hasMatch(model),
        isTrue,
      );
      expect(
        RegExp(
          r'lookupPauseDropped\.addListener\(\s*lookupPause\.dropPauseMark,',
        ).hasMatch(model),
        isTrue,
        reason: '音乐查词暂停方要订阅「撤暂停标记」信号',
      );
    });

    test('网页视频窗口宿主档：顶层查词窗口里制卡也按视频那行处理', () {
      final String src = File(
        'lib/src/pages/implementations/web_video_fushi_page.dart',
      ).readAsStringSync();
      final int start = src.indexOf('_mineFromGlobalLookup({');
      expect(start, greaterThan(0));
      final String body = src.substring(start, start + 900);
      expect(
        RegExp(r'_afterGlobalLookupMineAccepted\(\)').allMatches(body).length,
        2,
        reason: '回退纯字段制卡与入队两条路都要处理',
      );
      expect(
        RegExp(
          r'applyAfterMiningPopupAction\(\s*afterMiningPopupAction,\s*'
          r'dropPauseMark: dropLookupPauseMark,\s*'
          r'closeAll: GlobalLookupController\.instance\.dismissDesktopLookup,',
        ).hasMatch(src),
        isTrue,
      );
    });

    test('视频页不再写死「制卡后恒关弹窗」', () {
      final String page = File(
        'lib/src/pages/implementations/video_fushi_page.dart',
      ).readAsStringSync();
      expect(page.contains('closePopupAfterMining'), isFalse);
    });
  });

  // 反馈 OeS0m8tLHc：视频页点「制卡」卡在后台落地，弹窗不陪等。
  group('视频车道：制卡不陪等（OeS0m8tLHc）', () {
    final String mining = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync();
    final String tracker = File(
      'lib/src/pages/implementations/video_fushi/mine_queue.part.dart',
    ).readAsStringSync();
    final String remote = File(
      'lib/src/pages/implementations/video_fushi/playback_remote.part.dart',
    ).readAsStringSync();

    test('查词弹窗的新制卡不等落地：本地视频也走后台，只有遥控等结局', () {
      expect(
        mining.contains('bool awaitLocalLanding = false,'),
        isTrue,
        reason: '_onMineEntryImpl 默认（查词弹窗）不能等本地卡落地',
      );
      expect(
        mining.contains('awaitLocalLanding: awaitLocalLanding,'),
        isTrue,
        reason: '_onMineEntryImpl 必须把等不等交给 resolveVideoMineDispatch',
      );
      expect(
        remote.contains('_onMineEntryImpl(payload, awaitLocalLanding: true)'),
        isTrue,
        reason: '手机遥控制卡要把真实结局报回手机，仍等落地',
      );
      expect(
        mining.contains(
          'if (dispatch == VideoMineDispatch.awaitLanding) return land(await job);',
        ),
        isTrue,
      );
    });

    test('后台制卡失败：结果卡带「重试」（落地失败 / 抽取中止 / 抛错三条路）', () {
      expect(
        RegExp(
          r'expression: fields\[.expression.\],\s*retry: retry,',
        ).hasMatch(mining),
        isTrue,
        reason: '落地收尾 _landVideoMine 必须拿到 retry',
      );
      expect(
        RegExp(
          r'\}\),\s*retry: retry,\s*\);\s*return const MinePopupResult\.queued\(\);',
        ).hasMatch(mining),
        isTrue,
        reason: '后台任务抛错时 _trackBackgroundMine 也要能重试',
      );
      expect(
        mining.contains(
          'described.status == MineToastStatus.failed ? retry : null',
        ),
        isTrue,
        reason: '只有真失败挂重试，重复卡片不挂',
      );
      expect(
        mining.contains(
          '_showMineOsd(message, MineToastStatus.failed, null, retry);',
        ),
        isTrue,
        reason: '句子音频抽取中止也要能重试',
      );
      expect(
        tracker.contains(
          '_showMineOsd(message, MineToastStatus.failed, null, retry);',
        ),
        isTrue,
      );
      // 重试用点击当下冻结的那一帧，不借后来那次查词的对话框锁帧。
      expect(
        mining.contains('frozenCurrentFrame: currentFrameSnapshot,'),
        isTrue,
      );
      expect(
        mining.contains('t.video_mine_retry_cancelled_episode'),
        isTrue,
        reason: '换集后重试不能裁到新一集',
      );
    });
  });
}
