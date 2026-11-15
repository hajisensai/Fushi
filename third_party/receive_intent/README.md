
# receive_intent

<p>
<!-- ALL-CONTRIBUTORS-BADGE:START - Do not remove or modify this section -->
<a href="#contributors-"><img src="https://img.shields.io/badge/all_contributors-5-orange.svg" alt="All Contributors" /></a>
<!-- ALL-CONTRIBUTORS-BADGE:END -->
<a href="https://pub.dev/packages/receive_intent"><img src="https://img.shields.io/pub/v/receive_intent?logo=dart" alt="pub.dev"></a>
<a href="https://github.com/daadu/receive_intent/actions?query=workflow%3Aanalysis"><img src="https://github.com/daadu/receive_intent/workflows/analysis/badge.svg" alt="analysis"></a>
<a href="https://pub.dev/packages/receive_intent/score"><img src="https://img.shields.io/pub/points/receive_intent?logo=dart" alt="pub points"></a>
<a href="https://pub.dev/packages/receive_intent/score"><img src="https://img.shields.io/pub/popularity/receive_intent?logo=dart" alt="popularity"></a>
<a href="https://pub.dev/packages/receive_intent/score"><img src="https://img.shields.io/pub/likes/receive_intent?logo=dart" alt="likes"></a>
<a href="https://github.com/daadu/receive_intent/issues"><img src="https://img.shields.io/github/issues/daadu/receive_intent?logo=github" alt="GitHub issues"></a>
<a href="https://github.com/daadu/receive_intent/milestone/1"><img src="https://img.shields.io/github/milestones/progress-percent/daadu/receive_intent/1?logo=github" alt="GitHub milestone"></a>
<a href="https://github.com/daadu/receive_intent/stargazers"><img src="https://img.shields.io/github/stars/daadu/receive_intent?logo=github" alt="GitHub stars"></a>
<a href="https://github.com/daadu/receive_intent/network"><img src="https://img.shields.io/github/forks/daadu/receive_intent?logo=github" alt="GitHub forks"></a>
</p>

A Flutter plugin to pass Android Intents to the Flutter environment.

