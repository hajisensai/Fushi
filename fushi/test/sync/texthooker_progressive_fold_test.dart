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

    test('字符相同但换行变化是排版刷新，完全相同文本仍不是', () {
      expect(isWhitespaceOnlyLayoutRefresh('前半後半', '前半\n後半'), isTrue);
      expect(isWhitespaceOnlyLayoutRefresh('前半後半', '前半後半'), isFalse);
    });

    test('两句不同的台词不会被空白折叠判成排版刷新', () {
      // 负向覆盖。判据是「去空白后**完全相等**」，不是包含关系：两句不同的话
      // （含互为前缀的那种）一条都不该命中，否则用户会看着一句台词被下一句原地
      // 顶掉，上一句连同它的制卡/收藏一起从工作台上消失。
      expect(isWhitespaceOnlyLayoutRefresh('はい', 'いいえ'), isFalse);
      expect(
        isWhitespaceOnlyLayoutRefresh(
          'あのね、',
          'あのね、\n  きょうはいいてんきですね',
        ),
        isFalse,
        reason: '前缀增长归 isProgressiveTextUpdate 管，不是排版刷新',
      );
    });

    test('极短行的排版刷新照样折：等值判据没有 kMinFoldableLength 门', () {
      // 两条判据的下限**故意不对称**，不是漏了。kMinFoldableLength 是给
      // isProgressiveTextUpdate 的**包含**判据设的（任何长句都可能刚好以
      // 「はい」开头或结尾）。等值判据没有那个假阳性面：去空白后完全相同的两
      // 行，内容上本来就是同一句。给它补一个下限只会让下面这种真排版刷新漏折，
      // 在工作台上留一条重复短行 —— 那正是 BUG-1983 要消的症状。
      expect(isWhitespaceOnlyLayoutRefresh('はい', 'は い'), isTrue);
      expect(isWhitespaceOnlyLayoutRefresh('…', '…\n'), isTrue);
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

    test('websocket 源不折：那边的前缀关系是两句不同的话', () {
      // 折叠原本装在 appendLine 顶层，而该入口也服务 WS 源（Textractor / mpv /
      // 浏览器扩展），那条通道 5 平台都跑；而逃生开关在 Windows-only 的 game
      // 设置页里。收窄成 engineHook 之后，这个来源门同时就是平台门。
      TexthookerLineEntry? ws(String text, {int? seq}) => service.appendLine(
            text,
            source: TexthookerLineSource.websocket,
            sourceLabel: 'ws://127.0.0.1:6677',
            sourceSequence: seq,
          );
      ws(kZatoFirst, seq: 1);
      ws(kZatoFullLine, seq: 2);
      expect(service.entries.length, 2,
          reason: 'WS 送来的是外部工具已经成句的输出，前缀关系不代表同一句');
    });

    test('同为 WS 的两个端点不得互折（守卫必须认 sourceLabel）', () {
      // WS 路径下 textThreadKey 恒 null、source 恒 websocket，能区分 Textractor /
      // mpv / 浏览器扩展的**只有** sourceLabel。这里借 engineHook 源验判据本身
      // （WS 源已被上面那条门挡住，测不到这层）。
      service.appendLine(kZatoFirst,
          source: TexthookerLineSource.engineHook,
          sourceLabel: 'engine_hook_a',
          sourceSequence: 1,
          textThreadKey: 'thread-a');
      service.appendLine(kZatoFullLine,
          source: TexthookerLineSource.engineHook,
          sourceLabel: 'engine_hook_b',
          sourceSequence: 2,
          textThreadKey: 'thread-a');
      expect(service.entries.length, 2,
          reason: '不同端点的输出折成一条就是丢行');
    });

    test('折叠增量保留内部空白：拉丁文按词计数不能被焊成一个词', () {
      append(kZatoFirst, seq: 1);
      append(kZatoSecondSegment, seq: 2);
      final String delta = service.lastAppendedDelta;
      expect(delta, isNotEmpty);
      expect(delta.contains(' '), isTrue,
          reason: '在 normalizeForFold 的去空白坐标系里切增量，会把 '
              '"a lovely way to put it" 焊成一个词 —— countGalgameChars 对拉丁'
              '文本按词计数，空白是唯一的词边界，整段英文台词会被算成 1。');
      expect(delta, kZatoSecondSegment,
          reason: '第 ② 拍整段都是新字，增量应当就是它本身（两端 trim）');
    });

    test('折叠吞掉的行 id 必须被报出来（下游那批 map/timer 还拿它当活键）', () {
      final TexthookerLineEntry? first = append(kZatoFirst, seq: 1);
      final TexthookerLineEntry? second = append(kZatoSecondSegment, seq: 2);
      expect(first, isNotNull);
      expect(second, isNotNull);
      final TexthookerLineEntry? merged = append(kZatoFullLine, seq: 3);
      expect(merged, isNotNull);
      // 合并结果复用**最早**那条的 id，所以它不算「被吞」；第 ② 拍那条才是。
      expect(merged!.id, first!.id);
      expect(service.lastFoldedLineIds, contains(second!.id),
          reason: '不报出来的话，晚到的语音会写进死 id 被静默丢弃，'
              '用户的手动裁决也随之失效');
      expect(service.lastFoldedLineIds, isNot(contains(merged.id)),
          reason: '合并结果自己的 id 还活着，重定向链不该形成');
    });

    test('制卡 / 收藏位取并集，徽章不会因折叠消失', () {
      final TexthookerLineEntry? second0 = append(kZatoFirst, seq: 1);
      final TexthookerLineEntry? second = append(kZatoSecondSegment, seq: 2);
      expect(second0, isNotNull);
      service.markLineMined(second!.id, noteId: 42);
      final TexthookerLineEntry? merged = append(kZatoFullLine, seq: 3);
      expect(merged!.mined, isTrue,
          reason: '用户刚给第 ② 拍制的卡不该在第 ③ 拍折叠后从工作台上消失');
      expect(merged.minedNoteId, 42);
    });

    test('Zato 三拍最终只剩一条完整台词', () {
      append(kZatoFirst, seq: 1);
      append(kZatoSecondSegment, seq: 2);
      append(kZatoFullLine, seq: 3);

      expect(service.entries.length, 1,
          reason: '① 是 ③ 的前缀、② 是 ③ 的后缀，尾巴要一次性回吞干净；'
              '只折紧邻上一条的话 ① 会留下，第一句照样出现两次。');
      expect(service.entries.single.text, kZatoFullLine);
    });

    test('同句仅更新换行时原地采用最新排版，不新增重复行', () {
      final TexthookerLineEntry? first = append('大丈夫、話してみた感じ、後半', seq: 1);
      final TexthookerLineEntry? refreshed =
          append('大丈夫、話してみた感じ、\n後半', seq: 2);

      expect(service.entries, hasLength(1));
      expect(refreshed!.id, first!.id, reason: '排版刷新不能换掉制卡/查词使用的行身份');
      expect(service.entries.single.text, '大丈夫、話してみた感じ、\n後半');
      expect(service.lastAppendedDelta, isEmpty, reason: '仅换行不应重复计入学习字数');
    });

    test('两句不同的台词不会被排版刷新折成一条', () {
      // 服务层的负向对照：判据一旦从「等值」放宽成「包含」，这两条就会折成一
      // 条、第一句连同它的行 id 一起消失。
      append('はい', seq: 1);
      append('いいえ', seq: 2);

      expect(service.entries, hasLength(2));
      expect(service.entries.first.text, 'はい');
      expect(service.entries.last.text, 'いいえ');
    });

    test('同句两次快照之间插了别的线程也要折（SGRE：系统串线程夹在中间）', () {
      // 真机：SGRE exact 先出半句，WideCharToMultiByte 线程紧接着喷几条
      // normalrubytext…，然后 SGRE exact 才出整句。只看紧邻尾巴就断链，工作台
      // 里两条各带同一份语音。（半句取 ≥ kMinFoldableLength 字：3 字的「ねぇね」
      // 按「过短不折」判据本来就不参与折叠，那是另一条规则。）
      final TexthookerLineEntry? first = append('ねぇねぇ。なに', seq: 1);
      for (int i = 0; i < 3; i++) {
        service.appendLine(
          'normalrubytextrubytextruby',
          source: TexthookerLineSource.engineHook,
          sourceLabel: 'engine_hook',
          sourceSequence: 10 + i,
          textThreadKey: 'thread-system',
        );
      }
      final TexthookerLineEntry? merged =
          append('ねぇねぇ。なにブツブツ言ってるの？', seq: 20);

      expect(merged!.id, first!.id, reason: '整句必须回吞到最早那条，身份不跳');
      final List<String> texts =
          service.entries.map((TexthookerLineEntry e) => e.text).toList();
      expect(texts.where((String t) => t.startsWith('ねぇねぇ')).length, 1,
          reason: '半句与整句折成一条');
      expect(texts.where((String t) => t == 'normalrubytextrubytextruby').length,
          3,
          reason: '其它线程的行原地保留，不被折叠碰到');
    });

    test('回看只认同端点且仍要过折叠判据：隔着别的线程的两句无关台词不折', () {
      append('おはようございます。', seq: 1);
      service.appendLine(
        'normalrubytextrubytextruby',
        source: TexthookerLineSource.engineHook,
        sourceLabel: 'engine_hook',
        sourceSequence: 2,
        textThreadKey: 'thread-system',
      );
      append('いってきます。', seq: 3);
      expect(service.entries, hasLength(3));
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
