// §4.8「保存到」的落点解析（服务端与桌面 host 共用的 [resolveRemoteMiningTarget]）、单卡牌组覆盖写入与
// 回包的 `landed` / `targetUnavailable`。
import 'dart:convert';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_engine/sync/remote_mining_target.dart';
import 'package:test/test.dart';

const String _a = 'uid-a';
const String _b = 'uid-b';

Future<RemoteMiningResolution?> _resolve(
  RemoteMiningTarget? target, {
  String defaultKind = kRemoteMiningKindAnki,
  bool ankiAvailable = true,
  String? defaultReviewProfile = _a,
  Set<String> served = const <String>{_a, _b},
  Map<String, String> configured = const <String, String>{},
  Set<String>? ankiDecks,
  Map<String, Set<String>>? reviewDecks,
}) => resolveRemoteMiningTarget(
  target,
  defaultKind: defaultKind,
  ankiAvailable: ankiAvailable,
  defaultReviewProfile: defaultReviewProfile,
  servesReviewProfile: served.contains,
  configuredReviewDeck: (String uid) => configured[uid],
  ankiDeckExists: ankiDecks == null
      ? null
      : (String deck) async => ankiDecks.contains(deck),
  reviewDeckExists: reviewDecks == null
      ? null
      : (String uid, String deck) async =>
            reviewDecks[uid]?.contains(deck) ?? false,
);

