import 'package:fushi/src/mining/tyrano_dom/tyrano_dom_launch.dart';
import 'package:test/test.dart';

void main() {
  test('tyranoDomRemoteDebuggingArgs', () {
    expect(tyranoDomRemoteDebuggingArgs(9333), <String>[
      '--remote-debugging-port=9333',
    ]);
  });

  test('parseRemoteDebuggingPort 认 = 形式与分开两项，0 / 非法视为没给', () {
    expect(
      parseRemoteDebuggingPort(<String>['--remote-debugging-port=9222']),
      9222,
    );
    expect(
      parseRemoteDebuggingPort(<String>[
        '-x',
        '--remote-debugging-port',
        '9223',
      ]),
      9223,
    );
    expect(
      parseRemoteDebuggingPort(<String>['--remote-debugging-port=0']),
      isNull,
    );
    expect(
      parseRemoteDebuggingPort(<String>['--remote-debugging-port=abc']),
      isNull,
    );
    expect(parseRemoteDebuggingPort(<String>['--other']), isNull);
  });

  test('planTyranoDomLaunch：非 Tyrano 返回 null', () async {
    expect(
      await planTyranoDomLaunch(
        r'C:\g\a.exe',
        isTyranoGame: (String _) => false,
        pickPort: () async => 1234,
      ),
      isNull,
    );
  });

  test('planTyranoDomLaunch：取空闲端口并追加参数', () async {
    final TyranoDomLaunchPlan? plan = await planTyranoDomLaunch(
      r'C:\g\a.exe',
      isTyranoGame: (String _) => true,
      pickPort: () async => 41234,
    );
    expect(plan!.port, 41234);
    expect(plan.extraArgs, <String>['--remote-debugging-port=41234']);
  });

  test('planTyranoDomLaunch：用户参数已带端口则沿用、不追加', () async {
    final TyranoDomLaunchPlan? plan = await planTyranoDomLaunch(
      r'C:\g\a.exe',
      userArgs: <String>['--remote-debugging-port=9333'],
      isTyranoGame: (String _) => true,
      pickPort: () async => fail('should not pick a port'),
    );
    expect(plan!.port, 9333);
    expect(plan.extraArgs, isEmpty);
  });

  test('planTyranoDomLaunch：默认取到的是真实可用端口', () async {
    final TyranoDomLaunchPlan? plan = await planTyranoDomLaunch(
      r'C:\g\a.exe',
      isTyranoGame: (String _) => true,
    );
    expect(plan!.port, inInclusiveRange(1, 65535));
  });
}
