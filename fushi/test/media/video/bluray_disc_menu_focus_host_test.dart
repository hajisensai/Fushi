import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/media/video/bluray_disc_menu_focus_host.dart';

void main() {
  testWidgets('menu replacement reclaims after old focused controls detach', (
    WidgetTester tester,
  ) async {
    final FocusNode video = FocusNode(debugLabel: 'video');
    final FocusNode toolbar = FocusNode(debugLabel: 'old-toolbar');
    final FocusNode menuButton = FocusNode(debugLabel: 'menu-toolbar');
    final ValueNotifier<bool> menu = ValueNotifier<bool>(false);
    final PageFocusOwnership owner = PageFocusOwnership(
      node: video,
      canOwn: (_) => true,
    );
    int selections = 0;
    int attachments = 0;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      video.dispose();
      toolbar.dispose();
      menuButton.dispose();
      menu.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Focus(
            canRequestFocus: false,
            onKeyEvent: (_, KeyEvent event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.enter) {
                selections++;
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: ValueListenableBuilder<bool>(
              valueListenable: menu,
              builder: (BuildContext context, bool shown, _) => shown
                  ? BlurayDiscMenuFocusHost(
                      focusNode: video,
                      onAttached: (BuildContext context) {
                        attachments++;
                        if (ModalRoute.of(context)?.isCurrent == true) {
                          owner.reclaim(FocusReclaimCause.contentReady);
                        }
                      },
                      child: TextButton(
                        focusNode: menuButton,
                        onPressed: () {},
                        child: const Text('Back'),
                      ),
                    )
                  : Focus(
                      focusNode: video,
                      child: TextButton(
                        focusNode: toolbar,
                        onPressed: () {},
                        child: const Text('Top'),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
    toolbar.requestFocus();
    await tester.pump();
    expect(toolbar.hasPrimaryFocus, isTrue);
    menu.value = true;
    await tester.pump();
    await tester.pump();
    expect(video.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(selections, 1);
    expect(attachments, 1);
    // Subsequent frames must not take focus back from a deliberately chosen
    // app toolbar button; only a new host attachment reclaims it.
    menuButton.requestFocus();
    await tester.pump();
    expect(menuButton.hasPrimaryFocus, isTrue);
    expect(attachments, 1);
  });

  testWidgets('menu attachment behind a dialog leaves modal keyboard ownership', (
    WidgetTester tester,
  ) async {
    final FocusNode video = FocusNode();
    final FocusNode dialogButton = FocusNode();
    final ValueNotifier<bool> menu = ValueNotifier<bool>(false);
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    int claimed = 0;
    final PageFocusOwnership owner = PageFocusOwnership(
      node: video,
      canOwn: (_) => true,
    );
    addTearDown(() {
      video.dispose();
      dialogButton.dispose();
      menu.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: ValueListenableBuilder<bool>(
            valueListenable: menu,
            builder: (BuildContext context, bool shown, _) => shown
                ? BlurayDiscMenuFocusHost(
                    focusNode: video,
                    onAttached: (BuildContext host) {
                      if (ModalRoute.of(host)?.isCurrent == true) {
                        claimed++;
                        owner.reclaim(FocusReclaimCause.contentReady);
                      }
                    },
                    child: const Text('Disc'),
                  )
                : Focus(focusNode: video, child: const Text('Movie')),
          ),
        ),
      ),
    );
    unawaited(
      showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => AlertDialog(
          actions: <Widget>[
            TextButton(
              focusNode: dialogButton,
              autofocus: true,
              onPressed: () {},
              child: const Text('Keep dialog'),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      dialogButton.hasPrimaryFocus,
      isTrue,
      reason:
          'Dialog must own keyboard focus before replacing the background host',
    );
    menu.value = true;
    await tester.pump();
    await tester.pump();
    expect(dialogButton.hasPrimaryFocus, isTrue);
    expect(claimed, 0);
  });
}
