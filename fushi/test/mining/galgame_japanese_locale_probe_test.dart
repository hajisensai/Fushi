import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_audio_source.dart';
import 'package:fushi/src/mining/galgame_japanese_locale.dart';
import 'package:fushi/src/mining/galgame_japanese_locale_probe.dart';
import 'package:fushi/src/mining/pe_resources.dart';

/// BUG-2047 守卫：转区 `auto` 从「32 位就转」改成证据驱动的三态判定。
///
/// 全部用合成数据：Shift-JIS / GBK / UTF-8 文本字节、文件名、手工拼装的最小 PE
/// （`.rsrc` 含 RT_VERSION / RT_MANIFEST，`.rdata` 非代码段含假名串）。IO 层只用
/// `Directory.systemTemp` 落盘一次走通 [probeGalJapaneseLocaleNeed]。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('classifyUserLanguageForLocale', () {
    test('ja / ja-JP / JA_jp ⇒ 日语；其它 ⇒ 非日语；空 ⇒ 无证据', () {
      for (final String tag in <String>['ja', 'ja-JP', 'JA_jp', 'jpn']) {
        expect(
          classifyUserLanguageForLocale(tag),
          GalJapaneseLocaleEvidence.userLanguageJapanese,
          reason: tag,
        );
      }
      for (final String tag in <String>['zh-CN', 'en', 'zh_Hant']) {
        expect(
          classifyUserLanguageForLocale(tag),
          GalJapaneseLocaleEvidence.userLanguageOther,
          reason: tag,
        );
      }
      expect(classifyUserLanguageForLocale(null), isNull);
      expect(classifyUserLanguageForLocale(''), isNull);
      expect(classifyUserLanguageForLocale('   '), isNull);
    });
  });

  group('classifyTextBytesForLocale', () {
    test('无 BOM Shift-JIS：假名对 ≥ 20 且 GB 对 ≈ 0 ⇒ dirTextShiftJis', () {
      expect(
        classifyTextBytesForLocale(_sjisKana(25)),
        GalJapaneseLocaleEvidence.dirTextShiftJis,
      );
      // 二级汉字落进 GB 首字节区是正常现象：25 : 1 仍是 Shift-JIS。
      expect(
        classifyTextBytesForLocale(
          _concat(<Uint8List>[_sjisKana(25), _gbHanzi(1)]),
        ),
        GalJapaneseLocaleEvidence.dirTextShiftJis,
      );
      // 19 个不够阈值。
      expect(classifyTextBytesForLocale(_sjisKana(19)), isNull);
    });

    test('无 BOM GBK：GB 对 ≥ 20 且假名对 ≈ 0 ⇒ dirTextGbk', () {
      expect(
        classifyTextBytesForLocale(_gbHanzi(25)),
        GalJapaneseLocaleEvidence.dirTextGbk,
      );
      expect(classifyTextBytesForLocale(_gbHanzi(19)), isNull);
    });

    test('两种都多（混编 / 噪声）⇒ 不下结论', () {
      expect(
        classifyTextBytesForLocale(
          _concat(<Uint8List>[_sjisKana(25), _gbHanzi(25)]),
        ),
        isNull,
      );
    });

    test('UTF-8 BOM / UTF-16 BOM 简体中文：≥ 5 个简体专用汉字且无假名 ⇒ 简体', () {
      const String zh = '这是简体中文说明，请先安装汉化补丁再运行游戏。';
      expect(
        classifyTextBytesForLocale(_utf8Bom(zh)),
        GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi,
      );
      expect(
        classifyTextBytesForLocale(_utf16Le(zh)),
        GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi,
      );
      expect(
        classifyTextBytesForLocale(_utf16Be(zh)),
        GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi,
      );
      // 混着假名（日文说明里引用几个简体字）就不算。
      expect(classifyTextBytesForLocale(_utf8Bom('$zh こんにちは')), isNull);
      // 4 个不够。
      expect(classifyTextBytesForLocale(_utf8Bom('这说请汉 hello')), isNull);
    });

    test('无 BOM 但严格合法的 UTF-8 走 Unicode 路径：日文不算 Shift-JIS 正向', () {
      // UTF-8 平假名 E3 81 xx 顺序扫描会撞出伪「假名对」(0x82,0xE3)，必须先识别 UTF-8。
      final Uint8List utf8Kana = Uint8List.fromList(
        utf8.encode('こんにちは。これはユーティーエフはちのよみかたです。' * 4),
      );
      expect(classifyTextBytesForLocale(utf8Kana), isNull);
      expect(
        classifyTextBytesForLocale(
          Uint8List.fromList(utf8.encode('这是简体中文说明，请先安装汉化补丁再运行。')),
        ),
        GalJapaneseLocaleEvidence.dirTextSimplifiedHanzi,
      );
    });

    test('纯 ASCII / 空文件 ⇒ 无证据', () {
      expect(
        classifyTextBytesForLocale(
          Uint8List.fromList(ascii.encode('README' * 100)),
        ),
        isNull,
      );
      expect(classifyTextBytesForLocale(Uint8List(0)), isNull);
    });
  });

  group('classifyFileNamesForLocale', () {
    test('假名文件名 ⇒ 正向；汉化标记 ⇒ 负向；可同时命中', () {
      expect(
        classifyFileNamesForLocale(<String>['game.exe', 'お読みください.txt']),
        <GalJapaneseLocaleEvidence>{
          GalJapaneseLocaleEvidence.dirFileNameJapanese,
        },
      );
      for (final String name in <String>[
        'patch_CHS.xp3',
        '汉化说明.txt',
        'Game_Chinese.exe',
        'readme_cht.txt',
        '简体中文补丁.exe',
        'hanhua.dll',
        '繁體說明.txt',
        // KiriKiri 系汉化补丁最常见的 ASCII 词元：cn / zh / chn / gbk 及其变体。
        'cn.xp3',
        'patch2_cn.xp3',
        'readme_zh.txt',
        'zh-cn.txt',
        'patch_CHN.xp3',
        'GBK.txt',
      ]) {
        expect(
          classifyFileNamesForLocale(<String>[name]),
          <GalJapaneseLocaleEvidence>{
            GalJapaneseLocaleEvidence.dirFileNameChinesePatch,
          },
          reason: name,
        );
      }
      expect(
        classifyFileNamesForLocale(<String>[
          'data.xp3',
          'game.exe',
          'README.TXT',
          // 普通英文名里夹着 chs / cht 子串不算汉化标记：ASCII 标记必须是独立词元。
          'fuchsia.dll',
          'watchtower.ogg',
          'chsound.dll',
          'fuchsin.dll',
          'scene.ks',
          'bgm.xp3',
        ]),
        isEmpty,
      );
      expect(
        classifyFileNamesForLocale(<String>['お読みください.txt', 'patch_CHS.xp3']),
        <GalJapaneseLocaleEvidence>{
          GalJapaneseLocaleEvidence.dirFileNameJapanese,
          GalJapaneseLocaleEvidence.dirFileNameChinesePatch,
        },
      );
    });
  });

  group('readPeResourceLeaves', () {
    test('按类型取叶子，带 nameId / langId；非 PE / 无该类型 ⇒ 空', () {
      final Uint8List pe = _buildPe(
        resources: <int, List<_Leaf>>{
          16: <_Leaf>[
            _Leaf(lang: 0x0411, bytes: Uint8List.fromList(<int>[1, 2, 3])),
          ],
          24: <_Leaf>[
            _Leaf(lang: 0x0409, bytes: Uint8List.fromList(<int>[9])),
          ],
        },
      );
      final List<PeResourceLeaf> version = readPeResourceLeaves(pe, 16);
      expect(version, hasLength(1));
      expect(version.single.langId, 0x0411);
      expect(version.single.nameId, 1);
      expect(version.single.bytes, <int>[1, 2, 3]);
      expect(readPeResourceLeaves(pe, 24).single.bytes, <int>[9]);
      expect(readPeResourceLeaves(pe, 3), isEmpty);
      expect(
        readPeResourceLeaves(Uint8List.fromList(<int>[1, 2, 3]), 16),
        isEmpty,
      );
    });
  });

  group('classifyPeForLocale', () {
    test('RT_VERSION 语言目录 0x0411 ⇒ 版本资源日语', () {
      final Uint8List pe = _buildPe(
        resources: <int, List<_Leaf>>{
          16: <_Leaf>[_Leaf(lang: 0x0411, bytes: Uint8List(16))],
        },
      );
      expect(classifyPeForLocale(pe), <GalJapaneseLocaleEvidence>{
        GalJapaneseLocaleEvidence.versionInfoJapanese,
      });
    });

    test('语言目录中性但 VarFileInfo\\Translation = 0x0804 ⇒ 版本资源中文', () {
      final Uint8List pe = _buildPe(
        resources: <int, List<_Leaf>>{
          16: <_Leaf>[_Leaf(lang: 0x0409, bytes: _translationVar(0x0804))],
        },
      );
      expect(classifyPeForLocale(pe), <GalJapaneseLocaleEvidence>{
        GalJapaneseLocaleEvidence.versionInfoChinese,
      });
      // 0x0404 / 0x0C04 / 0x1004 也算中文；0x0409 不算任何证据。
      for (final int lang in <int>[0x0404, 0x0C04, 0x1004]) {
        expect(
          classifyPeForLocale(
            _buildPe(
              resources: <int, List<_Leaf>>{
                16: <_Leaf>[_Leaf(lang: lang, bytes: Uint8List(16))],
              },
            ),
          ),
          contains(GalJapaneseLocaleEvidence.versionInfoChinese),
          reason: lang.toRadixString(16),
        );
      }
      expect(
        classifyPeForLocale(
          _buildPe(
            resources: <int, List<_Leaf>>{
              16: <_Leaf>[_Leaf(lang: 0x0409, bytes: Uint8List(16))],
            },
          ),
        ),
        isEmpty,
      );
    });

    test('RT_MANIFEST 含 activeCodePage=UTF-8（可带 xmlns、大小写不敏感）⇒ manifest 证据', () {
      const String manifest =
          '<?xml version="1.0"?><assembly>'
          '<application><windowsSettings>'
          '<activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">'
          'utf-8</activeCodePage></windowsSettings></application></assembly>';
      final Uint8List pe = _buildPe(
        resources: <int, List<_Leaf>>{
          24: <_Leaf>[
            _Leaf(
              lang: 0x0409,
              bytes: Uint8List.fromList(utf8.encode(manifest)),
            ),
          ],
        },
      );
      expect(classifyPeForLocale(pe), <GalJapaneseLocaleEvidence>{
        GalJapaneseLocaleEvidence.manifestUtf8CodePage,
      });
      // 普通 manifest（只声明 DPI 等）不是证据。
      final Uint8List plain = _buildPe(
        resources: <int, List<_Leaf>>{
          24: <_Leaf>[
            _Leaf(
              lang: 0x0409,
              bytes: Uint8List.fromList(
                utf8.encode(
                  '<assembly><application><windowsSettings>'
                  '<dpiAware>true</dpiAware></windowsSettings></application></assembly>',
                ),
              ),
            ),
          ],
        },
      );
      expect(classifyPeForLocale(plain), isEmpty);
    });

    test('非代码段假名串段 ≥ 3 条 ⇒ exeShiftJisStrings；2 条 / 在代码段 / 带 GB 对都不算', () {
      final Uint8List three = _nulStrings(<Uint8List>[
        _sjisKana(3),
        _sjisKana(4),
        _concat(<Uint8List>[_asciiBytes('msg:'), _sjisKana(2)]),
      ]);
      expect(
        classifyPeForLocale(_buildPe(rdata: three)),
        <GalJapaneseLocaleEvidence>{
          GalJapaneseLocaleEvidence.exeShiftJisStrings,
        },
      );
      expect(countShiftJisStringSegments(_buildPe(rdata: three)), 3);

      final Uint8List two = _nulStrings(<Uint8List>[
        _sjisKana(3),
        _sjisKana(4),
      ]);
      expect(classifyPeForLocale(_buildPe(rdata: two)), isEmpty);

      // 同样的字节放进可执行段：代码段里的巧合字节不算证据。
      expect(classifyPeForLocale(_buildPe(text: three)), isEmpty);

      // 串段里混着 GB 对：不是纯假名串，不计。
      final Uint8List mixed = _nulStrings(<Uint8List>[
        _concat(<Uint8List>[_sjisKana(3), _gbHanzi(1)]),
        _concat(<Uint8List>[_sjisKana(3), _gbHanzi(1)]),
        _concat(<Uint8List>[_sjisKana(3), _gbHanzi(1)]),
      ]);
      expect(classifyPeForLocale(_buildPe(rdata: mixed)), isEmpty);

      // 只有 1 个假名对（长度虽 ≥ 6）不计：噪声上限。
      final Uint8List single = _nulStrings(<Uint8List>[
        _concat(<Uint8List>[_asciiBytes('abcd'), _sjisKana(1)]),
        _concat(<Uint8List>[_asciiBytes('abcd'), _sjisKana(1)]),
        _concat(<Uint8List>[_asciiBytes('abcd'), _sjisKana(1)]),
      ]);
      expect(classifyPeForLocale(_buildPe(rdata: single)), isEmpty);
    });

    test('exe 里的 GB2312 对不是负向证据（二进制里那是噪声）', () {
      final Uint8List gb = _nulStrings(
        List<Uint8List>.generate(50, (int _) => _gbHanzi(6)),
      );
      expect(classifyPeForLocale(_buildPe(rdata: gb)), isEmpty);
    });

    test('多种证据同时存在时全部返回，裁决交给 judge', () {
      final Uint8List pe = _buildPe(
        resources: <int, List<_Leaf>>{
          16: <_Leaf>[_Leaf(lang: 0x0411, bytes: _translationVar(0x0804))],
        },
        rdata: _nulStrings(<Uint8List>[
          _sjisKana(3),
          _sjisKana(3),
          _sjisKana(3),
        ]),
      );
      expect(classifyPeForLocale(pe), <GalJapaneseLocaleEvidence>{
        GalJapaneseLocaleEvidence.versionInfoJapanese,
        GalJapaneseLocaleEvidence.versionInfoChinese,
        GalJapaneseLocaleEvidence.exeShiftJisStrings,
      });
      expect(
        judgeJapaneseLocaleNeed(classifyPeForLocale(pe)).need,
        GalJapaneseLocaleNeed.notNeeded,
      );
    });

    test('非 PE / 截断 ⇒ 空集，不抛', () {
      expect(classifyPeForLocale(Uint8List(0)), isEmpty);
      expect(
        classifyPeForLocale(Uint8List.fromList(<int>[0x4D, 0x5A, 1])),
        isEmpty,
      );
      final Uint8List pe = _buildPe(
        resources: <int, List<_Leaf>>{
          16: <_Leaf>[_Leaf(lang: 0x0411, bytes: Uint8List(64))],
        },
      );
      // 截掉尾部 40 字节后 `.rsrc` 叶子越界：只允许「无证据」，不允许抛出或半截解析。
      expect(
        classifyPeForLocale(Uint8List.sublistView(pe, 0, pe.length - 40)),
        isEmpty,
      );
    });
  });

  group('judgeJapaneseLocaleNeed 优先级', () {
    test('空 ⇒ unknown、证据为空', () {
      final GalJapaneseLocaleVerdict verdict = judgeJapaneseLocaleNeed(
        const <GalJapaneseLocaleEvidence>[],
      );
      expect(verdict.need, GalJapaneseLocaleNeed.unknown);
      expect(verdict.evidence, isEmpty);
    });

    test('负向压过正向：汉化标记 + 日语版本资源 ⇒ notNeeded，只列负向', () {
      final GalJapaneseLocaleVerdict verdict =
          judgeJapaneseLocaleNeed(const <GalJapaneseLocaleEvidence>[
            GalJapaneseLocaleEvidence.versionInfoJapanese,
            GalJapaneseLocaleEvidence.exeShiftJisStrings,
            GalJapaneseLocaleEvidence.dirFileNameChinesePatch,
            GalJapaneseLocaleEvidence.dirTextGbk,
          ]);
      expect(verdict.need, GalJapaneseLocaleNeed.notNeeded);
      expect(verdict.evidence, <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.dirFileNameChinesePatch,
        GalJapaneseLocaleEvidence.dirTextGbk,
      ]);
    });

    test('用户声明日语压过一切负向；声明非日语压过一切正向', () {
      final GalJapaneseLocaleVerdict ja =
          judgeJapaneseLocaleNeed(const <GalJapaneseLocaleEvidence>[
            GalJapaneseLocaleEvidence.dirFileNameChinesePatch,
            GalJapaneseLocaleEvidence.manifestUtf8CodePage,
            GalJapaneseLocaleEvidence.userLanguageJapanese,
          ]);
      expect(ja.need, GalJapaneseLocaleNeed.needed);
      expect(ja.evidence, <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.userLanguageJapanese,
      ]);

      final GalJapaneseLocaleVerdict other =
          judgeJapaneseLocaleNeed(const <GalJapaneseLocaleEvidence>[
            GalJapaneseLocaleEvidence.versionInfoJapanese,
            GalJapaneseLocaleEvidence.userLanguageOther,
          ]);
      expect(other.need, GalJapaneseLocaleNeed.notNeeded);
      expect(other.evidence, <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.userLanguageOther,
      ]);
    });

    test('只有正向 ⇒ needed；去重、保持首次出现顺序', () {
      final GalJapaneseLocaleVerdict verdict =
          judgeJapaneseLocaleNeed(const <GalJapaneseLocaleEvidence>[
            GalJapaneseLocaleEvidence.exeShiftJisStrings,
            GalJapaneseLocaleEvidence.versionInfoJapanese,
            GalJapaneseLocaleEvidence.exeShiftJisStrings,
          ]);
      expect(verdict.need, GalJapaneseLocaleNeed.needed);
      expect(verdict.evidence, <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.exeShiftJisStrings,
        GalJapaneseLocaleEvidence.versionInfoJapanese,
      ]);
    });

    test('版本资源 0x0411 单独出现只是佐证 ⇒ unknown（Unicode 引擎的日文游戏）', () {
      // KiriKiri Z / Unity / Ren'Py 的日文游戏一样带 0x0411 却不需要 CP932；用户手上的
      // 官方多语言版正是这一格（BUG-1691 的「々 → 器」）。
      final GalJapaneseLocaleVerdict alone =
          judgeJapaneseLocaleNeed(const <GalJapaneseLocaleEvidence>[
            GalJapaneseLocaleEvidence.versionInfoJapanese,
          ]);
      expect(alone.need, GalJapaneseLocaleNeed.unknown);
      expect(alone.evidence, isEmpty);

      final GalJapaneseLocaleVerdict withBytes =
          judgeJapaneseLocaleNeed(const <GalJapaneseLocaleEvidence>[
            GalJapaneseLocaleEvidence.versionInfoJapanese,
            GalJapaneseLocaleEvidence.dirFileNameJapanese,
          ]);
      expect(withBytes.need, GalJapaneseLocaleNeed.needed);
      expect(withBytes.evidence, <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.versionInfoJapanese,
        GalJapaneseLocaleEvidence.dirFileNameJapanese,
      ]);
    });

    test('每条证据要么正向要么负向要么人工声明，没有第四类', () {
      for (final GalJapaneseLocaleEvidence evidence
          in GalJapaneseLocaleEvidence.values) {
        final bool declared =
            evidence == GalJapaneseLocaleEvidence.userLanguageJapanese ||
            evidence == GalJapaneseLocaleEvidence.userLanguageOther;
        expect(
          <bool>[
            declared,
            galJapaneseLocaleEvidenceIsNegative(evidence),
            galJapaneseLocaleEvidenceIsPositive(evidence),
          ].where((bool b) => b).length,
          1,
          reason: '$evidence 必须恰好落在一类，否则 judge 会把它静默丢掉',
        );
      }
    });
  });

  group('probeGalJapaneseLocaleNeed（systemTemp 落盘）', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('hibiki_gal_locale_probe_');
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    String path(String name) => '${temp.path}${Platform.pathSeparator}$name';

    test('日文原版：0x0411 版本资源 + Shift-JIS readme ⇒ needed', () async {
      await File(path('game.exe')).writeAsBytes(
        _buildPe(
          resources: <int, List<_Leaf>>{
            16: <_Leaf>[_Leaf(lang: 0x0411, bytes: Uint8List(16))],
          },
        ),
      );
      await File(path('ReadMe.txt')).writeAsBytes(_sjisKana(40));
      await File(path('data.xp3')).writeAsBytes(_gbHanzi(200)); // 非文本扩展名，不读

      final GalJapaneseLocaleVerdict verdict = await probeGalJapaneseLocaleNeed(
        exePath: path('game.exe'),
      );
      expect(verdict.need, GalJapaneseLocaleNeed.needed);
      expect(verdict.evidence, <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.versionInfoJapanese,
        GalJapaneseLocaleEvidence.dirTextShiftJis,
      ]);
    });

    test('汉化版：exe 仍是日文，但目录有汉化标记文件名 + GBK 说明 ⇒ notNeeded', () async {
      await File(path('game.exe')).writeAsBytes(
        _buildPe(
          resources: <int, List<_Leaf>>{
            16: <_Leaf>[_Leaf(lang: 0x0411, bytes: Uint8List(16))],
          },
        ),
      );
      await File(path('汉化说明.txt')).writeAsBytes(_gbHanzi(40));

      final GalJapaneseLocaleVerdict verdict = await probeGalJapaneseLocaleNeed(
        exePath: path('game.exe'),
      );
      expect(verdict.need, GalJapaneseLocaleNeed.notNeeded);
      expect(verdict.evidence, <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.dirFileNameChinesePatch,
        GalJapaneseLocaleEvidence.dirTextGbk,
      ]);
    });

    test('用户声明语言 ⇒ 零 IO 直接裁决（exe 不存在也能答）', () async {
      final GalJapaneseLocaleVerdict verdict = await probeGalJapaneseLocaleNeed(
        exePath: path('missing.exe'),
        language: 'zh-CN',
      );
      expect(verdict.need, GalJapaneseLocaleNeed.notNeeded);
      expect(verdict.evidence, <GalJapaneseLocaleEvidence>[
        GalJapaneseLocaleEvidence.userLanguageOther,
      ]);
    });

    test('exe / 目录都不存在 ⇒ unknown，不抛', () async {
      final GalJapaneseLocaleVerdict verdict = await probeGalJapaneseLocaleNeed(
        exePath:
            '${temp.path}${Platform.pathSeparator}nope'
            '${Platform.pathSeparator}game.exe',
      );
      expect(verdict.need, GalJapaneseLocaleNeed.unknown);
      expect(verdict.evidence, isEmpty);
    });

    test('无任何证据的 32 位 exe ⇒ unknown（这正是 BUG-2047 要改掉的「全转」格）', () async {
      await File(path('game.exe')).writeAsBytes(_buildPe());
      await File(path('readme.txt')).writeAsString('Just an English readme.');
      final GalJapaneseLocaleVerdict verdict = await probeGalJapaneseLocaleNeed(
        exePath: path('game.exe'),
      );
      expect(verdict.need, GalJapaneseLocaleNeed.unknown);
    });
  });

  group('EngineHookGalAudioSource：命令行与会话事实同源', () {
    late Directory temp;
    late File injector;
    late File game;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('hibiki_gal_locale_engine_');
      injector = File('${temp.path}${Platform.pathSeparator}injector.exe');
      await injector.writeAsBytes(const <int>[0]);
      game = File('${temp.path}${Platform.pathSeparator}game.exe');
      await game.writeAsBytes(_buildPe()); // 32 位、无任何证据
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    /// 跑到 injector 启动那一步就截住：此时 `--japanese-locale` 已经算好、状态已经记账。
    Future<void> captureArguments(EngineHookGalAudioSource source) async {
      await _startWithMockedChannel(source);
      await source.stop();
    }

    EngineHookGalAudioSource build({
      required GalJapaneseLocaleMode mode,
      required GalJapaneseLocaleNeedProbe probe,
      String? contentLanguage,
      required List<List<String>> sink,
    }) => EngineHookGalAudioSource(
      launchExe: game.path,
      injectorPath: injector.path,
      japaneseLocaleMode: mode,
      contentLanguage: contentLanguage,
      systemAnsiCodePageProbe: () => 936,
      japaneseLocaleNeedProbe: probe,
      capabilitiesProbe: (String _) async =>
          GalHookCapabilityProbeResult.supported,
      processStarter: (String _, List<String> arguments) async {
        sink.add(arguments);
        throw const ProcessException('injector', <String>[], 'stop here');
      },
    );

    test('auto + 探测 unknown ⇒ 不带 --japanese-locale，verdict 入引擎', () async {
      final List<List<String>> sink = <List<String>>[];
      final EngineHookGalAudioSource source = build(
        mode: GalJapaneseLocaleMode.auto,
        probe: (String _, String? __) async => GalJapaneseLocaleVerdict.unknown,
        sink: sink,
      );
      await captureArguments(source);
      expect(sink.single, isNot(contains('--japanese-locale')));
      expect(source.japaneseLocaleApplied, isFalse);
      expect(source.japaneseLocaleVerdict?.need, GalJapaneseLocaleNeed.unknown);
    });

    test('auto + 探测 needed ⇒ 带 --japanese-locale，verdict 就是探测结果', () async {
      const GalJapaneseLocaleVerdict needed = GalJapaneseLocaleVerdict(
        need: GalJapaneseLocaleNeed.needed,
        evidence: <GalJapaneseLocaleEvidence>[
          GalJapaneseLocaleEvidence.dirTextShiftJis,
        ],
      );
      final List<List<String>> sink = <List<String>>[];
      final List<(String, String?)> probeCalls = <(String, String?)>[];
      final EngineHookGalAudioSource source = build(
        mode: GalJapaneseLocaleMode.auto,
        contentLanguage: 'ja-JP',
        probe: (String exe, String? language) async {
          probeCalls.add((exe, language));
          return needed;
        },
        sink: sink,
      );
      await captureArguments(source);
      expect(sink.single, contains('--japanese-locale'));
      expect(source.japaneseLocaleApplied, isTrue);
      expect(source.japaneseLocaleVerdict, same(needed));
      expect(probeCalls, <(String, String?)>[
        (game.path, 'ja-JP'),
      ], reason: '探测器拿到的是 launch 的 exe 与该游戏声明的内容语言');
    });

    test('on / off 不探测：verdict 为 null，命令行只看档位', () async {
      for (final (GalJapaneseLocaleMode mode, bool expectFlag)
          in <(GalJapaneseLocaleMode, bool)>[
            (GalJapaneseLocaleMode.on, true),
            (GalJapaneseLocaleMode.off, false),
          ]) {
        final List<List<String>> sink = <List<String>>[];
        int probeCalls = 0;
        final EngineHookGalAudioSource source = build(
          mode: mode,
          probe: (String _, String? __) async {
            probeCalls++;
            return GalJapaneseLocaleVerdict.unknown;
          },
          sink: sink,
        );
        await captureArguments(source);
        expect(
          sink.single.contains('--japanese-locale'),
          expectFlag,
          reason: '$mode',
        );
        expect(source.japaneseLocaleApplied, expectFlag, reason: '$mode');
        expect(source.japaneseLocaleVerdict, isNull, reason: '$mode');
        expect(probeCalls, 0, reason: '$mode 下不该花 IO 去探测');
      }
    });

    test('探测器抛出 ⇒ 当 unknown、不转区、启动不被阻塞', () async {
      final List<List<String>> sink = <List<String>>[];
      final EngineHookGalAudioSource source = build(
        mode: GalJapaneseLocaleMode.auto,
        probe: (String _, String? __) async =>
            throw StateError('probe blew up'),
        sink: sink,
      );
      await captureArguments(source);
      expect(sink, hasLength(1), reason: 'injector 仍然被拉起');
      expect(sink.single, isNot(contains('--japanese-locale')));
      expect(source.japaneseLocaleVerdict?.need, GalJapaneseLocaleNeed.unknown);
    });
  });
}

