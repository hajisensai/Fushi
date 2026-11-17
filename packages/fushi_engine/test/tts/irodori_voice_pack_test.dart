import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack.dart';
import 'package:fushi_engine/tts/local/irodori_voice_pack_provider.dart';
import 'package:fushi_engine/tts/tts_audio_cache.dart';
import 'package:fushi_engine/tts/tts_voice_preset.dart';
import 'package:path/path.dart' as p;
import 'package:fushi_engine/tts/tts_direction.dart';
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

IrodoriVoicePack _pack({
  String id = 'pmiyagi',
  String? adapter = '/lora/miyagi',
  List<IrodoriRefGroup>? groups,
  int seed = 0,
  int revision = 0,
}) => IrodoriVoicePack(
  id: id,
  character: '宮城',
  adapterDir: adapter,
  groups:
      groups ??
      const <IrodoriRefGroup>[
        IrodoriRefGroup(name: '说出口', files: <String>['/r/a.wav', '/r/b.wav']),
        IrodoriRefGroup(name: '内心', files: <String>['/r/c.wav']),
      ],
  sampling: IrodoriSampling(seed: seed),
  revision: revision,
);

void main() {
  group('声音 id', () {
    test('pack:<id>/<group> 与 pack:<id> 都能解析，组名可含中文与 /', () {
      expect(
        IrodoriPackVoiceId.parse('pack:pmiyagi/内心'),
        const IrodoriPackVoiceId('pmiyagi', '内心'),
      );
      expect(
        IrodoriPackVoiceId.parse('pack:pmiyagi'),
        const IrodoriPackVoiceId('pmiyagi'),
      );
      expect(
        IrodoriPackVoiceId.parse('pack:p1/a/b')!.group,
        'a/b',
        reason: '组名是第一个 / 之后的全部',
      );
      expect(
        IrodoriPackVoiceId.parse('pack:p1/'),
        const IrodoriPackVoiceId('p1'),
        reason: '空组名 = 默认组',
      );
    });

    test('不是声音包 id 或 packId 非法 → null', () {
      expect(IrodoriPackVoiceId.parse(null), isNull);
      expect(IrodoriPackVoiceId.parse('1731800000000'), isNull);
      expect(IrodoriPackVoiceId.parse('builtin_edge'), isNull);
      expect(IrodoriPackVoiceId.parse('pack:'), isNull);
      expect(IrodoriPackVoiceId.parse('pack:有空格 x/g'), isNull);
      expect(IrodoriPackVoiceId.isPackVoice('pack:x'), isTrue);
      expect(IrodoriPackVoiceId.isPackVoice('x'), isFalse);
    });

    test('wire 往返', () {
      for (final String s in <String>['pack:a', 'pack:a/内心', 'pack:a-b_c/x']) {
        expect(IrodoriPackVoiceId.parse(s)!.wire, s);
      }
    });

    test('声音包 id 可直接放进声音指派表，按角色 × 类型解析回来', () {
      final CastVoiceAssignment a = CastVoiceAssignment(
        byCharacter: <String, String>{'宮城': 'pack:pmiyagi/说出口'},
        byCharacterKind: <String, Map<CastLineKind, String>>{
          '宮城': <CastLineKind, String>{CastLineKind.thought: 'pack:pmiyagi/内心'},
        },
      );
      final CastVoiceAssignment back = CastVoiceAssignment.fromJson(
        jsonDecode(jsonEncode(a.toJson())),
      );
      final String? thought = back.resolve('宮城', CastLineKind.thought);
      final ({IrodoriVoicePack pack, IrodoriRefGroup group})? r =
          resolveIrodoriPackVoice(<IrodoriVoicePack>[_pack()], thought);
      expect(r!.group.name, '内心');
      expect(
        resolveIrodoriPackVoice(<IrodoriVoicePack>[
          _pack(),
        ], back.resolve('宮城', CastLineKind.spoken))!.group.name,
        '说出口',
      );
    });
  });

  group('声音包', () {
    test('默认采样参数 = 40 步、文本引导 3.0、说话人引导 5.0', () {
      const IrodoriSampling s = IrodoriSampling();
      expect(s.steps, 40);
      expect(s.cfgText, 3.0);
      expect(s.cfgSpeaker, 5.0);
    });

    test('JSON 往返；默认组是第一组；找不到组返回 null', () {
      final IrodoriVoicePack pack = IrodoriVoicePack.fromJson(
        jsonDecode(jsonEncode(_pack(seed: 7, revision: 3).toJson())),
      )!;
      expect(pack.character, '宮城');
      expect(pack.adapterDir, '/lora/miyagi');
      expect(pack.usesLora, isTrue);
      expect(pack.sampling.seed, 7);
      expect(pack.revision, 3);
      expect(pack.group(null)!.name, '说出口');
      expect(pack.group('内心')!.files, <String>['/r/c.wav']);
      expect(pack.group('不存在'), isNull);
      expect(pack.voiceIds.map((IrodoriPackVoiceId v) => v.wire), <String>[
        'pack:pmiyagi/说出口',
        'pack:pmiyagi/内心',
      ]);
    });

    test('结构校验', () {
      expect(_pack().validate(), isEmpty);
      expect(
        _pack(groups: const <IrodoriRefGroup>[]).validate(),
        contains(IrodoriVoicePackProblem.noGroups),
      );
      expect(
        _pack(
          groups: const <IrodoriRefGroup>[
            IrodoriRefGroup(name: 'a', files: <String>[]),
          ],
        ).validate(),
        contains(IrodoriVoicePackProblem.emptyGroup),
      );
      expect(
        _pack(
          groups: const <IrodoriRefGroup>[
            IrodoriRefGroup(name: 'a', files: <String>['x']),
            IrodoriRefGroup(name: 'a', files: <String>['y']),
          ],
        ).validate(),
        contains(IrodoriVoicePackProblem.duplicateGroup),
      );
    });

    test('坏 id 的条目被丢弃', () {
      expect(IrodoriVoicePack.fromJson(<String, Object?>{'id': 'a b'}), isNull);
    });
  });

  group('IrodoriVoicePackStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('voice_pack_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('增 / 改（revision 自增）/ 删 / 解析', () {
      final IrodoriVoicePackStore store = IrodoriVoicePackStore(
        File(p.join(dir.path, 'sub', 'packs.json')),
      );
      expect(store.load(), isEmpty);
      store.upsert(_pack());
      expect(store.load().single.revision, 0);
      final IrodoriVoicePack edited = store.upsert(
        _pack().copyWith(clearAdapter: true),
      );
      expect(edited.revision, 1);
      expect(store.byId('pmiyagi')!.adapterDir, isNull);
      expect(store.resolve('pack:pmiyagi/内心')!.group.files, <String>[
        '/r/c.wav',
      ]);
      expect(store.resolve('pack:nope/内心'), isNull);
      expect(store.remove('pmiyagi'), isTrue);
      expect(store.remove('pmiyagi'), isFalse);
      expect(store.load(), isEmpty);
      expect(File('${store.file.path}.tmp').existsSync(), isFalse);
    });

    test('坏文件读成空、不抛', () {
      final File f = File(p.join(dir.path, 'packs.json'))
        ..writeAsStringSync('{not json');
      expect(IrodoriVoicePackStore(f).load(), isEmpty);
    });

    test('newId 合法且可解析', () {
      final String id = IrodoriVoicePackStore.newId(
        now: DateTime.utc(2026, 11, 17),
        random: Random(1),
      );
      expect(IrodoriPackVoiceId.parse('pack:$id')!.packId, id);
    });

    test('missingFiles 报缺的参考音频与没有 adapter_model 的目录', () {
      final File ref = File(p.join(dir.path, 'a.wav'))..writeAsStringSync('x');
      final Directory lora = Directory(p.join(dir.path, 'lora'))..createSync();
      final IrodoriVoicePack pack = _pack(
        adapter: lora.path,
        groups: <IrodoriRefGroup>[
          IrodoriRefGroup(
            name: 'g',
            files: <String>[ref.path, p.join(dir.path, 'gone.wav')],
          ),
        ],
      );
      expect(pack.missingFiles(), <String>[
        lora.path,
        p.join(dir.path, 'gone.wav'),
      ]);
      File(
        p.join(lora.path, 'adapter_model.safetensors'),
      ).writeAsStringSync('');
      expect(pack.missingFiles(), <String>[p.join(dir.path, 'gone.wav')]);
    });
  });

  group('短句规则', () {
    test('不挂 LoRA、20 字以内：0.55 + 0.15 × 字数（不计标点空白）', () {
      expect(irodoriManualSeconds('うん', lora: false), 0.85);
      expect(irodoriManualSeconds('え、うそ！？', lora: false), 1.0);
      expect(irodoriManualSeconds('「ありがとう」', lora: false), 1.3);
      expect(irodoriManualSeconds('あ' * 20, lora: false), 3.55);
    });

    test('超过 20 字或挂 LoRA → null（交给时长预测）', () {
      expect(irodoriManualSeconds('あ' * 21, lora: false), isNull);
      expect(irodoriManualSeconds('うん', lora: true), isNull);
      // 漫画生成端原先的第二份实现合并进来后：只有标点 / 长音的句子交给引擎预测。
      expect(irodoriSpokenCharCount('えっ！？'), 2);
      expect(irodoriSpokenCharCount('すごーい♪'), 3);
      expect(irodoriManualSeconds('……', lora: false), isNull);
      expect(irodoriManualSeconds('ーー！', lora: false), isNull);
    });

    test('forPack 自动套用、调用方给定时优先', () {
      final IrodoriBatchItem base = IrodoriBatchItem.forPack(
        id: 'l1',
        text: 'うん',
        pack: _pack(adapter: null),
        group: _pack().groups.first,
        outputPath: '/o/l1.wav',
      );
      expect(base.seconds, 0.85);
      expect(base.adapterDir, isNull);
      final IrodoriBatchItem lora = IrodoriBatchItem.forPack(
        id: 'l2',
        text: 'うん',
        pack: _pack(seed: 9),
        group: _pack().groups.first,
        outputPath: '/o/l2.wav',
      );
      expect(lora.seconds, isNull);
      expect(lora.seed, 9);
      expect(lora.refs, <String>['/r/a.wav', '/r/b.wav']);
      expect(
        IrodoriBatchItem.forPack(
          id: 'l3',
          text: 'うん',
          pack: _pack(adapter: null),
          group: _pack().groups.first,
          outputPath: '/o/l3.wav',
          seconds: 2.0,
          seed: 4,
        ),
        isA<IrodoriBatchItem>()
            .having((IrodoriBatchItem i) => i.seconds, 'seconds', 2.0)
            .having((IrodoriBatchItem i) => i.seed, 'seed', 4),
      );
    });
  });

  group('虚拟预设', () {
    test('每组一份，id 即声音 id；不完整的包跳过', () {
      final List<TtsVoicePreset> presets = irodoriVoicePackPresets(
        <IrodoriVoicePack>[
          _pack(),
          _pack(id: 'pbad', groups: const <IrodoriRefGroup>[]),
        ],
      );
      expect(presets.map((TtsVoicePreset e) => e.id), <String>[
        'pack:pmiyagi/说出口',
        'pack:pmiyagi/内心',
      ]);
      expect(presets.first.providerId, kIrodoriPackProviderId);
      expect(presets.first.name, '宮城 · 说出口');
    });

    test('预设 → 请求：参数原样带回、短句规则按是否挂 LoRA', () {
      final TtsVoicePreset preset = irodoriVoicePackPreset(
        _pack(adapter: null, seed: 3),
        _pack().groups.first,
      );
      final IrodoriBatchItem item = irodoriBatchItemFromPreset(
        preset,
        id: 'x',
        text: 'うん',
        outputPath: '/o/x.wav',
      )!;
      expect(item.refs, <String>['/r/a.wav', '/r/b.wav']);
      expect(item.adapterDir, isNull);
      expect(item.seed, 3);
      expect(item.steps, 40);
      expect(item.cfgText, 3.0);
      expect(item.cfgSpeaker, 5.0);
      expect(item.seconds, 0.85);
      expect(
        irodoriBatchItemFromPreset(
          preset.copyWith(params: <String, String>{'refs': 'bad'}),
          id: 'x',
          text: 't',
          outputPath: '/o',
        ),
        isNull,
      );
    });

    test('演出参数：种子与给定时长都收，改写请求；挂 LoRA 的声音标 adapter', () {
      final TtsVoicePreset plain = irodoriVoicePackPreset(
        _pack(adapter: null, seed: 3),
        _pack().groups.first,
      );
      final TtsVoicePreset lora = irodoriVoicePackPreset(
        _pack(),
        _pack().groups.first,
      );
      final TtsDirectionSupport s = irodoriPackDirectionSupport(plain);
      expect(s.seed, isTrue);
      expect(s.duration, isTrue);
      expect(s.adapter, isFalse);
      expect(irodoriPackDirectionSupport(lora).adapter, isTrue);

      final IrodoriBatchItem base = irodoriBatchItemFromPreset(
        plain,
        id: 'x',
        text: 'うん',
        outputPath: '/o/x.wav',
      )!;
      final IrodoriBatchItem directed = irodoriDirectedItem(
        base,
        const TtsDirection(seed: 42, durationSeconds: 0.7),
      );
      expect(directed.seed, 42);
      expect(directed.seconds, 0.7);
      expect(directed.refs, base.refs);
      expect(directed.outputPath, base.outputPath);
      // 没给时长：保留请求自带的短句规则结果；没给种子：保留包的种子。
      final IrodoriBatchItem seedOnly = irodoriDirectedItem(
        base,
        const TtsDirection(seed: 9),
      );
      expect(seedOnly.seconds, base.seconds);
      expect(irodoriDirectedItem(base, TtsDirection.none).seed, 3);
    });

    test('缓存键：换参考音频 / 编辑过（revision）会变，换组名标签不影响音色以外的东西', () {
      final IrodoriVoicePackTtsDescriptor d = IrodoriVoicePackTtsDescriptor(
        IrodoriLocalEngine(
          prefs: MemoryPrefStore(),
          httpClientFactory: () => HttpClient(),
          supported: true,
        ),
      );
      String key(IrodoriVoicePack pack, IrodoriRefGroup g) =>
          TtsAudioCache.keyFor(
            d.audioIdentity(irodoriVoicePackPreset(pack, g)),
            'こんにちは',
          );
      final IrodoriVoicePack pack = _pack();
      final String a = key(pack, pack.groups[0]);
      expect(key(pack, pack.groups[0]), a);
      expect(key(pack, pack.groups[1]), isNot(a));
      expect(key(pack.copyWith(revision: 1), pack.groups[0]), isNot(a));
      expect(key(_pack(seed: 1), pack.groups[0]), isNot(a));
      // 没装 v4-Large：描述符不可用（制作侧据此如实报「声音不可用」）。
      expect(d.isAvailable, isFalse);
      expect(d.validate(irodoriVoicePackPreset(pack, pack.groups[0])), isEmpty);
    });
  });
}
