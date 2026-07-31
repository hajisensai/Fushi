import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/anti_leech.dart';

const int kMiB = 1024 * 1024;

/// 造 peer 快照；默认是一个正常 qBittorrent peer。
PeerSnapshot peer({
  String ip = '1.2.3.4',
  String peerId = '-qB4650-0123456789ab',
  String client = 'qBittorrent 4.6.5',
  double reportedProgress = 0,
  int totalUpload = 0,
  int totalDownload = 0,
  int port = 0,
}) {
  return PeerSnapshot(
    ip: ip,
    peerId: peerId,
    client: client,
    reportedProgress: reportedProgress,
    totalUpload: totalUpload,
    totalDownload: totalDownload,
    port: port,
  );
}

/// 造种子上下文；默认 100 MiB、非做种（超过默认 PCB 最小种子大小）。
TorrentContext ctx({
  String infoHash = 'hash-a',
  int totalSize = 100 * kMiB,
  int? completedSize,
  bool isSeeding = false,
}) {
  return TorrentContext(
    infoHash: infoHash,
    totalSize: totalSize,
    completedSize: completedSize,
    isSeeding: isSeeding,
  );
}

void main() {
  group('cidrOf', () {
    test('IPv4 默认 /24', () {
      expect(cidrOf('1.2.3.4'), '1.2.3.0/24');
      expect(cidrOf('10.0.0.255'), '10.0.0.0/24');
    });

    test('IPv4 自定义前缀', () {
      expect(cidrOf('1.2.3.4', ipv4Prefix: 16), '1.2.0.0/16');
      expect(cidrOf('1.2.3.4', ipv4Prefix: 32), '1.2.3.4/32');
    });

    test('IPv6 默认 /60（非整字节掩码）', () {
      // /60 = 前 7 字节 + 第 8 字节高 4 位：0xf5 → 0xf0。
      expect(
        cidrOf('2001:db8:aaaa:bbf5::1'),
        '2001:db8:aaaa:bbf0:0:0:0:0/60',
      );
    });

    test('IPv6 自定义前缀 /64', () {
      expect(
        cidrOf('2001:db8:aaaa:bbf5::1', ipv6Prefix: 64),
        '2001:db8:aaaa:bbf5:0:0:0:0/64',
      );
    });

    test('非法 IPv4 返回 ip/32', () {
      expect(cidrOf('foo.bar'), 'foo.bar/32');
      expect(cidrOf('1.2.3.999'), '1.2.3.999/32');
      expect(cidrOf('1.2.3'), '1.2.3/32');
    });

    test('非法 IPv6 原样返回', () {
      expect(cidrOf('zz::1'), 'zz::1');
    });
  });

  group('ipInCidr', () {
    test('IPv4 /24 边界内外', () {
      expect(ipInCidr('1.2.3.99', '1.2.3.0/24'), isTrue);
      expect(ipInCidr('1.2.3.255', '1.2.3.0/24'), isTrue);
      expect(ipInCidr('1.2.4.0', '1.2.3.0/24'), isFalse);
      expect(ipInCidr('2.2.3.4', '1.2.3.0/24'), isFalse);
    });

    test('前缀 0 匹配一切 IPv4', () {
      expect(ipInCidr('9.9.9.9', '0.0.0.0/0'), isTrue);
    });

    test('IPv6 /60 边界内外', () {
      const String cidr = '2001:db8:aaaa:bbf0:0:0:0:0/60';
      expect(ipInCidr('2001:db8:aaaa:bbf5::9', cidr), isTrue);
      expect(ipInCidr('2001:db8:aaaa:bbe0::9', cidr), isFalse);
      expect(ipInCidr('2001:db8:aaab:bbf0::9', cidr), isFalse);
    });

    test('地址族不匹配返回 false', () {
      expect(ipInCidr('::1', '1.2.3.0/24'), isFalse);
      expect(ipInCidr('1.2.3.4', '2001:db8:0:0:0:0:0:0/60'), isFalse);
    });

    test('非法输入容错', () {
      expect(ipInCidr('1.2.3.4', 'garbage/24'), isFalse);
      expect(ipInCidr('not-an-ip', '1.2.3.0/24'), isFalse);
      expect(ipInCidr('1.2.3.4', '1.2.3.0/abc'), isFalse);
      expect(ipInCidr('1.2.3.4', '1.2.3.0/40'), isFalse);
      // 无 `/` 的 cidr（IPv6 非法回退产物）退化为精确串比较。
      expect(ipInCidr('zz::1', 'zz::1'), isTrue);
      expect(ipInCidr('zz::2', 'zz::1'), isFalse);
    });
  });

  group('PCB 进度作弊检测', () {
    late AntiLeechEngine engine;

    setUp(() => engine = AntiLeechEngine());

    // 默认宽限 60000ms：t0 首见（宽限内），t1 已出宽限。
    const int t0 = 1000;
    const int t1 = t0 + 60000;

    test('differenceTest：喂出 50% 却自报 5% → ban', () {
      final PeerSnapshot p =
          peer(totalUpload: 50 * kMiB, reportedProgress: 0.05);
      // 首轮在宽限窗口内 → allow。
      final Map<String, BanVerdict> r0 =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      expect(r0['1.2.3.4']!.banned, isFalse);
      // 出宽限后 → ban(progressCheat)。
      final Map<String, BanVerdict> r1 =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1);
      expect(r1['1.2.3.4']!.banned, isTrue);
      expect(r1['1.2.3.4']!.reason, BanReason.progressCheat);
      expect(r1['1.2.3.4']!.cidr, isNull);
    });

    test('自报与计算一致 → allow', () {
      final PeerSnapshot p =
          peer(totalUpload: 50 * kMiB, reportedProgress: 0.5);
      engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1);
      expect(r['1.2.3.4']!.banned, isFalse);
    });

    test('宽限窗口内即使作弊数值也 allow', () {
      final PeerSnapshot p =
          peer(totalUpload: 50 * kMiB, reportedProgress: 0.05);
      final Map<String, BanVerdict> r0 =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      expect(r0['1.2.3.4']!.banned, isFalse);
      // 仍在窗口内（差 1ms 到期）。
      final Map<String, BanVerdict> r1 =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1 - 1);
      expect(r1['1.2.3.4']!.banned, isFalse);
    });

    test('totalUpload==0 且无峰值 → allow（无从判定）', () {
      final PeerSnapshot p = peer(totalUpload: 0, reportedProgress: 0);
      engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1);
      expect(r['1.2.3.4']!.banned, isFalse);
    });

    test('小种子跳过 PCB', () {
      final TorrentContext small = ctx(totalSize: 10 * kMiB);
      final PeerSnapshot p = peer(totalUpload: 5 * kMiB, reportedProgress: 0);
      engine.evaluate(<PeerSnapshot>[p], small, nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], small, nowMs: t1);
      expect(r['1.2.3.4']!.banned, isFalse);
    });

    test('progressRewind：进度从 0.6 退到 0.5 → ban', () {
      // 宽限轮登记 lastProgress=0.6（上传量小，differenceTest 不触发）。
      engine.evaluate(
        <PeerSnapshot>[peer(totalUpload: kMiB, reportedProgress: 0.6)],
        ctx(),
        nowMs: t0,
      );
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(totalUpload: kMiB, reportedProgress: 0.5)],
        ctx(),
        nowMs: t1,
      );
      expect(r['1.2.3.4']!.banned, isTrue);
      expect(r['1.2.3.4']!.reason, BanReason.progressRewind);
    });

    test('小幅进度回落不超阈值 → allow', () {
      engine.evaluate(
        <PeerSnapshot>[peer(totalUpload: kMiB, reportedProgress: 0.6)],
        ctx(),
        nowMs: t0,
      );
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(totalUpload: kMiB, reportedProgress: 0.57)],
        ctx(),
        nowMs: t1,
      );
      expect(r['1.2.3.4']!.banned, isFalse);
    });

    test('excessiveDownload：单 peer 上传 3.5x 种子 → ban', () {
      final PeerSnapshot p =
          peer(totalUpload: 350 * kMiB, reportedProgress: 1.0);
      engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1);
      expect(r['1.2.3.4']!.banned, isTrue);
      expect(r['1.2.3.4']!.reason, BanReason.excessiveDownload);
    });

    test('excessiveDownload：未完成任务用 completedSize 做基准', () {
      // completedSize=50MiB，上传 160MiB > 50*3=150MiB → ban；
      // 若按 totalSize=100MiB 则 160 < 300 不会 ban。
      final TorrentContext partial = ctx(completedSize: 50 * kMiB);
      final PeerSnapshot p =
          peer(totalUpload: 160 * kMiB, reportedProgress: 1.0);
      engine.evaluate(<PeerSnapshot>[p], partial, nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], partial, nowMs: t1);
      expect(r['1.2.3.4']!.banned, isTrue);
      expect(r['1.2.3.4']!.reason, BanReason.excessiveDownload);
    });

    test('峰值抗断连：断连重连 totalUpload 归零仍按峰值判 → 仍 ban', () {
      // 首轮建峰值 50MiB（自报一致，宽限内也不会 ban）。
      engine.evaluate(
        <PeerSnapshot>[peer(totalUpload: 50 * kMiB, reportedProgress: 0.5)],
        ctx(),
        nowMs: t0,
      );
      // 断连重连：totalUpload=0、自报 0.05 → computedUploaded 按峰值 50MiB，
      // computedProgress 0.5 - 0.05 = 0.45 > 0.08 → ban。
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(totalUpload: 0, reportedProgress: 0.05)],
        ctx(),
        nowMs: t1,
      );
      expect(r['1.2.3.4']!.banned, isTrue);
      expect(r['1.2.3.4']!.reason, BanReason.progressCheat);
    });
  });

  group('抄 ClientBlocker：新增规则', () {
    const int t0 = 1000;
    const int t1 = t0 + 60000;

    test('ignoreEmptyPeer：peerId+client 全空 → allow（不误判）', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      final PeerSnapshot p = peer(
          peerId: '', client: '', totalUpload: 50 * kMiB, reportedProgress: 0);
      engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1);
      expect(r['1.2.3.4']!.banned, isFalse);
    });

    test('ignoreByDownloaded：从该 peer 下载超阈值 → 不自动封', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      // 作弊数值（喂 50MiB 自报 5%）但它给了我们 200MiB → 豁免。
      final PeerSnapshot p = peer(
        totalUpload: 50 * kMiB,
        reportedProgress: 0.05,
        totalDownload: 200 * kMiB,
      );
      engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1);
      expect(r['1.2.3.4']!.banned, isFalse);
    });

    test('banByProgressUploaded（opt-in）：喂 30MiB 自报 0% → ban', () {
      final AntiLeechEngine engine = AntiLeechEngine(
        config: const AntiLeechConfig(
          banByProgressUploaded: true,
          // 关掉 differenceTest 干扰：调大阈值让它不先命中。
          maxProgressDifference: 2.0,
        ),
      );
      final PeerSnapshot p = peer(totalUpload: 30 * kMiB, reportedProgress: 0);
      engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1);
      expect(r['1.2.3.4']!.reason, BanReason.progressUploadedCheat);
    });

    test('banByProgressUploaded：默认关 → 不因该规则封', () {
      final AntiLeechEngine engine = AntiLeechEngine(
        config: const AntiLeechConfig(maxProgressDifference: 2.0),
      );
      final PeerSnapshot p = peer(totalUpload: 30 * kMiB, reportedProgress: 0);
      engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t0);
      final Map<String, BanVerdict> r =
          engine.evaluate(<PeerSnapshot>[p], ctx(), nowMs: t1);
      expect(r['1.2.3.4']!.banned, isFalse);
    });

    test('banByRelativeProgressUploaded（opt-in）：进度不动却猛喂增量 → ban', () {
      final AntiLeechEngine engine = AntiLeechEngine(
        config: const AntiLeechConfig(
          banByRelativeProgressUploaded: true,
          maxProgressDifference: 2.0, // 让 differenceTest 不先命中
        ),
      );
      // t0（宽限内）建基准 upload=10MiB progress=0.5。
      engine.evaluate(
        <PeerSnapshot>[peer(totalUpload: 10 * kMiB, reportedProgress: 0.5)],
        ctx(),
        nowMs: t0,
      );
      // t1：进度仍 0.5（增量 0），却又喂了 40MiB 增量 → 相对作弊。
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(totalUpload: 50 * kMiB, reportedProgress: 0.5)],
        ctx(),
        nowMs: t1,
      );
      expect(r['1.2.3.4']!.reason, BanReason.relativeProgressUploadedCheat);
    });

    test('maxIpPortCount（opt-in）：同 IP 端口数超容忍 → ban(multiPort)', () {
      final AntiLeechEngine engine =
          AntiLeechEngine(config: const AntiLeechConfig(maxIpPortCount: 2));
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[
          peer(ip: '5.5.5.5', port: 1001),
          peer(ip: '5.5.5.5', port: 1002),
          peer(ip: '5.5.5.5', port: 1003),
        ],
        ctx(),
        nowMs: 0,
      );
      // 前两个端口在容忍内；第三个超 2 → multiPort。
      expect(r['5.5.5.5']!.reason, BanReason.multiPort);
    });

    test('banTime：到期 pruneExpired 解封；永久(0)不解封', () {
      final AntiLeechEngine engine = AntiLeechEngine(
        config: const AntiLeechConfig(banTimeMs: 10000),
      );
      // BUG-1274/1275 契约变更：身份黑名单仅做种期生效，且登记单 IP /32。
      engine.evaluate(
        <PeerSnapshot>[peer(peerId: '-SD0100-abcdefabcdef')],
        ctx(isSeeding: true),
        nowMs: 1000,
      );
      expect(engine.bannedCidrs, contains('1.2.3.4/32'));
      // 未到期（1000+10000=11000）→ 不解封。
      expect(engine.pruneExpired(10999), isFalse);
      expect(engine.bannedCidrs, contains('1.2.3.4/32'));
      // 到期 → 解封。
      expect(engine.pruneExpired(11000), isTrue);
      expect(engine.bannedCidrs, isEmpty);

      // banTimeMs=0（默认永久）：prune 永不解封。
      final AntiLeechEngine perm = AntiLeechEngine();
      perm.evaluate(
        <PeerSnapshot>[peer(peerId: '-SD0100-abcdefabcdef')],
        ctx(isSeeding: true),
        nowMs: 1000,
      );
      expect(perm.pruneExpired(999999999), isFalse);
      expect(perm.bannedCidrs, contains('1.2.3.4/32'));
    });
  });

  group('PeerId/ClientName 黑名单', () {
    late AntiLeechEngine engine;

    setUp(() => engine = AntiLeechEngine());

    test('迅雷 peerId 做种时 → ban（BUG-1274 后走统一黑名单路径）', () {
      // 契约变更（BUG-1274）：旧迅雷特例消除，-XL 命中普通 peerIdBlacklist，
      // 引擎不再产生 BanReason.xunleiSeeding；做种期封的行为与原特例等价。
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(peerId: '-XL0012-abcdefabcdef')],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r['1.2.3.4']!.banned, isTrue);
      expect(r['1.2.3.4']!.reason, BanReason.peerIdBlacklist);
    });

    test('迅雷 peerId 非做种 → allow（可能是正常下载者）', () {
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(peerId: '-XL0012-abcdefabcdef')],
        ctx(isSeeding: false),
        nowMs: 0,
      );
      expect(r['1.2.3.4']!.banned, isFalse);
    });

    test('client 以 thunder 开头：下载期放行、做种期封（与原特例等价）', () {
      // 契约变更（BUG-1274）：thunder 关键词命中普通 clientBlacklist。
      final PeerSnapshot p = peer(client: 'Thunder 11.3.1');
      expect(
        engine.evaluate(<PeerSnapshot>[p], ctx(isSeeding: false),
            nowMs: 0)['1.2.3.4']!.banned,
        isFalse,
      );
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(ip: '1.2.4.4', client: 'Thunder 11.3.1')],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r['1.2.4.4']!.reason, BanReason.clientBlacklist);
    });

    test('peerId 前缀 -SD：下载期放行、做种期 ban（BUG-1274 契约变更）', () {
      // 旧契约「与做种无关直接 ban」已废：下载期封 peer 只减少自己的数据源。
      final Map<String, BanVerdict> r0 = engine.evaluate(
        <PeerSnapshot>[peer(peerId: '-SD0100-abcdefabcdef')],
        ctx(isSeeding: false),
        nowMs: 0,
      );
      expect(r0['1.2.3.4']!.banned, isFalse);
      final Map<String, BanVerdict> r1 = engine.evaluate(
        <PeerSnapshot>[peer(peerId: '-SD0100-abcdefabcdef')],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r1['1.2.3.4']!.banned, isTrue);
      expect(r1['1.2.3.4']!.reason, BanReason.peerIdBlacklist);
    });

    test('client 含 thunder（非开头）做种期 → ban(clientBlacklist)', () {
      // BUG-1274 契约变更：身份判定只在做种期跑，用例改为做种上下文。
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(client: 'Fake thunder mod')],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r['1.2.3.4']!.banned, isTrue);
      expect(r['1.2.3.4']!.reason, BanReason.clientBlacklist);
    });

    test('正常客户端 → allow', () {
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer()],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r['1.2.3.4']!.banned, isFalse);
    });
  });

  group('MultiDialing 多拨', () {
    late AntiLeechEngine engine;

    setUp(() => engine = AntiLeechEngine());

    test('同 /24 同种子第 9 个 IP（超容忍 8）→ ban 段，同轮后续同段连坐', () {
      final List<PeerSnapshot> peers = <PeerSnapshot>[
        for (int i = 1; i <= 10; i++) peer(ip: '1.2.3.$i'),
      ];
      final Map<String, BanVerdict> r = engine.evaluate(peers, ctx(), nowMs: 0);
      for (int i = 1; i <= 8; i++) {
        expect(r['1.2.3.$i']!.banned, isFalse, reason: 'ip 1.2.3.$i');
      }
      expect(r['1.2.3.9']!.banned, isTrue);
      expect(r['1.2.3.9']!.reason, BanReason.multiDialing);
      expect(r['1.2.3.9']!.cidr, '1.2.3.0/24');
      // 第 10 个：段已进连坐源 → autoRangeBan。
      expect(r['1.2.3.10']!.reason, BanReason.autoRangeBan);
    });

    test('计数跨 evaluate 轮累积', () {
      engine.evaluate(
        <PeerSnapshot>[for (int i = 1; i <= 5; i++) peer(ip: '7.7.7.$i')],
        ctx(),
        nowMs: 0,
      );
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[for (int i = 6; i <= 9; i++) peer(ip: '7.7.7.$i')],
        ctx(),
        nowMs: 1000,
      );
      expect(r['7.7.7.8']!.banned, isFalse);
      expect(r['7.7.7.9']!.reason, BanReason.multiDialing);
    });

    test('不同种子的同段连接不互相计数', () {
      final List<PeerSnapshot> five = <PeerSnapshot>[
        for (int i = 1; i <= 5; i++) peer(ip: '8.8.8.$i'),
      ];
      final Map<String, BanVerdict> rA =
          engine.evaluate(five, ctx(infoHash: 'hash-a'), nowMs: 0);
      final Map<String, BanVerdict> rB =
          engine.evaluate(five, ctx(infoHash: 'hash-b'), nowMs: 0);
      expect(rA.values.every((BanVerdict v) => !v.banned), isTrue);
      expect(rB.values.every((BanVerdict v) => !v.banned), isTrue);
    });
  });

  group('AutoRangeBan 连坐与规则短路顺序', () {
    late AntiLeechEngine engine;

    setUp(() => engine = AntiLeechEngine());

    test('一个 IP 被 PCB ban 后，同 /24 另一 IP 下轮直接连坐', () {
      final PeerSnapshot cheat =
          peer(ip: '1.2.3.4', totalUpload: 50 * kMiB, reportedProgress: 0.05);
      engine.evaluate(<PeerSnapshot>[cheat], ctx(), nowMs: 0);
      final Map<String, BanVerdict> r1 =
          engine.evaluate(<PeerSnapshot>[cheat], ctx(), nowMs: 60000);
      expect(r1['1.2.3.4']!.reason, BanReason.progressCheat);
      expect(engine.bannedCidrs, contains('1.2.3.0/24'));

      final Map<String, BanVerdict> r2 = engine.evaluate(
        <PeerSnapshot>[peer(ip: '1.2.3.5')],
        ctx(),
        nowMs: 61000,
      );
      expect(r2['1.2.3.5']!.banned, isTrue);
      expect(r2['1.2.3.5']!.reason, BanReason.autoRangeBan);
      expect(r2['1.2.3.5']!.cidr, '1.2.3.0/24');
    });

    test('连坐优先于黑名单：已封 IP 重连报 autoRangeBan', () {
      // BUG-1275 后身份 ban 只登记 /32，同段邻居不再连坐；改用同 IP 重连
      // 验证规则 ① 仍优先于 ②。
      engine.evaluate(
        <PeerSnapshot>[peer(ip: '9.9.9.1', peerId: '-SD0100-abcdefabcdef')],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(ip: '9.9.9.1', peerId: '-SD0100-abcdefabcdef')],
        ctx(isSeeding: true),
        nowMs: 1000,
      );
      expect(r['9.9.9.1']!.reason, BanReason.autoRangeBan);
      expect(r['9.9.9.1']!.cidr, '9.9.9.1/32');
    });

    test('做种期黑名单优先于 PCB 且不受宽限窗口保护', () {
      // 首见即判（PCB 此时还在宽限窗口内）。BUG-1274 后需做种上下文。
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[
          peer(
            peerId: '-SD0100-abcdefabcdef',
            totalUpload: 50 * kMiB,
            reportedProgress: 0.05,
          ),
        ],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r['1.2.3.4']!.reason, BanReason.peerIdBlacklist);
    });

    test('IPv6 peer 被行为规则（PCB）ban 后同 /60 段连坐', () {
      // BUG-1275 后身份 ban 不再登记段；行为类（PCB）仍走段默认。用
      // progressCheat 驱动，验证 IPv6 /60 连坐对行为类保持不变。
      final PeerSnapshot cheat = peer(
        ip: '2001:db8:aaaa:bbf5::1',
        totalUpload: 50 * kMiB,
        reportedProgress: 0.05,
      );
      engine.evaluate(<PeerSnapshot>[cheat], ctx(), nowMs: 0);
      final Map<String, BanVerdict> r0 =
          engine.evaluate(<PeerSnapshot>[cheat], ctx(), nowMs: 60000);
      expect(r0['2001:db8:aaaa:bbf5::1']!.reason, BanReason.progressCheat);
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(ip: '2001:db8:aaaa:bbf9::2')],
        ctx(),
        nowMs: 61000,
      );
      expect(r['2001:db8:aaaa:bbf9::2']!.reason, BanReason.autoRangeBan);
      expect(r['2001:db8:aaaa:bbf9::2']!.cidr, '2001:db8:aaaa:bbf0:0:0:0:0/60');
    });
  });
  group('身份黑名单相位与粒度（BUG-1274 / BUG-1275）', () {
    const int t0 = 1000;
    const int t1 = t0 + 60000;

    test('BUG-1274：下载期 -SD 放行且继续走 PCB（伪造进度照样被封）', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      // 黑名单身份 + 作弊数值：下载期不因身份封，但 PCB 出宽限后照封。
      final PeerSnapshot p = peer(
        peerId: '-SD0100-abcdefabcdef',
        totalUpload: 50 * kMiB,
        reportedProgress: 0.05,
      );
      final Map<String, BanVerdict> r0 =
          engine.evaluate(<PeerSnapshot>[p], ctx(isSeeding: false), nowMs: t0);
      expect(r0['1.2.3.4']!.banned, isFalse);
      final Map<String, BanVerdict> r1 =
          engine.evaluate(<PeerSnapshot>[p], ctx(isSeeding: false), nowMs: t1);
      expect(r1['1.2.3.4']!.reason, BanReason.progressCheat);
    });

    test('BUG-1274：下载期 xfplay / dandanplay client 放行', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[
          peer(ip: '1.1.1.1', client: 'XfPlay 5.0'),
          peer(ip: '1.1.1.2', client: 'dandanplay/1.2'),
        ],
        ctx(isSeeding: false),
        nowMs: 0,
      );
      expect(r['1.1.1.1']!.banned, isFalse);
      expect(r['1.1.1.2']!.banned, isFalse);
    });

    test('BUG-1274：做种期同类身份照封', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[
          peer(ip: '1.1.1.1', peerId: '-SD0100-abcdefabcdef'),
          peer(ip: '2.1.1.1', client: 'XfPlay 5.0'),
          peer(ip: '3.1.1.1', client: 'dandanplay/1.2'),
        ],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r['1.1.1.1']!.reason, BanReason.peerIdBlacklist);
      expect(r['2.1.1.1']!.reason, BanReason.clientBlacklist);
      expect(r['3.1.1.1']!.reason, BanReason.clientBlacklist);
    });

    test('BUG-1274：做种期但 totalDownload≥豁免阈值 → 不因身份封', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      // 默认 ignoreByDownloadedBytes = 100MiB；它喂过我们 200MiB。
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[
          peer(peerId: '-SD0100-abcdefabcdef', totalDownload: 200 * kMiB),
        ],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r['1.2.3.4']!.banned, isFalse);

      // 豁免关闭（0）时不豁免 → 照封。
      final AntiLeechEngine noExempt = AntiLeechEngine(
        config: const AntiLeechConfig(ignoreByDownloadedBytes: 0),
      );
      final Map<String, BanVerdict> r2 = noExempt.evaluate(
        <PeerSnapshot>[
          peer(peerId: '-SD0100-abcdefabcdef', totalDownload: 200 * kMiB),
        ],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r2['1.2.3.4']!.reason, BanReason.peerIdBlacklist);
    });

    test('BUG-1275：身份命中登记单 IP /32，同段其它 IP 不连坐', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[peer(peerId: '-SD0100-abcdefabcdef')],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r['1.2.3.4']!.cidr, '1.2.3.4/32');
      expect(engine.bannedCidrs, contains('1.2.3.4/32'));
      expect(engine.bannedCidrs, isNot(contains('1.2.3.0/24')));
      // 同 /24 的正常邻居下轮不被 AutoRangeBan 连坐。
      final Map<String, BanVerdict> r2 = engine.evaluate(
        <PeerSnapshot>[peer(ip: '1.2.3.5')],
        ctx(isSeeding: true),
        nowMs: 1000,
      );
      expect(r2['1.2.3.5']!.banned, isFalse);
    });

    test('BUG-1275：IPv6 身份命中登记 /128，同 /60 邻居不连坐', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      final Map<String, BanVerdict> r = engine.evaluate(
        <PeerSnapshot>[
          peer(ip: '2001:db8:aaaa:bbf5::1', peerId: '-SD0100-abcdefabcdef'),
        ],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(
        r['2001:db8:aaaa:bbf5::1']!.cidr,
        '2001:db8:aaaa:bbf5:0:0:0:1/128',
      );
      final Map<String, BanVerdict> r2 = engine.evaluate(
        <PeerSnapshot>[peer(ip: '2001:db8:aaaa:bbf9::2')],
        ctx(isSeeding: true),
        nowMs: 1000,
      );
      expect(r2['2001:db8:aaaa:bbf9::2']!.banned, isFalse);
    });

    test('BUG-1274：迅雷 -XL 走统一路径后行为与原特例等价', () {
      final AntiLeechEngine engine = AntiLeechEngine();
      // 下载期放行（原特例语义），且作弊数值仍会被 PCB 封。
      final PeerSnapshot xl = peer(
        peerId: '-XL0012-abcdefabcdef',
        totalUpload: 50 * kMiB,
        reportedProgress: 0.05,
      );
      final Map<String, BanVerdict> r0 =
          engine.evaluate(<PeerSnapshot>[xl], ctx(isSeeding: false), nowMs: t0);
      expect(r0['1.2.3.4']!.banned, isFalse);
      final Map<String, BanVerdict> r1 =
          engine.evaluate(<PeerSnapshot>[xl], ctx(isSeeding: false), nowMs: t1);
      expect(r1['1.2.3.4']!.reason, BanReason.progressCheat);

      // 做种期封（原特例语义），reason 从 xunleiSeeding 变为统一黑名单值。
      final AntiLeechEngine seeding = AntiLeechEngine();
      final Map<String, BanVerdict> r2 = seeding.evaluate(
        <PeerSnapshot>[peer(ip: '4.3.2.1', peerId: '-XL0012-abcdefabcdef')],
        ctx(isSeeding: true),
        nowMs: 0,
      );
      expect(r2['4.3.2.1']!.banned, isTrue);
      expect(r2['4.3.2.1']!.reason, BanReason.peerIdBlacklist);
      expect(r2['4.3.2.1']!.cidr, '4.3.2.1/32');
    });
  });
}
