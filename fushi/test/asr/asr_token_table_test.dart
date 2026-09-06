import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/asr/asr_types.dart';

/// 字符级词表（ReazonSpeech 形态：`<token>\t<id>`）。
const String _kCharTokens =
    '<blk>\t0\nあ\t1\nい\t2\n。\t3\n<unk>\t4\n<sos/eos>\t5\n';

/// SentencePiece BPE 词表（LibriHeavy 形态：空格分隔 `<token> <id>`，词首带
/// `▁`，byte-fallback token `<0xNN>`）。
const String _kSpTokens = '<blk> 0\n'
    '<sos/eos> 1\n'
    '<unk> 2\n'
    '<0x50> 3\n'
    '<0x4F> 4\n'
    '<0xE2> 5\n'
    '<0x80> 6\n'
    '<0x99> 7\n'
    '▁the 8\n'
    '▁ 9\n'
    's 10\n'
    'ter 11\n'
    '. 12\n'
    ', 13\n'
    '▁and 14\n'
    '<0xFF> 15\n';

void main() {
  group('字符级词表', () {
    final AsrTokenTable table = AsrTokenTable.parse(_kCharTokens);

    test('不是 SentencePiece，特殊符号 id 正确', () {
      expect(table.isSentencePiece, isFalse);
      expect(table.size, 6);
      expect(table.blankId, 0);
      expect(table.unkId, 4);
      expect(table.eosId, 5);
      expect(table.tokenAt(1), 'あ');
      expect(table.byteValueOf(1), -1);
    });

    test('materialize 原样返回、时间一一对应', () {
      final ({List<String> tokens, List<int> timesMs}) m = table.materialize(
        <int>[1, 2, 3],
        <int>[100, 200, 300],
      );
      expect(m.tokens, <String>['あ', 'い', '。']);
      expect(m.timesMs, <int>[100, 200, 300]);
    });

    test('fromTokenIds 结果 tokens/times 等长且文本拼接正确', () {
      final AsrDecodedSegment seg = AsrDecodedSegment.fromTokenIds(
        table: table,
        ids: const <int>[1, 2, 3],
        offsetsMs: const <int>[40, 80, 120],
      );
      expect(seg.tokens.length, seg.tokenOffsetsMs.length);
      expect(seg.text, 'あい。');
      expect(seg.tokenOffsetsMs, <int>[40, 80, 120]);
    });
  });

  group('SentencePiece BPE 词表', () {
    final AsrTokenTable table = AsrTokenTable.parse(_kSpTokens);

    test('空格分隔的 tokens.txt 也能解析，判定为 SentencePiece', () {
      expect(table.isSentencePiece, isTrue);
      expect(table.size, 16);
      expect(table.blankId, 0);
      expect(table.eosId, 1);
      expect(table.unkId, 2);
      expect(table.tokenAt(8), '▁the');
      expect(table.tokenAt(3), '<0x50>');
    });

    test('byteValueOf 只认 <0xNN> 形态', () {
      expect(table.byteValueOf(3), 0x50);
      expect(table.byteValueOf(4), 0x4F);
      expect(table.byteValueOf(15), 0xFF);
      expect(table.byteValueOf(8), -1);
      expect(table.byteValueOf(12), -1);
      expect(table.byteValueOf(999), -1);
      expect(table.byteValueOf(-1), -1);
    });

    test('▁ 替换成空格', () {
      final ({List<String> tokens, List<int> timesMs}) m = table.materialize(
        <int>[8, 14, 9, 10],
        <int>[10, 20, 30, 40],
      );
      expect(m.tokens, <String>[' the', ' and', ' ', 's']);
      expect(m.timesMs, <int>[10, 20, 30, 40]);
    });

    test('连续 ASCII byte token 合成一段，时间取首字节', () {
      // <0x50><0x4F> + ter + . → 'PO' 'ter' '.'
      final ({List<String> tokens, List<int> timesMs}) m = table.materialize(
        <int>[3, 4, 11, 12],
        <int>[100, 140, 180, 220],
      );
      expect(m.tokens, <String>['PO', 'ter', '.']);
      expect(m.timesMs, <int>[100, 180, 220]);
      expect(m.tokens.join(), 'POter.');
    });

    test('多字节 UTF-8 序列合成一个字符（<0xE2><0x80><0x99> → ’）', () {
      final ({List<String> tokens, List<int> timesMs}) m = table.materialize(
        <int>[8, 5, 6, 7, 10],
        <int>[0, 40, 80, 120, 160],
      );
      expect(m.tokens, <String>[' the', '’', 's']);
      expect(m.timesMs, <int>[0, 40, 160]);
    });

    test('段尾的字节序列也会冲出', () {
      final ({List<String> tokens, List<int> timesMs}) m = table.materialize(
        <int>[8, 3],
        <int>[0, 40],
      );
      expect(m.tokens, <String>[' the', 'P']);
      expect(m.timesMs, <int>[0, 40]);
    });

    test('坏字节序列不抛，按 allowMalformed 替换', () {
      // 0xFF 不是合法 UTF-8 首字节；0xE2 0x80 后面缺一个续字节。
      final ({List<String> tokens, List<int> timesMs}) m = table.materialize(
        <int>[15, 8, 5, 6, 10],
        <int>[0, 10, 20, 30, 40],
      );
      expect(m.tokens.length, m.timesMs.length);
      expect(m.tokens.length, 4);
      expect(m.tokens[0], '�');
      expect(m.tokens[1], ' the');
      expect(m.tokens[2], contains('�'));
      expect(m.tokens[3], 's');
      expect(m.timesMs, <int>[0, 10, 20, 40]);
    });

    test('空输入返回空', () {
      final ({List<String> tokens, List<int> timesMs}) m = table.materialize(
        <int>[],
        <int>[],
      );
      expect(m.tokens, isEmpty);
      expect(m.timesMs, isEmpty);
    });

    test('fromTokenIds：tokens/times 等长，合并后比输入短', () {
      final AsrDecodedSegment seg = AsrDecodedSegment.fromTokenIds(
        table: table,
        ids: const <int>[3, 4, 11, 13, 8, 5, 6, 7, 10, 12],
        offsetsMs: const <int>[0, 40, 80, 120, 160, 200, 240, 280, 320, 360],
      );
      expect(seg.tokens.length, seg.tokenOffsetsMs.length);
      expect(seg.tokens, <String>['PO', 'ter', ',', ' the', '’', 's', '.']);
      expect(seg.tokenOffsetsMs, <int>[0, 80, 120, 160, 200, 320, 360]);
      expect(seg.text, 'POter, the’s.');
      expect(seg.isEmpty, isFalse);
    });
  });

  group('parse 健壮性', () {
    test('CRLF、空行、坏行都能容忍；id 缺号补空串', () {
      final AsrTokenTable table = AsrTokenTable.parse(
        '<blk>\t0\r\n\r\nあ\t1\r\nbad line\nx\t3\n',
      );
      expect(table.size, 4);
      expect(table.tokenAt(0), '<blk>');
      expect(table.tokenAt(1), 'あ');
      expect(table.tokenAt(2), '');
      expect(table.tokenAt(3), 'x');
      expect(table.tokenAt(4), '');
      expect(table.unkId, -1);
      expect(table.eosId, -1);
    });

    test('空格本身作为 token 时用最后一个分隔符切分', () {
      final AsrTokenTable table = AsrTokenTable.parse('<blk>\t0\n \t1\n');
      expect(table.tokenAt(1), ' ');
      expect(table.isSentencePiece, isFalse);
    });
  });
}