`Intent` in Android is the "payload" for the communication between and within apps. This plugin passes the `Intent`, that "started"  the `Activity` to the flutter environment. It also passes any "new Intents" that are received (via [`Activity.onNewIntent`](https://developer.android.com/reference/android/app/Activity#onNewIntent(android.content.Intent))) while the `Activity` is already "started".

If the `Intent` was "started" via `startActivityForResult`, then this plugin also sends additional information (package name and app signature) about the "calling" Android Component, and can send "result" back (via [`Activity.setResult`](https://developer.android.com/reference/android/app/Activity#setResult(int))) to it.

This plugin is in active development.
___Any contribution, idea, criticism or feedback is welcomed.___

## Quick links
| | |
|-|-|
| __package__ | https://pub.dev/packages/receive_intent |
| __Git Repo__  | https://github.com/daadu/receive_intent |
| __Issue Tracker__ | https://github.com/daadu/receive_intent/issues |


## Use cases
- [OAuth based App Flip](https://developers.google.com/identity/account-linking/app-flip-overview) - This was the initial motivation for this plugin. The plugin can be used to pass the `Intent` sent by Google App to the flutter environment - where the consent UI is shown - once it is authorized (or not), the result is sent back to the Google App.
- Deeplink/Applink - This plugin is a generic implementation of [uni_links](https://pub.dev/packages/uni_links) plugin. While this plugin passes "any" Intents, `uni_links` only passes app-link/deep-link Intents.
- Receive Share Intents - This plugin is a generic implementation of [receive_sharing_intent](https://pub.dev/packages/receive_sharing_intent) plugin. While this plugin passes "any" Intents, `receive_sharing_intent` only passes "android.intent.action.SEND" (or related) Intents.
- In general, if you want other apps to "start" your app, then this plugin can pass the `Intent` that "triggered" it to the flutter environment of the app. These `Intent` will give the app understanding of why the app was started. Check [Getting started](#getting-started) section to implement this.

## Getting started
#### Add `<intent-filter>` to `AndroidMainfest.xml`
You need to add `<intent-filter>` to `android/app/src/main/AndroidManifest.xml` file:
```xml
<manifest ...>
  <!-- ... other tags -->
  <application ...>
    <activity ...>
      <!-- ... other tags -->

      <!-- Describe Intent your app can receive with <intent-filter>  -->
      <intent-filter>
        <action android:name="RECEIVE_INTENT_EXAMPLE_ACTION" />
        <category android:name="android.intent.category.DEFAULT"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
```
In this example we want to receive Intent with `action` matching `RECEIVE_INTENT_EXAMPLE_ACTION` literal. This `<intent-filter>` should be added to the `Activity` that extends `FlutterActivity` (for project generated from template it is `MainActivity`).

`<intent-filter>` describes, what `Intent` the `Activity` is capable to recevie. To read more about "Intent and Intent Filter", encourage you to check [official docs](https://developer.android.com/guide/components/intents-filters) from Android.
#### Recevie and handle Intent that launched the Activity in Flutter
Inside flutter code, you can call `ReceiveIntent.getInitialIntent()` to get the `Intent` that started the `Activity`:
```dart
import 'package:receive_intent/receive_intent.dart';
// ...

  Future<void> _initReceiveIntent() async {
    // Platform messages may fail, so we use a try/catch PlatformException.
    try {
      final receivedIntent = await ReceiveIntent.getInitialIntent();
      // Validate receivedIntent and warn the user, if it is not correct,
      // but keep in mind it could be `null` or "empty"(`receivedIntent.isNull`).
    } on PlatformException {
      // Handle exception
    }
  }

// ...
```
#### Listen for any new Intent while the Activity is already running
To listen to new `Intent` while the `Activity` is running, you can use the `ReceiveIntent.receivedIntentStream` stream:
```dart
import 'package:receive_intent/receive_intent.dart';
// ...
  StreamSubscription _sub;

  Future<void> _initReceiveIntentit() async {
    // ... check initialIntent

    // Attach a listener to the stream
    _sub = ReceiveIntent.receivedIntentStream.listen((Intent? intent) {
      // Validate receivedIntent and warn the user, if it is not correct,
    }, onError: (err) {
      // Handle exception
    });

    // NOTE: Don't forget to call _sub.cancel() in dispose()
  }
// ...
```
#### Send result to the calling Activity (Optional)
If the calling `Activty` has "started" this activity with `startActivityWithResult` then you can send back result to that activity when ready with `ReceiveIntent.setResult`:
```dart
import 'package:receive_intent/receive_intent.dart';
// ...

  Future<void> _setActivityResult() async {
    // ...
    await ReceiveIntent.setResult(kActivityResultOk, data: {"sum": 123})
  }
// ...
```
To read more about "Starting Activities and Getting Results" pattern, encourage you to check [official docs](https://developer.android.com/reference/android/app/Activity#starting-activities-and-getting-results) from Android.

Additionaly, in the case of activity started with `startActivityWithResult`, the `Intent` object will also have package name (`intent.fromPackageName`) and app signautres (`intent.fromSignatures`) of the calling activity. This could be used to validate the calling app, so that sensitive information is not given to unintendent apps.
#### Tools to test it
You can test this with either [`adb`](https://developer.android.com/studio/command-line/adb) or [Intent Test](https://play.google.com/store/apps/details?id=com.applauncher.applauncher) app form Playstore.
##### adb
To invoke (start) our `FlutterAcitivity` with `RECEIVE_INTENT_EXAMPLE_ACTION`  intent action name as mentioned in example `<intent-filter>` [above](#add-intent-filter-to-AndroidMainfest.xml):
```sh
adb shell 'am start -W -a RECEIVE_INTENT_EXAMPLE_ACTION -c android.intent.category.DEFAULT'
```
If you don't have  [`adb`](https://developer.android.com/studio/command-line/adb)  in your path, but have  `$ANDROID_HOME`  env variable then use  `"$ANDROID_HOME"/platform-tools/adb ...`.

Note: Alternatively you could simply enter an  `adb shell`  and run the  [`am`](https://developer.android.com/studio/command-line/adb#am)  commands in it.

#### Check example app
To know more or to get the working code check the [example app](https://github.com/daadu/receive_intent/tree/master/example).

## Todo
- Document API references properly
- Receive Intent for non-`Activity` based `intent-filter` (`BroadcastReceiver`, `Service`)
- Automatic testing

## Contribute
Check the [Todo](#todo) section above, before you begin with any contribution.

1. You'll need a GitHub account.
2. Fork the [repository](https://github.com/daadu/receive_intent).
3. Pick an issue to work on from [issue tracker](https://github.com/daadu/receive_intent/issues).
4. Implement it.
5. Add your name and email in `authors` section in `pubspec.yaml` file.
6. Send merge request.
7. Star this project.
8. Become a hero!!

## Features and bugs
Please file feature requests and bugs at the [issue tracker](https://github.com/daadu/receive_intent/issues).

## Contributors ✨

Thanks goes to these wonderful people ([emoji key](https://allcontributors.org/docs/en/emoji-key)):

<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->
<table>
  <tr>
    <td align="center"><a href="https://bhikadia.com/"><img src="https://avatars.githubusercontent.com/u/4963236?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Harsh Bhikadia</b></sub></a><br /><a href="#ideas-daadu" title="Ideas, Planning, & Feedback">🤔</a> <a href="https://github.com/daadu/receive_intent/commits?author=daadu" title="Code">💻</a></td>
    <td align="center"><a href="https://the.lastgimbus.com/"><img src="https://avatars.githubusercontent.com/u/40139196?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Mateusz Soszyński</b></sub></a><br /><a href="https://github.com/daadu/receive_intent/commits?author=TheLastGimbus" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/luckyrat"><img src="https://avatars.githubusercontent.com/u/1211375?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Chris Tomlinson</b></sub></a><br /><a href="https://github.com/daadu/receive_intent/commits?author=luckyrat" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/eric-nextsense"><img src="https://avatars.githubusercontent.com/u/78733538?v=4?s=100" width="100px;" alt=""/><br /><sub><b>eric-nextsense</b></sub></a><br /><a href="https://github.com/daadu/receive_intent/issues?q=author%3Aeric-nextsense" title="Bug reports">🐛</a> <a href="https://github.com/daadu/receive_intent/commits?author=eric-nextsense" title="Code">💻</a></td>
    <td align="center"><a href="https://github.com/tneotia"><img src="https://avatars.githubusercontent.com/u/50850142?v=4?s=100" width="100px;" alt=""/><br /><sub><b>Tanay Neotia</b></sub></a><br /><a href="https://github.com/daadu/receive_intent/issues?q=author%3Atneotia" title="Bug reports">🐛</a> <a href="https://github.com/daadu/receive_intent/commits?author=tneotia" title="Code">💻</a></td>
  </tr>
</table>

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->

This project follows the [all-contributors](https://github.com/all-contributors/all-contributors) specification. Contributions of any kind welcome!