/// 让 `start()` 跑到 processStarter（它记下参数后抛出），把 MethodChannel 兜住即可。
Future<void> _startWithMockedChannel(EngineHookGalAudioSource source) async {
  const MethodChannel channel = MethodChannel('app.fushi.reader/voice_hook');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (MethodCall _) async => null);
  try {
    await source.start();
  } finally {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

// ---------------------------------------------------------------------------
// 合成数据

/// [count] 个 Shift-JIS 平假名（あいうえお… 循环，0x82 0xA0 起）。
Uint8List _sjisKana(int count) {
  final Uint8List out = Uint8List(count * 2);
  for (int i = 0; i < count; i++) {
    out[i * 2] = 0x82;
    out[i * 2 + 1] = 0xA0 + (i % 0x50);
  }
  return out;
}

/// [count] 个 GB2312 汉字（lead 0xB0–0xF7 循环，trail 0xA1 起）。
Uint8List _gbHanzi(int count) {
  final Uint8List out = Uint8List(count * 2);
  for (int i = 0; i < count; i++) {
    out[i * 2] = 0xB0 + (i % 0x48);
    out[i * 2 + 1] = 0xA1 + (i % 0x5D);
  }
  return out;
}

Uint8List _asciiBytes(String s) => Uint8List.fromList(ascii.encode(s));

Uint8List _concat(List<Uint8List> parts) {
  final BytesBuilder builder = BytesBuilder(copy: false);
  for (final Uint8List part in parts) {
    builder.add(part);
  }
  return builder.toBytes();
}

/// 把每段接上 NUL 终止，再整体加一段填充，模拟 `.rdata` 里的字符串表。
Uint8List _nulStrings(List<Uint8List> strings) {
  final BytesBuilder builder = BytesBuilder(copy: false);
  builder.add(Uint8List(8));
  for (final Uint8List s in strings) {
    builder.add(s);
    builder.addByte(0);
  }
  builder.add(Uint8List(8));
  return builder.toBytes();
}

Uint8List _utf8Bom(String text) => _concat(<Uint8List>[
  Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF]),
  Uint8List.fromList(utf8.encode(text)),
]);

