import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/texthooker_line_fold.dart';
import 'package:fushi/src/sync/texthooker_service.dart';

/// 用户报的 Zato 症状：一段台词分多次点击逐步显示，引擎每次点击都重绘整条文本行，
/// 于是 hook 依次拿到「第一句」「第二段」「整行」三条，工作台里第二句出现两次、
/// 字数被重复统计、浮窗连闪三次。
///
/// 截图里的原句就是下面这三拍。
const String kZatoFirst = 'Some would call it a miracle.';
const String kZatoSecondSegment =
    "And of course, that's a lovely way to put it...";
const String kZatoFullLine =
    "Some would call it a miracle. And of course, that's a lovely way to put it...";

void main() {
  group('折叠判据', () {
    test('前缀增长（同一句越写越长）算同一句', () {
      expect(
        isProgressiveTextUpdate(kZatoFirst, kZatoFullLine),
        isTrue,
      );
    });

    test('后缀增长（引擎补画整行，旧文本落在末尾）算同一句', () {
      // 这一条是 Zato 序列的关键：③ 相对 ② 是**后缀**关系而不是前缀。只做前缀
      // 判定（浏览器扩展 BUG-1029 那版判据）会漏掉它。
      expect(
        isProgressiveTextUpdate(kZatoSecondSegment, kZatoFullLine),
        isTrue,
      );
    });

    test('两句无关的台词不折', () {
      expect(
        isProgressiveTextUpdate('おはようございます。', 'いってきます。'),
        isFalse,
      );
    });

    test('完全相同的两行不折（游戏确实会连着输出两遍同样的「……」）', () {
      expect(isProgressiveTextUpdate(kZatoFirst, kZatoFirst), isFalse);
    });

    test('过短的行不参与折叠（任何长句都可能刚好以「はい」开头）', () {
      expect(isProgressiveTextUpdate('はい', 'はいそうですね、わかりました'), isFalse);
    });

    test('中缀不算（只认前缀 / 后缀）', () {
      expect(
        isProgressiveTextUpdate('abcdefg', 'xxxxabcdefgxxxx'),
        isFalse,
      );
    });

    test('比较前去空白：引擎在段间插的换行不该让同一句判成两句', () {
      expect(
        isProgressiveTextUpdate(
          'あのね、',
          'あのね、\n  きょうはいいてんきですね',
        ),
        isTrue,
      );
    });
  });

  group('TexthookerService 折叠行为', () {
    late TexthookerService service;

    setUp(() {
      service = TexthookerService.instance;
      service.clear();
      service.foldProgressiveLines = true;
    });

    tearDown(() {
      service.clear();
      service.foldProgressiveLines = true;
    });

    TexthookerLineEntry? append(String text, {int? seq}) {
      return service.appendLine(
        text,
        source: TexthookerLineSource.engineHook,
        sourceLabel: 'engine_hook',
        sourceSequence: seq,
        textThreadKey: 'thread-a',
      );
    }

    test('Zato 三拍最终只剩一条完整台词', () {
      append(kZatoFirst, seq: 1);
      append(kZatoSecondSegment, seq: 2);
      append(kZatoFullLine, seq: 3);

      expect(service.entries.length, 1,
          reason: '① 是 ③ 的前缀、② 是 ③ 的后缀，尾巴要一次性回吞干净；'
              '只折紧邻上一条的话 ① 会留下，第一句照样出现两次。');
      expect(service.entries.single.text, kZatoFullLine);
    });

    test('折叠后 lineId 保持最早那条（浮窗/游戏内卡片的身份不跳）', () {
      final TexthookerLineEntry? first = append(kZatoFirst, seq: 1);
      append(kZatoSecondSegment, seq: 2);
      final TexthookerLineEntry? merged = append(kZatoFullLine, seq: 3);

      expect(merged!.id, first!.id);
    });

    test('身份元数据前移到最新一次事件（逐句语音按 seq 配对）', () {
      append(kZatoFirst, seq: 1);
      append(kZatoSecondSegment, seq: 2);
      final TexthookerLineEntry? merged = append(kZatoFullLine, seq: 3);

      expect(merged!.sourceSequence, 3);
    });

    test('字数增量：整句被前后缀拼满时新增为空，不重复计字', () {
      append(kZatoFirst, seq: 1);
      expect(service.lastAppendedDelta, kZatoFirst);

      append(kZatoSecondSegment, seq: 2);
      expect(service.lastAppendedDelta, kZatoSecondSegment,
          reason: '② 与 ① 无前后缀关系，是货真价实的新字。');

      append(kZatoFullLine, seq: 3);
      expect(service.lastAppendedDelta, isEmpty,
          reason: '③ = ① + ②，两头都已被计过，这一拍一个新字都没有。');
    });

    test('纯前缀累积：只计新长出来的那一段', () {
      append('あのねきょうは', seq: 1);
      append('あのねきょうはいいてんきですね', seq: 2);

      expect(service.entries.length, 1);
      expect(service.lastAppendedDelta, 'いいてんきですね');
    });

    test('新文本被旧文本完全包含时不倒退，也不计字', () {
      append(kZatoFullLine, seq: 1);
      final TexthookerLineEntry? shorter = append(kZatoFirst, seq: 2);

      expect(service.entries.length, 1);
      expect(shorter!.text, kZatoFullLine, reason: '保留信息量更大的那份，别被后到的残缺重绘覆盖掉。');
      expect(service.lastAppendedDelta, isEmpty);
    });

    test('不同 hook 线程之间绝不互折（折进对方就是丢行）', () {
      service.appendLine(
        kZatoFirst,
        source: TexthookerLineSource.engineHook,
        textThreadKey: 'thread-a',
      );
      service.appendLine(
        kZatoFullLine,
        source: TexthookerLineSource.engineHook,
        textThreadKey: 'thread-b',
      );

      expect(service.entries.length, 2);
    });

    test('关掉开关就退回旧的逐条追加行为', () {
      service.foldProgressiveLines = false;

      append(kZatoFirst, seq: 1);
      append(kZatoSecondSegment, seq: 2);
      append(kZatoFullLine, seq: 3);

      expect(service.entries.length, 3);
      expect(service.lastAppendedDelta, kZatoFullLine);
    });

    test('无关的下一句照常新起一行，不会被上一句吞掉', () {
      append(kZatoFirst, seq: 1);
      append(kZatoFullLine, seq: 2);
      append('Nothing in common with the previous line.', seq: 3);

      expect(service.entries.length, 2);
      expect(service.entries.last.text,
          'Nothing in common with the previous line.');
    });
  });
}
