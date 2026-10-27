import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';

import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/tts/tts_provider.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';

import 'package:fushi/src/media/audiobook/tts/tts_voice_settings_page.dart'
    show ttsPresetsAfterDelete;
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_settings_cli.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_settings_routes.dart';
import 'package:fushi/src/ops/ctl_settings_values.dart';
import 'package:fushi/src/ops/ctl_settings_wire.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

/// 建路由表不解引用 ref（handler 都是闭包），给一个空壳即可。
class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('建路由表时不应触碰 WidgetRef：${invocation.memberName}');
}

/// 只声明参数表的假引擎（[applyCtlTtsParams] / validate 不碰 capabilities / create）。
class _FakeTtsDescriptor extends TtsProviderDescriptor {
  const _FakeTtsDescriptor();

  @override
  String get id => 'fake';

  @override
  TtsCapabilities get capabilities => throw UnimplementedError();

  @override
  List<TtsParamSpec> get params => const <TtsParamSpec>[
    TtsParamSpec(key: 'endpoint', kind: TtsParamKind.url, required: true),
    TtsParamSpec(key: 'apiKey', kind: TtsParamKind.secret),
    TtsParamSpec(
      key: 'format',
      kind: TtsParamKind.choice,
      choices: <String>['mp3', 'wav'],
    ),
  ];

  @override
  TtsProvider create(TtsVoicePreset preset, TtsHost host) =>
      throw UnimplementedError();
}

int _status(Object? Function() body) {
  try {
    body();
  } on CtlFailure catch (f) {
    return f.status;
  }
  return 0;
}

StatFact _fact({
  required String kind,
  required String key,
  required String day,
  int ms = 0,
  int chars = 0,
  int pages = 0,
}) => StatFact(
  mediaKind: kind,
  mediaKey: key,
  title: 'T-$key',
  format: '',
  dateKey: day,
  hour: -1,
  ms: ms,
  chars: chars,
  pages: pages,
  lastActiveMs: 0,
);