Uint8List _utf16Le(String text) {
  final BytesBuilder builder = BytesBuilder();
  builder.add(<int>[0xFF, 0xFE]);
  for (final int unit in text.codeUnits) {
    builder
      ..addByte(unit & 0xFF)
      ..addByte(unit >> 8);
  }
  return builder.toBytes();
}

Uint8List _utf16Be(String text) {
  final BytesBuilder builder = BytesBuilder();
  builder.add(<int>[0xFE, 0xFF]);
  for (final int unit in text.codeUnits) {
    builder
      ..addByte(unit >> 8)
      ..addByte(unit & 0xFF);
  }
  return builder.toBytes();
}

/// VS_VERSIONINFO 里的 `Var` 结构：`Translation` 键 + 一个 DWORD（低字 = 语言）。
Uint8List _translationVar(int language, {int charset = 0x04B0}) {
  final List<int> key = <int>[];
  for (final int unit in 'Translation'.codeUnits) {
    key
      ..add(unit)
      ..add(0);
  }
  key
    ..add(0)
    ..add(0);
  // 6 字节头 + 24 字节键 = 30，对齐到 32，再放 4 字节值。
  final Uint8List out = Uint8List(36);
  final ByteData view = ByteData.sublistView(out);
  view.setUint16(0, 36, Endian.little); // wLength
  view.setUint16(2, 4, Endian.little); // wValueLength
  view.setUint16(4, 0, Endian.little); // wType = binary
  out.setRange(6, 6 + key.length, key);
  view.setUint16(32, language, Endian.little);
  view.setUint16(34, charset, Endian.little);
  return out;
}

