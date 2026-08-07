// TODO-2482：内置引擎 peer flags 位掩码 → qb 风格字母串。
//
// 位定义与 native/hibiki_torrent 头文件契约逐位对齐（TorrentPeerFlagBits），
// 这里守住字母映射的语义分支：D/d、U/u、K、?、修饰位、全 0 哨兵。

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/torrent_task_display.dart';

void main() {
  group('formatTorrentPeerFlags', () {
    test('全 0（老 DLL 无该字段）返回空串哨兵', () {
      expect(formatTorrentPeerFlags(0), '');
    });

    test('感兴趣且对端未 choke 我们 = 正在下载 D', () {
      final String flags =
          formatTorrentPeerFlags(TorrentPeerFlagBits.interesting);
      expect(flags.split(' '), contains('D'));
      expect(flags.split(' '), isNot(contains('d')));
    });

    test('感兴趣但被对端 choke = d（想下未遂）', () {
      final String flags = formatTorrentPeerFlags(
          TorrentPeerFlagBits.interesting | TorrentPeerFlagBits.remoteChoked);
      expect(flags.split(' '), contains('d'));
      expect(flags.split(' '), isNot(contains('D')));
    });

    test('对端感兴趣且我们未 choke = 正在上传 U', () {
      final String flags =
          formatTorrentPeerFlags(TorrentPeerFlagBits.remoteInterested);
      expect(flags.split(' '), contains('U'));
      expect(flags.split(' '), isNot(contains('u')));
    });

    test('对端感兴趣但被我们 choke = u', () {
      final String flags = formatTorrentPeerFlags(
          TorrentPeerFlagBits.remoteInterested | TorrentPeerFlagBits.choked);
      expect(flags.split(' '), contains('u'));
      expect(flags.split(' '), isNot(contains('U')));
    });

    test('对端没 choke 我们但我们不感兴趣 = K', () {
      // 双方常态开局：双向 choke —— 只置 remoteInterested 位时我们未 choke
      // 对端也未被对端解锁……用一个真实组合：seed 位 + 双向 choke。
      final String flags = formatTorrentPeerFlags(
          TorrentPeerFlagBits.seed | TorrentPeerFlagBits.choked);
      // 我们不感兴趣（bit0=0）且对端未 choke 我们（bit3=0）→ K。
      expect(flags.split(' '), contains('K'));
    });

    test('修饰位：乐观解锁 O / snubbed S / 入站 I / 加密 E / uTP P / 洞穿 H', () {
      final String flags = formatTorrentPeerFlags(
        TorrentPeerFlagBits.interesting |
            TorrentPeerFlagBits.outgoingConnection |
            TorrentPeerFlagBits.optimisticUnchoke |
            TorrentPeerFlagBits.snubbed |
            TorrentPeerFlagBits.rc4Encrypted |
            TorrentPeerFlagBits.utpSocket |
            TorrentPeerFlagBits.holepunched,
      );
      final List<String> parts = flags.split(' ');
      expect(parts, containsAll(<String>['O', 'S', 'E', 'P', 'H']));
      // 出站连接：不该有 I。
      expect(parts, isNot(contains('I')));
    });

    test('入站连接（无 outgoing 位）标 I', () {
      final String flags = formatTorrentPeerFlags(
          TorrentPeerFlagBits.interesting | TorrentPeerFlagBits.remoteChoked);
      expect(flags.split(' '), contains('I'));
    });
  });
}
