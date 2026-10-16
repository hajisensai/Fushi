// 反馈 LUgHjyc8By：galgame 快进 / 跳过与 Backlog 回看的台词不得计入阅读字数与时长。
import 'package:fushi/src/mining/galgame_char_count.dart';
import 'package:fushi/src/stats/galgame_line_study_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// 模拟会话侧的入账：计数器 → 门 → 净字数 / 跳过时长（与
/// `GalHookSessionController._recordActivity` 同一顺序）。
class _Ledger {
  final GalgameLineCharCounter counter = GalgameLineCharCounter();
  final GalgameLineStudyGate gate = GalgameLineStudyGate();
  int chars = 0;
  int skippedMs = 0;
  int _nextId = 0;

  /// 一行新台词（新的行 id），在 [atMs] 到达。
  void line(String text, int atMs) => _admit('${_nextId++}', text, text, atMs);

  /// 同一句的打字机续写（复用上一行 id）。
  void grow(String delta, String fullText, int atMs) =>
      _admit('${_nextId - 1}', delta, fullText, atMs);

  void _admit(String id, String delta, String fullText, int atMs) {
    final GalgameLineStudyDecision d = gate.admit(
      lineId: id,
      lineText: fullText,
      chars: counter.countDelta(delta),
      atMs: atMs,
    );
    chars += d.credit - d.retract;
    skippedMs += d.skippedDwellMs;
  }
}

void main() {
  test('正常节奏照常计：每行停留足够读完', () {
    final _Ledger l = _Ledger();
    l.line('あいうえお', 0); // 5
    l.line('かきくけこさしすせそ', 3000); // 10
    l.line('たちつてと', 7000); // 5
    l.line('なにぬねの', 9000); // 5（最后一行，停在上面读）
    expect(l.chars, 25);
    expect(l.skippedMs, 0);
  });

  test('会话内已入账的台词再出现（Backlog 回看）不重复计', () {
    final _Ledger l = _Ledger();
    l.line('「今日はいい天気だね。」', 0); // 9
    l.line('うん、そうだね', 4000); // 6
    l.line('散歩に行こうか', 8000); // 7
    // 打开 Backlog 慢慢往回翻：旧台词作为新行再进来（标点 / 括号不同也认）。
    l.line('散歩に行こうか', 12000);
    l.line('うん、そうだね。', 16000);
    l.line('今日はいい天気だね', 20000);
    expect(l.chars, 9 + 6 + 7);
  });

  test('重复判定只看已入账的行：打字机先入的增量在整句成为重复时撤回', () {
    final _Ledger l = _Ledger();
    l.line('ありがとう', 0); // 5
    l.line('ごめんね', 3000); // 4
    // 回看时同一句被逐字重绘：先到「あり」，长成整句后才认出是重复。
    l.line('あり', 6000);
    l.grow('がとう', 'ありがとう', 6100);
    expect(l.chars, 9);
  });

  test('快进连发不计：连续快于可阅读速度的整串撤回，停留时长记为跳过', () {
    final _Ledger l = _Ledger();
    l.line('はじまりの台詞です', 0); // 9，停留 5s：读过
    // Ctrl 跳过：每 50ms 一行。
    int t = 5000;
    for (int i = 0; i < 20; i++) {
      l.line('飛ばされた台詞その$i番', t);
      t += 50;
    }
    // 松开快进键，停在这一行上读。
    l.line('ここから読む', t);
    l.line('次の台詞', t + 4000);
    expect(l.chars, 9 + 6 + 4, reason: '快进的 20 行一字不计，前后正常阅读的照计');
    expect(l.skippedMs, 20 * 50);
  });

  test('一两行的快速推进（误点 / 连点）不是快进流，照计', () {
    final _Ledger l = _Ledger();
    l.line('一行目です', 0);
    l.line('二行目', 3000);
    l.line('三行目', 3100); // 二行目只停 100ms
    l.line('四行目', 3200); // 三行目只停 100ms：连续 2 行快，未达门槛
    l.line('五行目です', 8000);
    expect(l.chars, 5 + 3 + 3 + 3 + 5);
    expect(l.skippedMs, 0);
  });

  test('快进跳过的行之后真正读到时照计（没读过的不进去重集合）', () {
    final _Ledger l = _Ledger();
    l.line('最初', 0);
    int t = 4000;
    for (final String text in <String>['甲の台詞', '乙の台詞', '丙の台詞', '丁の台詞']) {
      l.line(text, t);
      t += 30;
    }
    l.line('止まった', t);
    // 读档回去慢慢读刚才跳过的台词。
    l.line('甲の台詞', t + 5000);
    l.line('乙の台詞', t + 9000);
    expect(l.chars, 2 + 4 + 4 + 4);
  });

  test('外部通道无行 id：以前一行为前缀的续写认作同一句', () {
    final GalgameLineStudyGate gate = GalgameLineStudyGate();
    final GalgameLineCharCounter counter = GalgameLineCharCounter();
    int chars = 0;
    void admit(String text, int at) {
      final GalgameLineStudyDecision d = gate.admit(
        lineId: null,
        lineText: text,
        chars: counter.countLine(text),
        atMs: at,
      );
      chars += d.credit - d.retract;
    }

    admit('あ', 0);
    admit('ああ', 20);
    admit('ああ、そう', 40); // 打字机：同一句，20ms 间隔不算快进
    admit('違う台詞だ', 4000); // 5
    admit('ああ、そう', 8000); // 回看重复
    expect(chars, 4 + 5);
  });

  test('门槛常量：可读停留 = max(200ms, 字数 / 40 字每秒)', () {
    expect(galStudyMinDwellMsForChars(0), 200);
    expect(galStudyMinDwellMsForChars(2), 200);
    expect(galStudyMinDwellMsForChars(40), 1000);
    expect(normalizeGalStudyLine('「Hello, World!」\n'), 'helloworld');
  });

  test('重复行的速度门与入账同口径（学习单位），西文 Backlog 不被按字母误判成快进', () {
    // 每行 10 个词：按学习单位可读停留 = max(200, 10/40s) = 250ms；按去空白码点
    // （40+ 字母）却要 1000ms 以上。500ms 一行是正常读速。
    const List<String> lines = <String>[
      'this is a very long english sentence that goes on',
      'we walked along the river until the sun went down',
      'she said nothing and looked out of the old window',
    ];
    const String tail =
        'and then we finally went back home together once again';

    // 首读：500ms 一行，照计、不判快进。
    final _Ledger fresh = _Ledger();
    for (int i = 0; i < lines.length; i++) {
      fresh.line(lines[i], i * 500);
    }
    fresh.line(tail, lines.length * 500);
    expect(fresh.skippedMs, 0);
    expect(fresh.chars, 40);

    // Backlog 按同样节奏回看：重复行字数为 0，但停留判据必须与首读一致——
    // 不是快进流，不扣游玩时长。
    final _Ledger replay = _Ledger();
    for (int i = 0; i < lines.length; i++) {
      replay.line(lines[i], i * 4000);
    }
    const int base = 20000;
    for (int i = 0; i < lines.length; i++) {
      replay.line(lines[i], base + i * 500);
    }
    replay.line(tail, base + lines.length * 500);
    expect(replay.skippedMs, 0);
    expect(replay.chars, 40);
  });

  test('reset 后跨会话的重读照计', () {
    final _Ledger l = _Ledger();
    l.line('同じ台詞', 0);
    l.gate.reset();
    l.counter.reset();
    l.line('同じ台詞', 100000);
    expect(l.chars, 8);
  });
}