class _Leaf {
  const _Leaf({required this.lang, required this.bytes});

  final int lang;
  final Uint8List bytes;
}

/// 组装一个最小但结构合法的 32 位 PE：DOS 头 + PE 签名 + COFF 头 + 可选头 +
/// 至多三个段（`.text` 可执行、`.rdata` 非代码、`.rsrc` 资源树）。
///
/// `.rsrc` 是三层树：type → 每叶一个 id → 语言叶子 → 数据；[resources] 的键是资源类型 id。
Uint8List _buildPe({
  Map<int, List<_Leaf>> resources = const <int, List<_Leaf>>{},
  Uint8List? rdata,
  Uint8List? text,
  int machine = 0x014C,
}) {
  const int peOffset = 0x80;
  const int optionalHeaderSize = 0xE0;
  const int sectionTableOffset = peOffset + 4 + 20 + optionalHeaderSize;
  const int rawStart = 0x200;

  final Uint8List rsrc = _buildRsrc(resources, rsrcRva: 0x3000);
  final List<(String, Uint8List, int, int)> sections =
      <(String, Uint8List, int, int)>[
        if (text != null) ('.text', text, 0x1000, 0x60000020),
        if (rdata != null) ('.rdata', rdata, 0x2000, 0x40000040),
        ('.rsrc', rsrc, 0x3000, 0x40000040),
      ];

  int total = rawStart;
  for (final (String, Uint8List, int, int) section in sections) {
    total += (section.$2.length + 3) & ~3;
  }
  final Uint8List out = Uint8List(total);
  final ByteData view = ByteData.sublistView(out);

  out[0] = 0x4D;
  out[1] = 0x5A;
  view.setUint32(0x3C, peOffset, Endian.little);
  out[peOffset] = 0x50;
  out[peOffset + 1] = 0x45;
  view.setUint16(peOffset + 4, machine, Endian.little);
  view.setUint16(peOffset + 4 + 2, sections.length, Endian.little);
  view.setUint16(peOffset + 4 + 16, optionalHeaderSize, Endian.little);
  view.setUint16(peOffset + 24, 0x10B, Endian.little); // PE32 magic

  int cursor = rawStart;
  for (int i = 0; i < sections.length; i++) {
    final (String name, Uint8List bytes, int rva, int characteristics) =
        sections[i];
    final int base = sectionTableOffset + i * 40;
    for (int j = 0; j < name.length; j++) {
      out[base + j] = name.codeUnitAt(j);
    }
    view.setUint32(base + 8, bytes.length, Endian.little); // VirtualSize
    view.setUint32(base + 12, rva, Endian.little);
    view.setUint32(base + 16, bytes.length, Endian.little); // SizeOfRawData
    view.setUint32(base + 20, cursor, Endian.little); // PointerToRawData
    view.setUint32(base + 36, characteristics, Endian.little);
    out.setRange(cursor, cursor + bytes.length, bytes);
    cursor += (bytes.length + 3) & ~3;
  }
  return out;
}

