import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hibiki/src/utils/misc/log_uploader.dart';
import 'package:hibiki/i18n/strings.g.dart';

void main() {
  // 用一个按钮触发 ensureLogUploadConsent，记录返回值，便于断言三条路径。
  Future<bool?> pumpAndInvoke(WidgetTester tester) async {
    bool? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () async {
                  result = await ensureLogUploadConsent(context);
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets('首次：弹同意框，点同意 → true 且持久化', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await pumpAndInvoke(tester);
    // 对话框出现
    expect(find.text(t.log_upload_consent_title), findsOneWidget);
    // 点「同意并上传」
    await tester.tap(find.text(t.log_upload_consent_agree));
    await tester.pumpAndSettle();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kLogUploadConsentKey), isTrue);
  });

  testWidgets('首次：点取消 → false 且不持久化', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    bool? result;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () async {
                  result = await ensureLogUploadConsent(context);
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.cancel));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(kLogUploadConsentKey), isNull);
  });

  testWidgets('已记住同意 → 直接 true，不弹框', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kLogUploadConsentKey: true,
    });
    final bool? result = await pumpAndInvoke(tester);
    expect(result, isTrue);
    expect(find.text(t.log_upload_consent_title), findsNothing);
  });
}
