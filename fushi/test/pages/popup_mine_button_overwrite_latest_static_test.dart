import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// TODO-270 D: tri-state mine button — "overwrite the latest mined card".
//
// After a successful mine that returns a real backend note id (AnkiConnect
// only), the button enters a THIRD "latest editable" state (green ✓ + undo
// glyph). Clicking it OVERWRITES that note in place (updateEntry ->
// repo.updateMinedNote) instead of deleting+recreating. Mining a different word
// supersedes the previous latest. AnkiDroid returns no id -> never enters the
// third state (graceful degrade).
//
// Behaviour coverage (mine -> green ✓↩ -> updateEntry; supersession; no-id
// degrade) lives in fushi/test/utils/misc/popup_asset_behavior_test.js. This
// static guard locks the wiring so the third state cannot silently regress to
// the old two-state behaviour, WITHOUT breaking the TODO-084/087 guards
// (popup_mine_button_anki_truth_static_test.dart), which still require the
// `data-mined === '1'` re-verify-before-mine branch.
void main() {
  late String source;
  late String onclickBody;

  setUpAll(() {
    source = File('assets/popup/popup.js').readAsStringSync();
    // Anchor on the mine button itself: `onclick: async () => {` appears on
    // several earlier buttons, so a bare first-occurrence search swallows
    // unrelated handlers into `onclickBody` and makes the ordering assertions
    // below read the wrong text.
    final int mineButtonIdx = source.indexOf("const mineButton = el('button'");
    expect(mineButtonIdx, greaterThanOrEqualTo(0),
        reason: 'mine button construction not found');
    final int onclickIdx =
        source.indexOf('onclick: async () => {', mineButtonIdx);
    expect(onclickIdx, greaterThanOrEqualTo(0),
        reason: 'mine button onclick handler not found');
    final int end = source.indexOf('buttonsContainer.appendChild(mineButton)');
    expect(end, greaterThan(onclickIdx));
    onclickBody = source.substring(onclickIdx, end);
  });

  test('a separate updateEntry path overwrites an existing note by id', () {
    // The JS layer must expose an updateEntry() that posts to the Dart
    // `updateEntry` handler carrying the note id + freshly-built fields.
    expect(source.contains('async function updateEntry('), isTrue,
        reason: 'an updateEntry() function must exist for the overwrite path');
    expect(source.contains("callHandler('updateEntry', { noteId, fields })"),
        isTrue,
        reason: 'updateEntry must call the Dart updateEntry handler with '
            'the note id + fields');
  });

  test('the latest-editable branch runs updateEntry, not a second mineEntry',
      () {
    final int latestIdx = onclickBody.indexOf("dataset.latest === '1'");
    expect(latestIdx, greaterThanOrEqualTo(0),
        reason: 'onclick must branch on the latest-editable sub-state');
    final int updateIdx = onclickBody.indexOf('updateEntry(', latestIdx);
    expect(updateIdx, greaterThan(latestIdx),
        reason: 'the latest-editable branch must overwrite via updateEntry');
    // The latest branch must come BEFORE the data-mined re-verify branch so a
    // green ✓↩ overwrites in place rather than falling into the re-mine path.
    // Match the re-verify BRANCH, not any read of `dataset.mined`: BUG-2242's
    // queued early-return reads the same dataset flag earlier in the handler
    // (`setMineState(mineButton.dataset.mined === '1')`), which is not a branch
    // on it at all.
    final int minedIdx =
        onclickBody.indexOf("if (mineButton.dataset.mined === '1') {");
    expect(minedIdx, greaterThanOrEqualTo(0),
        reason: 'onclick must keep the ordinary mined re-verify branch');
    expect(minedIdx, greaterThan(latestIdx),
        reason: 'the latest-editable branch must be checked before the '
            'ordinary mined re-verify branch');
  });

  test('the editable latest is gated on a real backend note id', () {
    // Only a backend that returns a note id (AnkiConnect) becomes the editable
    // latest; AnkiDroid (no id) must degrade to an ordinary ✓.
    expect(source.contains('function rememberLatestMined('), isTrue,
        reason: 'a helper must record the latest-mined note id');
    expect(source.contains('function isLatestEditable('), isTrue,
        reason: 'a helper must decide whether a word is the editable latest');
    // setMineState gates the green state on isLatestEditable, not just on mined.
    final int setStateIdx = source.indexOf('const setMineState =');
    expect(setStateIdx, greaterThanOrEqualTo(0));
    final int setStateEnd = source.indexOf('const mineButton =', setStateIdx);
    final String setStateBody = source.substring(setStateIdx, setStateEnd);
    expect(setStateBody.contains('isLatestEditable('), isTrue,
        reason: 'the green latest state must require a held note id');
    expect(setStateBody.contains('dataset.latest ='), isTrue,
        reason: 'setMineState must record the latest sub-state on the button');
  });

  test('a successful mine with a note id supersedes any prior latest', () {
    // The normal mine success path (ankiConnect) records the new latest, which
    // supersedes the previous one (rememberLatestMined overwrites the held id).
    expect(onclickBody.contains('rememberLatestMined('), isTrue,
        reason: 'a successful mine must (re)record the latest-editable card');
  });
}
