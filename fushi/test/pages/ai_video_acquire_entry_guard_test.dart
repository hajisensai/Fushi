import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2694：「AI 下视频」入口在 AI 未指派时整颗不渲染，新装用户（AI 没指派、
/// 下载 runtime 也常没起）在 Windows / Mac 上永远看不到它，也没有任何线索提示
/// 要先去「设置 › AI」指派。
///
/// 修法：入口门只剩平台合规（iOS 合规另由 ios_store_compliance_guard_test 钉），
/// 缺 AI 指派改在点击时推 AI 设置页，返回后已指派则继续进对话页。这组源码扫描
/// 钉住两侧，防止有人为了「没配就别显示」把 AI 判据加回入口门。
void main() {
  final String home = compactCode(
    File('lib/src/pages/implementations/home_page.dart').readAsStringSync(),
  );

  String bodyOf(String signature) {
    final int start = home.indexOf(signature);
    expect(start, isNot(-1), reason: '找不到 $signature');
    final int end = home.indexOf('Future<', start + signature.length);
    return home.substring(start, end == -1 ? home.length : end);
  }

  test('BUG-2694 入口门不再因 AI 未指派 / 下载 runtime 没起而隐藏入口', () {
    final int start = home.indexOf('boolget_canAiAcquire=>');
    expect(start, isNot(-1));
    final String gate = home.substring(start, home.indexOf(';', start));
    expect(gate, isNot(contains('resolveVideoAcquireAiProvider')));
    expect(gate, isNot(contains('videoResourceRegistry')));
    expect(gate, isNot(contains('videoDownloadPipelineService')));
  });

  test('入口仍尊重用户关掉的模块：AI 模块与下载模块', () {
    expect(
      home,
      contains('onAiAcquire:_canAiAcquire&&_aiAcquireModulesEnabled?'),
      reason: '模块门挂在入口渲染处，iOS 合规门 _canAiAcquire 另由合规守卫钉。',
    );
    final int start = home.indexOf('boolget_aiAcquireModulesEnabled=>');
    expect(start, isNot(-1));
    final String gate = home.substring(start, home.indexOf(';', start));
    expect(
      gate,
      contains('isAiModuleEnabled(appModel.moduleVisibility)'),
      reason: '关了 AI 模块 = 隐藏了设置 › AI，入口不得再把这页推出来。',
    );
    expect(gate, contains('moduleVisibility.isEnabled(ModuleId.browse)'));
  });

  test('互联 host 的 AI 助手与首页入口同一模块门：AI 模块关闭回「已关闭」', () {
    final String assembly = File(
      'lib/src/media/video/acquisition/app_video_acquisition_assembly.dart',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), '');
    final int start = assembly.indexOf('videoAcquireBlocker:');
    expect(start, isNot(-1));
    final int disabled = assembly.indexOf(
      'returnkHostAssistantReasonDisabled;',
      start,
    );
    final int noProvider = assembly.indexOf(
      'returnkHostAssistantReasonNoProvider;',
      start,
    );
    expect(disabled, greaterThan(start));
    expect(noProvider, greaterThan(disabled));
    expect(
      assembly.substring(start, disabled),
      contains('!isAiModuleEnabled(appModel.moduleVisibility)'),
      reason: '模块关闭必须先于「没配提供商」判出，否则对端被引向已隐藏的设置页。',
    );
  });

  test('BUG-2694 点击时 AI 未指派 → 推 AI 设置页，返回后重判再继续', () {
    final String open = bodyOf(
      'Future<void>_openAiVideoAcquisition([String?initialQuery])async{',
    );
    expect(
      open,
      contains(
        'if(resolveVideoAcquireAiProvider(appModelNoUpdate.prefsRepo)==null){'
        '_showVideoDiscoveryMessage(context,t.ai_assist_no_provider);'
        'await_pushAiSettings(context);'
        'if(!context.mounted||'
        'resolveVideoAcquireAiProvider(appModelNoUpdate.prefsRepo)==null){'
        'return;}}',
      ),
    );
    // 路由本体抽到 ai_settings_route.dart（「AI 下载」三域共用），首页只委托。
    expect(
      home,
      contains(
        'Future<void>_pushAiSettings(BuildContextcontext)=>'
        'pushAiSettingsPage(context);',
      ),
    );
    expect(
      compactCode(
        File(
          'lib/src/pages/implementations/ai_settings_route.dart',
        ).readAsStringSync(),
      ),
      contains('destinationId:SettingsDestinationId.ai,'),
      reason: '_pushAiSettings 必须落到「设置 › AI」目的地。',
    );
  });
}
