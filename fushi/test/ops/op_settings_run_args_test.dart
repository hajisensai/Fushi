import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';
import 'package:fushi/src/ops/op_descriptions_settings.dart';
import 'package:fushi/src/ops/op_routes.dart';
import 'package:fushi_cli/fushi_cli.dart';

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ref is not used when building the call');
}

void main() {
  test('settings.run delivers args as body.args, the shape its route reads '
      '(T3 H4)', () {
    final List<CtlRoute> routes = buildOpRoutes(
      OpContext(ref: _UnusedRef(), focusMainWindow: () async {}),
    );
    final OpCatalog catalog = OpCatalog.build(
      routes,
      describeSettingsOps(
        OpDescribeKit(OpContext(ref: _UnusedRef()), routes),
      ).where((OpDescription d) => d.id == 'settings.run'),
    );
    final FushiOp op = catalog['settings.run']!;
    final CtlCall call = OpInvoker(catalog).buildCall(op, <String, Object?>{
      'key': 'media_tracking.cli.search',
      'args': <String, Object?>{'keyword': 'Frieren', 'site': 'anilist'},
    });
    expect(call.body['args'], <String, Object?>{
      'keyword': 'Frieren',
      'site': 'anilist',
    });
    expect(call.body.containsKey('keyword'), isFalse);
  });
}