void main() {
  group('resolveRemoteMiningTarget', () {
    test('不带 target = 主机默认（Anki）', () async {
      expect(
        await _resolve(null),
        const RemoteMiningResolution(kind: kRemoteMiningKindAnki),
      );
    });

    test('主机默认是复习：落默认 profile 与它配置的制卡牌组', () async {
      expect(
        await _resolve(
          null,
          defaultKind: kRemoteMiningKindReview,
          configured: <String, String>{_a: 'Mining'},
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _a,
          deck: 'Mining',
        ),
      );
    });

    test('只带手机自己的 profile（= 主机默认）：主机有那份就落那份', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(profile: _b),
          defaultKind: kRemoteMiningKindReview,
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _b,
        ),
      );
    });

    test('只带 profile 而主机没有那份：落默认 profile，不算退回', () async {
      final RemoteMiningResolution? r = await _resolve(
        const RemoteMiningTarget(profile: 'phone-only'),
        defaultKind: kRemoteMiningKindReview,
      );
      expect(r?.profile, _a);
      expect(r?.fellBack, isFalse);
    });

    test('主机默认是 Anki 时只带 profile：落 Anki，不算退回', () async {
      expect(
        await _resolve(const RemoteMiningTarget(profile: 'phone-only')),
        const RemoteMiningResolution(kind: kRemoteMiningKindAnki),
      );
    });

    test('显式复习 + profile + 牌组：照办', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _b,
            deck: 'Core',
          ),
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _b,
          deck: 'Core',
        ),
      );
    });

    test('显式 Anki 牌组：照办', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(kind: kRemoteMiningKindAnki, deck: 'Core'),
          defaultKind: kRemoteMiningKindReview,
        ),
        const RemoteMiningResolution(kind: kRemoteMiningKindAnki, deck: 'Core'),
      );
    });

    test('显式复习但复习不可用：退到 Anki、不沿用复习牌组、报退回', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _b,
            deck: 'Core',
          ),
          defaultReviewProfile: null,
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindAnki,
          fellBack: true,
        ),
      );
    });

    test('显式 Anki 但 Anki 不可用：退到复习默认 profile、报退回', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(kind: kRemoteMiningKindAnki, deck: 'Core'),
          defaultKind: kRemoteMiningKindReview,
          ankiAvailable: false,
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _a,
          fellBack: true,
        ),
      );
    });

    test('显式点名的 profile 主机没有：整个退回主机默认（不保留所点的类别）、报退回', () async {
      // 主机默认是 Anki：所点的复习类别不保留（拍板 2026-11-08）。
      expect(
        await _resolve(
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: 'gone',
            deck: 'Core',
          ),
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindAnki,
          fellBack: true,
        ),
      );
      // 主机默认是复习：落默认 profile，不沿用别人那份的牌组名。
      expect(
        await _resolve(
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: 'gone',
            deck: 'Core',
          ),
          defaultKind: kRemoteMiningKindReview,
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _a,
          fellBack: true,
        ),
      );
    });

    test('哪儿都写不了：null', () async {
      expect(
        await _resolve(null, ankiAvailable: false, defaultReviewProfile: null),
        isNull,
      );
    });
  });

  group('点名的牌组没有了：整个退回主机默认', () {
    test('复习牌组被删：不落那份 profile 的默认牌组，退到主机默认（Anki）并报退回', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _b,
            deck: 'Deck B',
          ),
          reviewDecks: <String, Set<String>>{
            _b: <String>{'Default'},
          },
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindAnki,
          fellBack: true,
        ),
      );
    });

    test('主机默认是复习：退到默认 profile 与它配置的制卡牌组', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _b,
            deck: 'Deck B',
          ),
          defaultKind: kRemoteMiningKindReview,
          configured: <String, String>{_a: 'Mining'},
          reviewDecks: <String, Set<String>>{
            _a: <String>{'Mining'},
            _b: <String>{'Default'},
          },
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _a,
          deck: 'Mining',
          fellBack: true,
        ),
      );
    });

    test('复习牌组还在：照办', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(
            kind: kRemoteMiningKindReview,
            profile: _b,
            deck: 'Deck B',
          ),
          reviewDecks: <String, Set<String>>{
            _b: <String>{'Deck B'},
          },
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _b,
          deck: 'Deck B',
        ),
      );
    });

    test('Anki 牌组不在主机清单里：退到主机默认（复习默认 profile）并报退回', () async {
      expect(
        await _resolve(
          const RemoteMiningTarget(kind: kRemoteMiningKindAnki, deck: 'Gone'),
          defaultKind: kRemoteMiningKindReview,
          ankiDecks: <String>{'Mining'},
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _a,
          fellBack: true,
        ),
      );
    });

    test('配置给的默认牌组不查（只查手机点名的）', () async {
      expect(
        await _resolve(
          null,
          defaultKind: kRemoteMiningKindReview,
          configured: <String, String>{_a: 'Mining'},
          reviewDecks: <String, Set<String>>{_a: <String>{}},
        ),
        const RemoteMiningResolution(
          kind: kRemoteMiningKindReview,
          profile: _a,
          deck: 'Mining',
        ),
      );
    });
  });

  group('withRemoteMiningDeck', () {
    test('没有牌组：原样', () {
      const String raw = '{"expression":"猫"}';
      expect(withRemoteMiningDeck(raw, null), (raw: raw, own: false));
    });

    test('写进单卡牌组覆盖', () {
      final ({String raw, bool own}) out = withRemoteMiningDeck(
        jsonEncode(<String, String>{'expression': '猫'}),
        'Core',
      );
      expect(out.own, isFalse);
      final Map<String, dynamic> fields =
          jsonDecode(out.raw) as Map<String, dynamic>;
      expect(MiningRequestOverrides.readFrom(fields)?.deckName, 'Core');
    });

    test('这张卡自己选过牌组：不动、报 own', () {
      final String raw = jsonEncode(<String, String>{
        'expression': '猫',
        MiningRequestOverrides.wireKey: jsonEncode(<String, String>{
          'deck': 'Own',
        }),
      });
      expect(withRemoteMiningDeck(raw, 'Core'), (raw: raw, own: true));
    });
  });

  group('remoteMineLandingFor', () {
    const RemoteMineResult ok = RemoteMineResult(result: 'success');

    test('落进点名的牌组：landed 带实际牌组，不报退回', () {
      final RemoteMineLanding l = remoteMineLandingFor(
        ok,
        outcome: const MineOutcome.success(deckName: 'Core'),
        to: const RemoteMiningResolution(
          kind: kRemoteMiningKindAnki,
          deck: 'Core',
        ),
        target: const RemoteMiningTarget(
          kind: kRemoteMiningKindAnki,
          deck: 'Core',
        ),
        ownDeck: false,
      );
      expect(
        l.landed,
        const RemoteMiningTarget(kind: kRemoteMiningKindAnki, deck: 'Core'),
      );
      expect(l.targetUnavailable, isFalse);
    });

    test('点名的牌组主机没有、卡进了默认牌组：报退回', () {
      final RemoteMineLanding l = remoteMineLandingFor(
        ok,
        outcome: const MineOutcome.success(deckName: 'Default'),
        to: const RemoteMiningResolution(
          kind: kRemoteMiningKindAnki,
          deck: 'Gone',
        ),
        target: const RemoteMiningTarget(
          kind: kRemoteMiningKindAnki,
          deck: 'Gone',
        ),
        ownDeck: false,
      );
      expect(l.landed?.deck, 'Default');
      expect(l.targetUnavailable, isTrue);
    });

    test('卡自己选了牌组：实际牌组不同不算退回', () {
      final RemoteMineLanding l = remoteMineLandingFor(
        ok,
        outcome: const MineOutcome.success(deckName: 'Own'),
        to: const RemoteMiningResolution(
          kind: kRemoteMiningKindAnki,
          deck: 'Core',
        ),
        target: const RemoteMiningTarget(
          kind: kRemoteMiningKindAnki,
          deck: 'Core',
        ),
        ownDeck: true,
      );
      expect(l.targetUnavailable, isFalse);
    });

    test('解析时已退回：报退回', () {
      final RemoteMineLanding l = remoteMineLandingFor(
        ok,
        outcome: const MineOutcome.success(deckName: 'Default'),
        to: const RemoteMiningResolution(
          kind: kRemoteMiningKindAnki,
          fellBack: true,
        ),
        target: const RemoteMiningTarget(kind: kRemoteMiningKindReview),
        ownDeck: false,
      );
      expect(l.targetUnavailable, isTrue);
    });
  });
}
