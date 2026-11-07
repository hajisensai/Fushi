// 远程复习打开主机上的哪份 profile（docs/specs/2026-11-05-server-srs-design.md §4.4）：
// 本机自己的在主机提供的里面就直接打开；主机有几份又没有本机的才让用户选；只有一份 / 老主机照旧开主机那份。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_remote_store_client.dart';
import 'package:fushi_engine/srs/srs_remote_store.dart';

void main() {
  const SrsRemoteServedProfile ja = SrsRemoteServedProfile(
    uid: 'ja',
    name: 'Japanese',
  );
  const SrsRemoteServedProfile zh = SrsRemoteServedProfile(
    uid: 'zh',
    name: 'Chinese',
  );

  Future<String?> neverAsked(List<SrsRemoteServedProfile> _) =>
      fail('should not ask the user');

  test('本机的 profile 在主机提供的里面：直接打开它，不问', () async {
    expect(
      await srsPickRemoteProfile(
        hostDefault: 'ja',
        served: const <SrsRemoteServedProfile>[ja, zh],
        preferProfile: 'zh',
        chooseProfile: neverAsked,
      ),
      'zh',
    );
  });

  test('主机有几份但没有本机的：让用户选；取消就抛 cancelled', () async {
    expect(
      await srsPickRemoteProfile(
        hostDefault: 'ja',
        served: const <SrsRemoteServedProfile>[ja, zh],
        preferProfile: 'ko',
        chooseProfile: (List<SrsRemoteServedProfile> p) async => p.last.uid,
      ),
      'zh',
    );
    await expectLater(
      srsPickRemoteProfile(
        hostDefault: 'ja',
        served: const <SrsRemoteServedProfile>[ja, zh],
        preferProfile: 'ko',
        chooseProfile: (List<SrsRemoteServedProfile> _) async => null,
      ),
      throwsA(isA<SrsRemoteProfileChoiceCancelled>()),
    );
  });

  test('桌面 host / 老服务端（不带 profiles）或只有一份：开主机那份，不问', () async {
    expect(
      await srsPickRemoteProfile(
        hostDefault: 'ja',
        served: const <SrsRemoteServedProfile>[],
        preferProfile: 'zh',
        chooseProfile: neverAsked,
      ),
      'ja',
    );
    expect(
      await srsPickRemoteProfile(
        hostDefault: 'ja',
        served: const <SrsRemoteServedProfile>[ja],
        preferProfile: 'zh',
        chooseProfile: neverAsked,
      ),
      'ja',
    );
  });

  test('握手回包里的 profiles 解析；坏项跳过', () {
    expect(
      srsServedProfilesOf(<String, dynamic>{
        'profiles': <Object?>[
          <String, Object?>{'uid': 'ja', 'name': 'Japanese', 'notes': 3},
          <String, Object?>{'name': 'no uid'},
          'junk',
        ],
      }).map((SrsRemoteServedProfile p) => (p.uid, p.name, p.notes)),
      <(String, String, int)>[('ja', 'Japanese', 3)],
    );
    expect(srsServedProfilesOf(<String, dynamic>{}), isEmpty);
  });
}