void main() {
  group('路由表', () {
    final List<CtlRoute> routes = buildSettingsCtlRoutes(
      OpContext(ref: _UnusedRef(), focusMainWindow: () async {}),
    );

    test('路径都在 /api/admin/ 下，method+path 不重复', () {
      expect(routes, isNotEmpty);
      final Set<String> seen = <String>{};
      for (final CtlRoute route in routes) {
        expect(route.pattern, startsWith('/api/admin/'));
        expect(
          seen.add('${route.method} ${route.pattern}'),
          isTrue,
          reason: '重复路由 ${route.method} ${route.pattern}',
        );
      }
    });

    test('profiles/import 不被 profiles/:id 吞掉（POST 只有 import 一条两段路径）', () {
      final List<CtlRoute> hits = routes
          .where(
            (CtlRoute r) =>
                r.method == 'POST' &&
                r.match('/api/admin/profiles/import') != null,
          )
          .toList();
      expect(hits.map((CtlRoute r) => r.pattern), <String>[
        '/api/admin/profiles/import',
      ]);
    });

    test('新路由齐全：设置 reset/run、模块顺序、Profile 绑定、快捷键、AI、模型、声音', () {
      final Set<String> ids = <String>{
        for (final CtlRoute r in routes) '${r.method} ${r.pattern}',
      };
      for (final String expected in <String>[
        'POST /api/admin/settings/:key/reset',
        'POST /api/admin/settings/:key/run',
        'POST /api/admin/modules/order',
        'GET /api/admin/profiles/bindings',
        'PUT /api/admin/profiles/bindings/:scope/:key',
        'PUT /api/admin/shortcuts/:action',
        'POST /api/admin/shortcuts/:action/unbind',
        'POST /api/admin/shortcuts/reset',
        'GET /api/admin/ai/presets',
        'GET /api/admin/ai/providers',
        'POST /api/admin/ai/providers',
        'PUT /api/admin/ai/providers/:id',
        'DELETE /api/admin/ai/providers/:id',
        'POST /api/admin/ai/providers/:id/probe',
        'GET /api/admin/ai/features',
        'PUT /api/admin/ai/features/:feature',
        'PUT /api/admin/ai/default',
        'GET /api/admin/models',
        'GET /api/admin/models/:kind/:id',
        'POST /api/admin/models/:kind/:id/download',
        'POST /api/admin/models/:kind/:id/cancel',
        'POST /api/admin/models/:kind/:id/link',
        'DELETE /api/admin/models/:kind/:id',
        'GET /api/admin/voices',
        'GET /api/admin/voices/engines',
        'POST /api/admin/voices',
        'PUT /api/admin/voices/:id',
        'POST /api/admin/voices/:id/activate',
        'DELETE /api/admin/voices/:id',
        'GET /api/admin/voices/:id/voices',
        'GET /api/admin/settings/:key/items',
        'POST /api/admin/settings/:key/items',
        'PUT /api/admin/settings/:key/items/:id',
        'DELETE /api/admin/settings/:key/items/:id',
        'POST /api/admin/models/:kind/:id/start',
        'POST /api/admin/models/:kind/:id/stop',
        'PUT /api/admin/tts/speed',
      ]) {
        expect(ids, contains(expected));
      }
    });

    test('固定段路由不被同 method 的 :参数 路由吞掉', () {
      List<String> hits(String method, String path) => <String>[
        for (final CtlRoute r in routes)
          if (r.method == method && r.match(path) != null) r.pattern,
      ];
      expect(hits('POST', '/api/admin/modules/order'), <String>[
        '/api/admin/modules/order',
      ]);
      expect(hits('POST', '/api/admin/shortcuts/reset'), <String>[
        '/api/admin/shortcuts/reset',
      ]);
      expect(hits('GET', '/api/admin/voices/engines'), <String>[
        '/api/admin/voices/engines',
      ]);
      expect(hits('GET', '/api/admin/profiles/bindings'), <String>[
        '/api/admin/profiles/bindings',
      ]);
    });
  });

  group('视频自绘行的 CLI 写法', () {
    test('控件布局：包装对象 / 裸布局 / 坏结构与未知动作给 FormatException', () {
      final String layout = VideoControlLayout.currentChrome.encode();
      final ({VideoControlLayout? layout, VideoCustomActionBindings? bindings})
      wrapped = parseVideoControlLayoutCli(
        '{"layout": $layout, "customActions": ","}',
      );
      expect(wrapped.layout!.encode(), layout);
      expect(wrapped.bindings, isNotNull);
      final ({VideoControlLayout? layout, VideoCustomActionBindings? bindings})
      bare = parseVideoControlLayoutCli(layout);
      expect(bare.layout, isNotNull);
      expect(bare.bindings, isNull);
      expect(() => parseVideoControlLayoutCli('[]'), throwsFormatException);
      expect(
        () => parseVideoControlLayoutCli('{"layout": {"version": 3}}'),
        throwsFormatException,
      );
      expect(
        () => parseVideoControlLayoutCli('{"customActions": "no_such_action"}'),
        throwsFormatException,
      );
    });

    test('弹幕屏蔽规则：正则行先编译校验', () {
      validateVideoDanmakuBlockRules('广告\n/^\\d+\$/');
      expect(
        () => validateVideoDanmakuBlockRules('ok\n/(unclosed/'),
        throwsFormatException,
      );
    });
  });

  group('快捷键 token', () {
    test('四类绑定按写法识别，token 可往返', () {
      final Object kb = parseCtlShortcutBinding('Ctrl+F');
      expect(kb, isA<InputBinding>());
      final Object pad = parseCtlShortcutBinding('pad:A');
      expect(pad, isA<GamepadBinding>());
      final Object mouse = parseCtlShortcutBinding('MouseBack');
      expect(mouse, isA<MouseBinding>());
      final Object wheel = parseCtlShortcutBinding('Alt+WheelDown');
      expect(wheel, isA<WheelBinding>());
      for (final Object b in <Object>[kb, pad, mouse, wheel]) {
        expect(parseCtlShortcutBinding(ctlShortcutBindingToken(b)), b);
      }
      // 不带前缀的 A 是键盘键，不是手柄键。
      expect(parseCtlShortcutBinding('A'), isA<InputBinding>());
      expect(_status(() => parseCtlShortcutBinding('Ctrl+NoSuchKey')), 400);
      expect(_status(() => parseCtlShortcutBinding('foo:A')), 400);
    });

    test('合并：replace 只换被提到的通道；add 追加去重；without 缺失给 400', () {
      final InputBinding f = InputBinding.deserialize('KeyF')!;
      final InputBinding g = InputBinding.deserialize('KeyG')!;
      final GamepadBinding a = GamepadBinding.deserialize('A')!;
      final ShortcutBindingSet before = ShortcutBindingSet(
        keyboardBindings: <InputBinding>[f],
        gamepadBindings: <GamepadBinding>[a],
      );
      final ShortcutBindingSet replaced = ctlShortcutMergedBindings(
        before,
        <Object>[g],
        replace: true,
      );
      expect(replaced.keyboardBindings, <InputBinding>[g]);
      expect(replaced.gamepadBindings, <GamepadBinding>[a]);
      final ShortcutBindingSet added = ctlShortcutMergedBindings(
        before,
        <Object>[g, f],
        replace: false,
      );
      expect(added.keyboardBindings, <InputBinding>[f, g]);
      final ShortcutBindingSet removed = ctlShortcutWithout(added, <Object>[f]);
      expect(removed.keyboardBindings, <InputBinding>[g]);
      expect(removed.gamepadBindings, <GamepadBinding>[a]);
      expect(_status(() => ctlShortcutWithout(removed, <Object>[f])), 400);
      expect(ctlShortcutTokens(before), <String>['KeyF', 'pad:A']);
    });

    test('友好写法归一：修饰键别名、单字母 / 单数字', () {
      expect(normalizeCtlKeyToken('ctrl+shift+f'), 'Ctrl+Shift+KeyF');
      expect(normalizeCtlKeyToken('cmd+1'), 'Meta+Digit1');
      expect(normalizeCtlKeyToken('Alt+WheelDown'), 'Alt+WheelDown');
      expect(normalizeCtlKeyToken('F12'), 'F12');
      expect(
        parseCtlShortcutBinding('ctrl+f'),
        parseCtlShortcutBinding('Ctrl+KeyF'),
      );
      expect(
        parseCtlShortcutBinding('option+WheelUp'),
        parseCtlShortcutBinding('Alt+WheelUp'),
      );
    });

    test('动作 / 作用域名大小写无关', () {
      final ShortcutAction first = ShortcutAction.values.first;
      expect(parseCtlShortcutAction(first.key), first);
      expect(parseCtlShortcutAction(first.name.toUpperCase()), first);
      expect(parseCtlShortcutAction('no_such_action'), isNull);
      expect(parseCtlShortcutScope('VIDEO'), ShortcutScope.video);
      expect(parseCtlShortcutScope('nope'), isNull);
    });
  });

  test('Profile 绑定参数', () {
    expect(parseCtlProfileMediaKind('video'), ProfileMediaKind.video);
    expect(parseCtlProfileMediaKind('SRTBOOK'), ProfileMediaKind.srtbook);
    expect(parseCtlProfileMediaKind('book'), isNull);
    expect(isCtlNoneToken('none'), isTrue);
    expect(isCtlNoneToken('-'), isTrue);
    expect(isCtlNoneToken('2'), isFalse);
  });

  group('AI', () {
    test('功能 / 协议 / 推理档位解析', () {
      expect(parseCtlAiFeature('manga-ocr'), AiFeature.mangaOcr);
      expect(parseCtlAiFeature('videoAcquire'), AiFeature.acquire);
      expect(parseCtlAiFeature('acquire'), AiFeature.acquire);
      expect(parseCtlAiFeature('lookupContext'), isNull);
      expect(
        parseCtlAiProtocol('gemini'),
        AiWireProtocol.geminiGenerateContent,
      );
      expect(_status(() => parseCtlAiProtocol('grpc')), 400);
      expect(parseCtlAiReasoning('HIGH'), AiReasoningEffort.high);
      expect(_status(() => parseCtlAiReasoning('max')), 400);
    });

    test('新建：预设起点 + 覆盖；自定义缺地址 / 云端明文 HTTP 给 400', () {
      final AiProviderPreset openai = aiProviderPresetById('openai')!;
      final AiProviderConfig built = buildCtlAiProvider(
        openai,
        id: 'ai-1',
        model: 'm',
        rpm: 10,
        apiKeys: const <AiApiKey>[AiApiKey('sk-secret-1234')],
      );
      expect(built.baseUrl.toString(), openai.baseUrl);
      expect(built.model, 'm');
      expect(built.requestsPerMinute, 10);
      expect(built.isUsable, isTrue);
      expect(
        _status(
          () => buildCtlAiProvider(
            aiProviderPresetById(kAiCustomPresetId)!,
            id: 'ai-2',
          ),
        ),
        400,
      );
      expect(
        _status(
          () => buildCtlAiProvider(
            openai,
            id: 'ai-3',
            baseUrl: 'http://api.example.com/v1',
          ),
        ),
        400,
      );
      expect(_status(() => buildCtlAiProvider(openai, id: 'a', rpm: -1)), 400);
      // 本地预设默认放行 loopback 明文 HTTP。
      expect(
        buildCtlAiProvider(
          aiProviderPresetById('ollama')!,
          id: 'ai-4',
        ).allowInsecureHttp,
        isTrue,
      );
    });

    test('应答不回显 Key，只给末 4 位', () {
      final AiProviderConfig provider = buildCtlAiProvider(
        aiProviderPresetById('openai')!,
        id: 'ai-1',
        apiKeys: const <AiApiKey>[AiApiKey('sk-secret-1234')],
      );
      final Map<String, Object?> json = ctlAiProviderJson(provider);
      expect('$json', isNot(contains('sk-secret')));
      expect((json['keys']! as List<Object?>).single, <String, Object?>{
        'tail': '…1234',
        'enabled': true,
      });
      expect(json['keyCount'], 1);
    });

    test('Key 合并：替换 / 追加去重 / 空串 400', () {
      const List<AiApiKey> current = <AiApiKey>[AiApiKey('a'), AiApiKey('b')];
      expect(mergeCtlAiKeys(current, 'c', append: false), <AiApiKey>[
        const AiApiKey('c'),
      ]);
      expect(mergeCtlAiKeys(current, ' a ', append: true), <AiApiKey>[
        const AiApiKey('b'),
        const AiApiKey('a'),
      ]);
      expect(_status(() => mergeCtlAiKeys(current, '  ', append: true)), 400);
    });

    test('按 id / 名字找提供商；重名给 409，找不到给 404', () {
      final AiProviderPreset openai = aiProviderPresetById('openai')!;
      final List<AiProviderConfig> providers = <AiProviderConfig>[
        buildCtlAiProvider(openai, id: 'ai-1', name: 'A'),
        buildCtlAiProvider(openai, id: 'ai-2', name: 'B'),
        buildCtlAiProvider(openai, id: 'ai-3', name: 'B'),
      ];
      expect(resolveCtlAiProvider(providers, 'ai-2').id, 'ai-2');
      expect(resolveCtlAiProvider(providers, 'A').id, 'ai-1');
      expect(_status(() => resolveCtlAiProvider(providers, 'B')), 409);
      expect(_status(() => resolveCtlAiProvider(providers, 'C')), 404);
    });
  });

  group('TTS 声音', () {
    const _FakeTtsDescriptor engine = _FakeTtsDescriptor();
    const TtsVoicePreset base = TtsVoicePreset(
      id: 'tts_1',
      providerId: 'fake',
      name: 'N',
      params: <String, String>{'format': 'mp3'},
    );

    test('参数写入：未知键 / 非法选项给 400；空值删除；凭据进 secrets', () {
      final TtsVoicePreset next = applyCtlTtsParams(
        base,
        engine,
        <String, String>{
          'endpoint': 'http://127.0.0.1:9880',
          'format': '',
          'apiKey': 'k-1',
          'concurrency': '2',
        },
        secretSources: <String>{'apiKey'},
      );
      expect(next.params, <String, String>{
        'endpoint': 'http://127.0.0.1:9880',
        'concurrency': '2',
      });
      expect(next.secrets, <String, String>{'apiKey': 'k-1'});
      expect(engine.validate(next), isEmpty);
      expect(
        _status(
          () => applyCtlTtsParams(base, engine, <String, String>{'x': '1'}),
        ),
        400,
      );
      expect(
        _status(
          () => applyCtlTtsParams(base, engine, <String, String>{
            'format': 'ogg',
          }),
        ),
        400,
      );
      // 凭据不经 stdin / env 给 400（命令行明文会进 shell 历史）。
      expect(
        _status(
          () =>
              applyCtlTtsParams(base, engine, <String, String>{'apiKey': 'k'}),
        ),
        400,
      );
    });

    test('应答只列已设凭据的键，不回显值；缺必填参数列进 problems', () {
      final TtsVoicePreset preset = base.copyWith(
        secrets: <String, String>{'apiKey': 'k-1'},
      );
      final Map<String, Object?> json = ctlTtsPresetJson(
        preset,
        active: true,
        descriptor: engine,
      );
      expect('$json', isNot(contains('k-1')));
      expect(json['secrets'], <String>['apiKey']);
      expect(json['problems'], <String>['endpoint']);
      expect(ctlTtsPresetJson(preset, active: false)['problems'], <String>[
        'engine_missing',
      ]);
    });

    test('删声音：删的是默认就退回第一份，删光为 null（设置页与 voice rm 共用）', () {
      final List<TtsVoicePreset> presets = <TtsVoicePreset>[
        base,
        const TtsVoicePreset(id: 'tts_2', providerId: 'fake', name: 'M'),
      ];
      final ({List<TtsVoicePreset> presets, String? activeId}) a =
          ttsPresetsAfterDelete(presets, 'tts_1', 'tts_1');
      expect(a.presets.map((TtsVoicePreset p) => p.id), <String>['tts_2']);
      expect(a.activeId, 'tts_2');
      expect(
        ttsPresetsAfterDelete(presets, 'tts_2', 'tts_1').activeId,
        'tts_2',
      );
      expect(
        ttsPresetsAfterDelete(
          <TtsVoicePreset>[base],
          'tts_1',
          'tts_1',
        ).activeId,
        isNull,
      );
    });

    test('按 id / 名字找声音', () {
      final List<TtsVoicePreset> presets = <TtsVoicePreset>[
        base,
        base.copyWith(name: 'M'),
      ];
      expect(resolveCtlTtsPreset(<TtsVoicePreset>[base], 'tts_1'), base);
      expect(resolveCtlTtsPreset(<TtsVoicePreset>[base], 'N'), base);
      expect(_status(() => resolveCtlTtsPreset(presets, 'tts_1')), 0);
      expect(_status(() => resolveCtlTtsPreset(presets, 'Z')), 404);
    });
  });

  group('值解析', () {
    test('布尔', () {
      expect(parseCtlSettingBool('ON'), isTrue);
      expect(parseCtlSettingBool('0'), isFalse);
      expect(
        () => parseCtlSettingBool('maybe'),
        throwsA(
          isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
        ),
      );
    });

    test('数字：整数约束与越界 400', () {
      expect(parseCtlSettingNumber('1.5', integer: false, min: 0, max: 2), 1.5);
      expect(parseCtlSettingNumber('3', integer: true), 3);
      for (final String bad in <String>['1.5', 'x']) {
        expect(
          () => parseCtlSettingNumber(bad, integer: true),
          throwsA(isA<CtlFailure>()),
        );
      }
      expect(
        () => parseCtlSettingNumber('5', integer: false, max: 2),
        throwsA(isA<CtlFailure>()),
      );
      expect(
        () => parseCtlSettingNumber('NaN', integer: false),
        throwsA(isA<CtlFailure>()),
      );
    });

    test('单选：token / 大小写 / 标签', () {
      const List<String> tokens = <String>['light', 'system', 'dark'];
      const List<String> labels = <String>['浅色', '跟随系统', '深色'];
      expect(
        indexOfCtlSettingOption('dark', tokens: tokens, labels: labels),
        2,
      );
      expect(
        indexOfCtlSettingOption('LIGHT', tokens: tokens, labels: labels),
        0,
      );
      expect(
        indexOfCtlSettingOption('跟随系统', tokens: tokens, labels: labels),
        1,
      );
      expect(
        () => indexOfCtlSettingOption('blue', tokens: tokens, labels: labels),
        throwsA(isA<CtlFailure>()),
      );
      expect(ctlSettingOptionToken(ModuleId.browse), 'browse');
      expect(ctlSettingOptionToken(3), '3');
    });

    test('模块 id：枚举名各种写法与持久化键', () {
      expect(parseCtlModuleId('browser-extension'), ModuleId.web);
      expect(parseCtlModuleId('CARD_CREATION'), ModuleId.cardCreation);
      expect(parseCtlModuleId('module_downloads_enabled'), ModuleId.browse);
      expect(parseCtlModuleId('nope'), isNull);
    });
  });

  test('机密判定：schema secret / 键尾命中 PrefRedactionPolicy', () {
    expect(isCtlSecretSetting('x.y', declaredSecret: true), isTrue);
    expect(
      isCtlSecretSetting(
        'system.network_proxy_username',
        declaredSecret: false,
      ),
      isTrue,
    );
    expect(
      isCtlSecretSetting('services.jimaku_api_key', declaredSecret: false),
      isTrue,
    );
    expect(
      isCtlSecretSetting('appearance.eink_mode', declaredSecret: false),
      isFalse,
    );
    expect(redactCtlSecret('hunter2'), kCtlRedactedValue);
    expect(redactCtlSecret(''), '');
  });

  test('统计域参数：listen 没有独立口径给 400', () {
    expect(ctlStatMediaKindOf(null), isNull);
    expect(ctlStatMediaKindOf('read'), kActivityMediaBook);
    expect(ctlStatMediaKindOf('watch'), kActivityMediaVideo);
    expect(ctlStatMediaKindOf('game'), kActivityMediaGame);
    expect(() => ctlStatMediaKindOf('listen'), throwsA(isA<CtlFailure>()));
    expect(() => ctlStatMediaKindOf('xx'), throwsA(isA<CtlFailure>()));
  });

  test('统计摘要：按窗口与域过滤日面事实，按条目排名', () {
    final List<StatFact> daily = <StatFact>[
      _fact(
        kind: kActivityMediaBook,
        key: 'a',
        day: '2026-10-01',
        ms: 60000,
        chars: 500,
      ),
      _fact(
        kind: kActivityMediaBook,
        key: 'a',
        day: '2026-10-02',
        ms: 60000,
        chars: 300,
      ),
      _fact(
        kind: kActivityMediaBook,
        key: 'b',
        day: '2026-09-01',
        ms: 999999,
        chars: 1,
      ),
      _fact(kind: kActivityMediaVideo, key: 'v', day: '2026-10-02', ms: 180000),
    ];
    bool inWindow(String day) => day.compareTo('2026-09-28') >= 0;

    final Map<String, Object?> all = summarizeCtlStatFacts(
      daily,
      inWindow: inWindow,
    );
    final Map<String, Object?> totals = all['totals']! as Map<String, Object?>;
    expect(totals['ms'], 300000);
    expect(totals['chars'], 800);
    expect(totals['activeDays'], 2);
    final Map<String, Object?> byKind = all['byKind']! as Map<String, Object?>;
    expect(byKind.keys, unorderedEquals(<String>['read', 'watch']));
    final List<Map<String, Object?>> top =
        all['topMedia']! as List<Map<String, Object?>>;
    expect(top.map((Map<String, Object?> m) => m['mediaKey']), <String>[
      'v',
      'a',
    ]);

    final Map<String, Object?> books = summarizeCtlStatFacts(
      daily,
      inWindow: (String _) => true,
      mediaKind: kActivityMediaBook,
    );
    expect((books['totals']! as Map<String, Object?>)['chars'], 801);
    expect((books['byKind']! as Map<String, Object?>).keys, <String>['read']);
  });

  test('快捷键列：键盘与滚轮按平台显示约定出，macOS 上是 ⌘ / ⌥ 符号写法', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const InputBinding cmdF = InputBinding(
      key: LogicalKeyboardKey.keyF,
      modifiers: <ModifierKey>{ModifierKey.meta},
    );
    const WheelBinding altWheel = WheelBinding(
      WheelDirection.down,
      modifiers: <ModifierKey>{ModifierKey.alt},
    );
    final Map<String, List<String>> columns = ctlShortcutBindingColumns(
      const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[cmdF],
        wheelBindings: <WheelBinding>[altWheel],
      ),
    );
    expect(columns['keyboard'], <String>[cmdF.displayLabel]);
    expect(columns['keyboard']!.single, contains('⌘'));
    expect(columns['mouse'], <String>[altWheel.displayLabel]);
    expect(columns['mouse']!.single, contains('⌥'));
    debugDefaultTargetPlatformOverride = null;
  });

  test('时长格式', () {
    expect(formatCtlDuration(45000), '45s');
    expect(formatCtlDuration(750000), '12m30s');
    expect(formatCtlDuration(3900000), '1h05m');
  });
}
