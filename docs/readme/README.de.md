<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Immersiver Japanisch-Reader für Android</p>
<p align="center">EPUB · Wörterbuch · Anki · Hörbuch-Synchronisation</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <b>Deutsch</b> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Einführung

**hibiki** ist eine Android-Lese-App für Japanisch-Lernende.

## Funktionen

### EPUB-Leser
- EPUB-Rendering in WebView (Seitenumbruch-Engine abgeleitet von [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- Antippen zum Nachschlagen, Markieren zum Analysieren
- Benutzerdefinierte Schriftarten und Designs (hell/dunkel)
- Lesestatistiken und Lesezeichen
- Zwei Modi: Endlos-Scrollen / Seitenumbruch

### Wörterbuch
- Import von Wörterbüchern im [Yomitan](https://github.com/yomidevs/yomitan)-Format (ehemals Yomichan)
- Unterstützung für Tonhöhenakzent und Häufigkeitsdaten
- Parallele Suche in mehreren Wörterbüchern, Suchverlauf
- Ve-Dekonjugation

### Anki-Karten
- Ein-Tipp-Export nach [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Automatisches Ausfüllen von Kontextsätzen
- Audioaufnahme und Screenshot-Zuschnitt
- Mehrere Exportprofile, benutzerdefinierte Feldzuordnung
- Schnellaktionen (Quick Actions) für Kartenerstellung in einem Schritt

### Hörbuch-Synchronisation (Sasayaki)
- Untertitelformate: SRT / LRC / VTT / ASS
- Automatische Ausrichtung der Untertitel am EPUB-Text
- Mitlese-Hervorhebung, audiosynchrones Seitenwechseln
- Wiedergabesteuerung (Fortschritt, Navigation, Geschwindigkeit)

### Sonstiges
- 17 Oberflächensprachen
- Mehrere Benutzerprofile
- Inkognito-Modus
- Text aus anderen Apps teilen zum direkten Nachschlagen

## Unterstützte Sprachen

Die Oberfläche unterstützt folgende Sprachen:

| Sprache | Code |
|---|---|
| English | `en` |
| 简体中文 | `zh-CN` |
| 繁體中文 | `zh-HK` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español | `es` |
| Français | `fr` |
| Deutsch | `de` |
| Português (Brasil) | `pt-BR` |
| Русский | `ru` |
| Tiếng Việt | `vi` |
| ภาษาไทย | `th` |
| Bahasa Indonesia | `id` |
| Italiano | `it` |
| Nederlands | `nl` |
| Türkçe | `tr` |
| العربية | `ar` |

## Technologie-Stack

| Schicht | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plattform | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptiv) |
| Reader | WebView-Seitenumbruch-Engine (abgeleitet von [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Speicher | Drift (SQLite, WAL) + hoshidicts (C++ FFI Wörterbuch-Engine) |
| NLP | Ve (Dekonjugation) |
| Kartenerstellung | AnkiDroid API |
| Internationalisierung | Slang (17 Sprachen) |
| Mindestversion | Android 7.0 (API 24) |

## Kompilierung

Vorbereitung mit einem Befehl (`flutter pub get` + wendet Patches an), dann kompilieren:

```bash
# im Repository-Root
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # oder (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` bündelt zwei Schritte in einem Befehl: ① `flutter pub get`; ② Ausführung von `ci/apply-patches.sh`. `melos bootstrap` erledigt dasselbe über einen Post-Hook (auf Windows hat melos einen CJK-Encoding-Bug, daher `tool/bootstrap.ps1` verwenden).

> **Patch-Hinweis:** `ci/apply-patches.sh` überschreibt den tatsächlichen Pub Cache mit den Änderungen aus `ci/patches/`. Nach jedem Leeren des Pub Cache oder erneutem `flutter pub get` muss es erneut ausgeführt werden (bootstrap erledigt das bereits). Findet das Skript kein Patch-Ziel, überspringt es und warnt, statt Erfolg vorzutäuschen.

## Abhängigkeiten und Patches

Dieses Projekt ist auf Flutter 3.44.0 festgelegt; einige Upstream-Abhängigkeiten sind noch nicht angepasst. Die Korrekturen laufen über zwei Wege: ① Pakete, die als Build-Eingabe maschinenübergreifend konsistent reproduzierbar sein müssen, werden direkt unter `third_party/` vendort und per `dependency_overrides` referenziert (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **kein** Pub-Cache-Patch nötig); ② die übrigen Pakete werden von `ci/apply-patches.sh` im Pub-Cache-Quellcode gepatcht. Mechanismus-Details siehe [docs/agent/build.md](../agent/build.md). Die folgenden Klapptabellen sind eine nach Änderung gruppierte historische Liste; bei Überschneidung mit Mechanismus ① gilt die vendorte Version.

<details>
<summary><b>Flutter-API-Änderungspatches</b></summary>

| Paket | Änderungen |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; Ersetzung des entfernten `imageCache.putIfAbsent` |
| `flutter_blurhash` 0.7.0 | Ebenso `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Internes Import mit `hide CarouselController` zur Vermeidung von Namenskonflikten |
| `fading_edge_scrollview` 3.0.0 | Nullable-Korrektur für `PageView.controller` |

</details>

<details>
<summary><b>v1-Embedding-Entfernungspatches</b></summary>

Flutter 3.44.0 hat die v1-Embedding-API (`PluginRegistry.Registrar`) vollständig entfernt. Die folgenden Plugins erfordern das Entfernen der entsprechenden Referenzen:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle-/Kotlin-Patches</b></summary>

| Ziel | Änderungen |
|---|---|
| `android/build.gradle` afterEvaluate | Erzwungenes `compileSdk` (Standard 36, einzelne 34) für Unterprojekte; Entfernung von `-Werror` |
| `audio_session` 0.1.14 | Entfernung von `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Kotlin Null-Sicherheitskorrektur |
| `receive_intent` (git) | Kotlin Null-Sicherheitskorrektur |

</details>

<details>
<summary><b>Git-Abhängigkeiten</b></summary>

| Paket | Quelle |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

</details>

## Projektstruktur

```
hibiki/                      # Repository-Root (Melos-Workspace: hibiki_workspace)
├── hibiki/                  # Haupt-Flutter-App-Verzeichnis
│   ├── lib/
│   │   ├── i18n/            # Internationalisierung (17 Sprachen, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Seiten (Bibliothek, Reader, Wörterbuch, Einstellungen usw.)
│   │   │   ├── reader/      # Reader-WebView-JS/CSS-Skripte
│   │   │   ├── media/       # Hörbuch, Untertitel-Analyse, Reader-Source
│   │   │   └── models/      # Datenmodelle und Zustandsverwaltung (AppModel)
│   │   └── main.dart
│   └── android/             # Android-Projekt (Manifest, native hoshidicts)
├── packages/                # Interne Packages + flutter_inappwebview_windows(Fork) + gamepads_android_stub
├── third_party/             # vendorte Patch-Pakete (von dependency_overrides referenziert)
├── ci/                      # Build-Patches und Integrationstest-Skripte
├── tool/                    # bootstrap / i18n_sync u. a. Skripte
└── docs/                    # Entwicklungsdokumentation (inkl. docs/agent/ Agent-Handbuch)
```

## Danksagungen

| Projekt | Beschreibung |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Immersives Japanisch-Lerntool |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android-Japanisch-Reader |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ Wörterbuch-Engine |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS-Japanisch-Reader |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Hörbuch-Synchronisationslösung |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB-Rendering-Engine |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Community-gepflegte ttu-Version (SvelteKit v2), Upstream-Basis des hibiki-Forks |
| [Yomitan](https://github.com/yomidevs/yomitan) | Wörterbuchformat-Quelle |

## Lizenz

[GNU General Public License v3.0](../../LICENSE)
