import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final java = File(
    'android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java',
  ).readAsStringSync();
  final repo = File(
    '../packages/fushi_anki/lib/src/ankidroid/anki_repository.dart',
  ).readAsStringSync();

  group('AnkiDroid native create path is schema-driven', () {
    test('native handler has createNoteType + createDeck cases', () {
      expect(java, contains('case "createNoteType"'));
      expect(java, contains('case "createDeck"'));
      expect(java, contains('addNewCustomModel'));
      expect(java, contains('addNewDeck'));
    });

    test('legacy hardcoded Lapis model is gone', () {
      expect(java.contains('case "addDefaultModel"'), isFalse);
      expect(java.contains('"Cloze Before"'), isFalse,
          reason: 'old Term/Meaning hardcoded schema must be removed');
      expect(java.contains('"Expanded Meaning"'), isFalse);
    });

    test('Dart repo invokes the schema-driven channel methods', () {
      // 不要求 `invokeMethod('createNoteType'` 连写：那钉的是**写法**不是不变式，
      // 参数一多换个行就红（BUG-2380 拆多行时正是如此）。要钉的是「这两个 channel
      // method 名确实被 invokeMethod 调用了」。
      expect(repo, contains('invokeMethod('));
      expect(repo, contains("'createNoteType'"));
      expect(repo, contains("'createDeck'"));
      expect(repo, contains('noteTypeFields'));
    });
  });

  group('settings page wires the Create Lapis action', () {
    final page = File(
      'lib/src/pages/implementations/anki_settings_page.dart',
    ).readAsStringSync();
    // BUG-1902：这一行的实现搬进了共享组件 `anki/anki_config_controls.dart`，
    // 好让新手引导用**同一份**实现（此前它是本页的私有方法，跨文件不可见，引导页
    // 只能显示三行只读文本）。守卫跟着实现走：页面负责挂载，组件负责调用与文案。
    final controls = File(
      'lib/src/anki/anki_config_controls.dart',
    ).readAsStringSync();

    test('page mounts the shared row and the row calls createLapisSetup', () {
      expect(page, contains('AnkiCreateLapisRow('));
      expect(controls, contains('createLapisSetup()'));
      expect(controls, contains('t.anki_create_lapis'));
    });
  });

  // BUG-2380：这一组是**本文件原有守卫漏掉的那一半**。上面那条只断言
  // `addNewDeck` / `addNewCustomModel` 这些字符串在不在，而 bug 期间它们一直都在
  // ——被丢掉的是它们的**返回值**（provider 建失败时返回 null）。字符串存在性守卫
  // 对此全程绿灯，用户拿到的却是「创建成功」+ 选中了自己的牌组。
  //
  // 这里改钉「返回值被用上了」这个不变式。native 没有任何 JVM 测试，源码扫描是
  // 目前最强的可落地层。
  group('BUG-2380 native create paths must not swallow a failed creation', () {
    test('createDeck 判 addNewDeck 的 null 并报 CREATE_DECK_FAILED', () {
      expect(java, contains('api.addNewDeck(deckName) == null'),
          reason: 'addNewDeck 返回 null = 建组失败，必须判空，'
              '不能像旧实现那样裸调用后无条件 success');
      expect(java, contains('result.error("CREATE_DECK_FAILED"'));
    });

    test('createNoteType 判 addNewCustomModel 的 null', () {
      expect(java, contains('if (modelId == null)'),
          reason: 'addNewCustomModel 返回 null = 建笔记类型失败，必须判空');
      expect(java, contains('result.error("CREATE_MODEL_FAILED"'));
    });

    test('两条创建路径都把「新建 / 本来就有」如实回给 Dart', () {
      // 旧实现一律 success(null)，Dart 只能自己再查一遍清单去猜——而它那份判据
      // 与 native 的不一致（native 大小写不敏感 / 按名字+字段数，Dart 精确相等）。
      expect(java, contains('result.success(false)'));
      expect(java, contains('result.success(true)'));
      expect(java, contains('result.success(createNoteType('));
    });

    test('Dart 侧不再自带第二份存在性判据', () {
      // 判据只留 native 一处；Dart 再查一遍就会与 native 分歧，分歧时
      // 「Dart 要求创建 → native 静默跳过 → 报成功」是本 bug 的第二段根因。
      final int createDeckStart = repo.indexOf('Future<bool> createDeck(');
      expect(createDeckStart, greaterThan(-1));
      final String createDeckBody =
          repo.substring(createDeckStart, createDeckStart + 500);
      expect(createDeckBody.contains("invokeMethod('getDecks')"), isFalse,
          reason: 'createDeck 不该自己再查一遍牌组清单');

      final int createNoteTypeStart =
          repo.indexOf('Future<bool> createNoteType(');
      expect(createNoteTypeStart, greaterThan(-1));
      final String createNoteTypeBody =
          repo.substring(createNoteTypeStart, createNoteTypeStart + 700);
      expect(createNoteTypeBody.contains("invokeMethod('getModelList')"),
          isFalse,
          reason: 'createNoteType 不该自己再查一遍笔记类型清单');
    });
  });

  // BUG-2380：「创建并选用 Lapis」在回读清单里看不到 Lapis 时必须失败，
  // 绝不退而选清单里的第一个牌组/笔记类型。
  group('BUG-2380 createLapisSetup has no silent fallback', () {
    final vm = File('lib/src/anki/anki_view_model.dart').readAsStringSync();

    test('不再用 orElse 退到清单第一个', () {
      final int start = vm.indexOf('Future<LapisSetupResult> createLapisSetup');
      expect(start, greaterThan(-1));
      final int end = vm.indexOf('_lapisSetupFailure(Object e)', start);
      final String body = vm.substring(start, end > start ? end : vm.length);
      expect(body.contains('availableNoteTypes.first'), isFalse,
          reason: '找不到 Lapis 就选清单第一个 = 把用户自己的牌组当成 Lapis');
      expect(body.contains('availableDecks.first'), isFalse);
      expect(body, contains('AnkiErrorCode.lapisSetupMissing'));
    });
  });

  // BUG-2380：连接 Anki 之后与新手引导「下一步」都要判一次「这套配置真能制出卡吗」，
  // 判不过就走同一个弹窗。两处不许各写一套判据。
  group('BUG-2380 mining-readiness check is wired at both entry points', () {
    final controls =
        File('lib/src/anki/anki_config_controls.dart').readAsStringSync();
    final page = File('lib/src/pages/implementations/anki_settings_page.dart')
        .readAsStringSync();
    final wizard =
        File('lib/src/pages/implementations/onboarding_wizard_page.dart')
            .readAsStringSync();

    test('弹窗只有一处实现，判据是 canMineCards', () {
      expect(controls, contains('promptCreateLapisIfCannotMine'));
      expect(controls, contains('settings.canMineCards'));
    });

    test('设置页刷新之后调它', () {
      expect(page, contains('promptCreateLapisIfCannotMine('));
    });

    test('新手引导的下一步与测试连接都调它', () {
      expect('promptCreateLapisIfCannotMine('.allMatches(wizard).length, 2,
          reason: '一处在 _goNextAsync（离开 Anki 步之前），'
              '一处在 _testAnkiConnection（连上之后）');
    });
  });
}
