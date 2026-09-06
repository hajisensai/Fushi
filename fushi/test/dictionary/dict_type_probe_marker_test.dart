// 词典类型探测标记（[kDictTypeProbeKey]）的语义测试。
//
// 这个标记存在的唯一理由是「探过」必须是一等状态。旧实现只在**需要改判类型**时
// 才往 metadata 里写东西，于是「没探过」和「探过、结论是不用改」在数据上长得一模
// 一样——启动期的自愈循环没法区分，只能对每一本每次启动都重探。而 kanji 分支的
// 探测是把整张 hash 表扫完、逐槽随机跳读 blobs.bin，纯 kanji 词典还永远触发不了
// 「term+kanji 都找到」的提前退出，扫的就是全表。手机冷缓存下每本几万次随机页
// 访问，词典一多启动就被这段同步 FFI 吞掉（用户报告：导入很多词典后 app 打不开）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

Dictionary dict({Map<String, String> metadata = const <String, String>{}}) =>
    Dictionary(
      name: 'D',
      formatKey: 'yomichan',
      order: 0,
      type: DictionaryType.kanji,
      metadata: metadata,
    );

void main() {
  group('isTypeProbed', () {
    test('没有标记 = 没探过（老词典要探一次）', () {
      expect(dict().isTypeProbed, isFalse);
    });

    test('标记等于当前版本 = 探过，跳过', () {
      expect(
        dict(metadata: <String, String>{
          kDictTypeProbeKey: kDictTypeProbeVersion,
        }).isTypeProbed,
        isTrue,
      );
    });

    test('标记是旧版本 = 要重探（探测语义升级后存量自动重探）', () {
      // 值存版本号而不是 'true' 就是为了这条：改探测逻辑只需 bump 版本，
      // 不必再发明一个新键、也不必写一次性迁移。
      expect(
        dict(metadata: <String, String>{kDictTypeProbeKey: '0'}).isTypeProbed,
        isFalse,
      );
    });

    test('标记是垃圾值 = 要重探（不把无法解释的值当成已探过）', () {
      expect(
        dict(metadata: <String, String>{kDictTypeProbeKey: 'true'})
            .isTypeProbed,
        isFalse,
      );
    });

    test('「探过」与「有 kanji 内容」是两件事，不能互相反推', () {
      // 这正是旧实现的二义：hasKanji 缺席既可能是没探过，也可能是探过但这本没有
      // kanji 记录。两个键各管各的。
      final Dictionary probedNoKanji = dict(metadata: <String, String>{
        kDictTypeProbeKey: kDictTypeProbeVersion,
      });
      expect(probedNoKanji.isTypeProbed, isTrue);
      expect(probedNoKanji.metadata['hasKanji'], isNull);

      final Dictionary unprobedWithKanji =
          dict(metadata: <String, String>{'hasKanji': 'true'});
      expect(unprobedWithKanji.isTypeProbed, isFalse);
    });
  });

  group('metadata 往返', () {
    test('标记随 toJson/fromJson 存活（存量词典重启后不会退回未探状态）', () {
      final Dictionary original = dict(metadata: <String, String>{
        kDictTypeProbeKey: kDictTypeProbeVersion,
        'hasKanji': 'true',
      });
      final Dictionary restored = Dictionary.fromJson(original.toJson());
      expect(restored.isTypeProbed, isTrue,
          reason: '标记丢了就等于每次重启都重扫一遍，这条修复也就没了');
      expect(restored.metadata['hasKanji'], equals('true'));
    });
  });
}