/// 生成 `.rsrc` 段字节；叶子里的数据 RVA 以 [rsrcRva] 为基。
Uint8List _buildRsrc(Map<int, List<_Leaf>> resources, {required int rsrcRva}) {
  final List<int> types = resources.keys.toList()..sort();
  final int l1Size = 16 + 8 * types.length;
  int cursor = l1Size;
  final Map<int, int> l2Offset = <int, int>{};
  for (final int type in types) {
    l2Offset[type] = cursor;
    cursor += 16 + 8 * resources[type]!.length;
  }
  final Map<(int, int), int> l3Offset = <(int, int), int>{};
  final Map<(int, int), int> leafOffset = <(int, int), int>{};
  final Map<(int, int), int> dataOffset = <(int, int), int>{};
  for (final int type in types) {
    for (int i = 0; i < resources[type]!.length; i++) {
      l3Offset[(type, i)] = cursor;
      cursor += 24;
    }
  }
  for (final int type in types) {
    for (int i = 0; i < resources[type]!.length; i++) {
      leafOffset[(type, i)] = cursor;
      cursor += 16;
    }
  }
  for (final int type in types) {
    for (int i = 0; i < resources[type]!.length; i++) {
      dataOffset[(type, i)] = cursor;
      cursor += (resources[type]![i].bytes.length + 3) & ~3;
    }
  }
  final Uint8List out = Uint8List(cursor);
  final ByteData view = ByteData.sublistView(out);

  view.setUint16(14, types.length, Endian.little);
  for (int t = 0; t < types.length; t++) {
    final int type = types[t];
    view.setUint32(16 + t * 8, type, Endian.little);
    view.setUint32(16 + t * 8 + 4, 0x80000000 | l2Offset[type]!, Endian.little);
    final int l2 = l2Offset[type]!;
    final List<_Leaf> leaves = resources[type]!;
    view.setUint16(l2 + 14, leaves.length, Endian.little);
    for (int i = 0; i < leaves.length; i++) {
      view.setUint32(l2 + 16 + i * 8, i + 1, Endian.little);
      view.setUint32(
        l2 + 16 + i * 8 + 4,
        0x80000000 | l3Offset[(type, i)]!,
        Endian.little,
      );
      final int l3 = l3Offset[(type, i)]!;
      view.setUint16(l3 + 14, 1, Endian.little);
      view.setUint32(l3 + 16, leaves[i].lang, Endian.little);
      view.setUint32(l3 + 20, leafOffset[(type, i)]!, Endian.little);
      final int leaf = leafOffset[(type, i)]!;
      view.setUint32(leaf, rsrcRva + dataOffset[(type, i)]!, Endian.little);
      view.setUint32(leaf + 4, leaves[i].bytes.length, Endian.little);
      out.setRange(
        dataOffset[(type, i)]!,
        dataOffset[(type, i)]! + leaves[i].bytes.length,
        leaves[i].bytes,
      );
    }
  }
  return out;
}
