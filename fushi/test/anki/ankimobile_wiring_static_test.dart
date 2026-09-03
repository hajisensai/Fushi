import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS platform services use the AnkiMobile repository', () {
    final src =
        File('lib/src/platform/platform_services.dart').readAsStringSync();

    expect(
        src,
        contains(
            "import 'package:fushi/src/anki/ankimobile_repository.dart';"));
    expect(src, contains('if (Platform.isIOS)'));
    expect(src, contains('createAnkiRepository: AnkiMobileRepository.new'));
  });

  test('Riverpod Anki repository is created from PlatformServices', () {
    final src = File('lib/src/anki/anki_view_model.dart').readAsStringSync();

    expect(
        src,
        contains(
            "import 'package:fushi/src/platform/platform_providers.dart';"));
    expect(src, contains('ref.watch(platformServicesProvider)'));
    expect(src,
        isNot(contains('if (isAndroidPlatform) return AnkiRepository();')));
  });

  // AnkiMobile/iOS 是 BaseAnkiRepository 之外**另一份**「渲染前重建 context」的落卡路径。
  // packages/fushi_anki 里那条同名守卫只读包内 lib/src/base_anki_repository.dart，
  // 结构上照不到 fushi/ 下这一份——手抄逐字段重建在这里漏一个新字段（本次是
  // clipStartMs/clipEndMs），iOS 用户的卡就少一块，而全套测试仍绿。
  test('AnkiMobile 渲染路径用 withMediaRefs 而非手抄重建 AnkiMiningContext', () {
    final String src =
        File('lib/src/anki/ankimobile_repository.dart').readAsStringSync();
    final int renderStart = src.indexOf('_renderMinedFieldsForAnkiMobile({');
    expect(renderStart, greaterThan(-1), reason: '锚点漂移，守卫失效');
    // 结束锚必须先跳过命名参数表的收尾（本方法是 `\n  }) async {`）：直接从
    // renderStart 找 `\n  }` 会命中参数表，截出的 body 只有形参 → contains 恒 false、
    // 断言恒真。用 `\n  }) ` 同时覆盖 `}) {` 与 `}) async {` 两种收尾。
    final int paramsEnd = src.indexOf('\n  }) ', renderStart);
    expect(paramsEnd, greaterThan(renderStart), reason: '找不到命名参数表的收尾');
    final int renderEnd = src.indexOf('\n  }', paramsEnd + 5);
    expect(renderEnd, greaterThan(paramsEnd), reason: '找不到方法体收尾');
    final String body = src.substring(paramsEnd, renderEnd);
    // 自检：截出来的必须真是方法体，否则下面那条 isFalse 又变成空转。
    expect(
      body.contains('context.withMediaRefs('),
      isTrue,
      reason: 'AnkiMobile 渲染路径必须经 withMediaRefs 带全字段（锚点漂移也会红）',
    );
    expect(
      body.contains('AnkiMiningContext('),
      isFalse,
      reason: '又在 _renderMinedFieldsForAnkiMobile 里手抄 context 了——新字段迟早再漏',
    );
  });
}
