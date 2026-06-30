<div align="center">

# hibiki

<img src="../static-assets/hibiki-logo.png" alt="hibiki-Logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | **Deutsch** | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[Benutzerhandbuch](../user-guide.de.md) | [Neueste Version herunterladen](https://github.com/hajisensai/hibiki/releases)

hibiki ist ein immersives Sprachlernwerkzeug für Android und Windows, das EPUB-Lesen, Hörbuch-Synchronisation, das Nachschlagen von Wörtern in Videountertiteln und das Erstellen von Anki-Karten mit einem Tipp vereint — so wird jeder Input ganz natürlich zu wiederholbarem Vokabular.

<table>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-bookshelf-en.png" alt="Bücherregal" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-library-en.png" alt="Videobibliothek" width="100%"></td>
  </tr>
  <tr>
    <td colspan="2"><img src="../static-assets/screenshots/hibiki-readme-reader-vertical-lookup.png" alt="Vertikales Lesen am Desktop mit Nachschlage-Popup" width="100%"></td>
  </tr>
  <tr>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-nested.png" alt="Nachschlagen im Video (verschachtelte Popups)" width="100%"></td>
    <td><img src="../static-assets/screenshots/hibiki-readme-video-lookup-subtitle.png" alt="Nachschlagen im Video (Untertitelliste)" width="100%"></td>
  </tr>
</table>

</div>

## Funktionen

### Bücherregal

- EPUBs einzeln, im Stapel oder rekursiv per Ordner importieren; den Lesefortschritt direkt im Regal sehen.
- Bücher mit eigenen Bücherregalen, Tag-Filtern und Ziehen zum Neuanordnen organisieren.
- Dateien per Drag-and-drop importieren — Bücher, Untertitel oder Videos (Desktop).
- Beim Import automatisch namensgleiche Untertitel-/Audiodateien zuordnen.

### Lesen

- Im vertikalen oder horizontalen Layout lesen; zwischen seitenweisem und fortlaufendem Scroll-Modus wechseln.
- Themes (hell / dunkel / reines Schwarz / benutzerdefiniert), Schriften, Absatzabstand und Reader-Steuerung anpassen.
- Furigana (ふりがな)-Annotationen.
- Anpassbare UI-Skalierung; die Steuerelemente der unteren Leiste folgen der Skalierung.
- Mehrbenutzer-Profile (Profile), pro Buch automatisch umgeschaltet.

### Nachschlagen

- [Yomitan](https://github.com/yomidevs/yomitan) (früher Yomichan), ABBYY Lingvo (DSL), MDict (MDX) und Migaku-Wörterbücher importieren.
- Im Reader auf Text tippen, um Wörter nachzuschlagen, auf der Wörterbuchseite suchen oder Text aus anderen Apps teilen.
- Deflexion für **alle Yomitan-Transformationssprachen** + Textnormalisierung vor dem Nachschlagen (Groß-/Kleinschreibung / diakritische Zeichen / arabische Harakat), Code-Point-gesteuert ohne Sprachwechsel.
- Auf Wörter innerhalb von Definitionen tippen für rekursives Nachschlagen (verschachtelte Popups).
- Parallele Abfragen über mehrere Wörterbücher, Priorität und Umschalten von Unterquellen, Tonhöhenakzent- und Häufigkeitsannotationen.
- Online- und lokales Wort-Audio.
- Eigenes CSS einspeisen.

### Markierungen & Statistiken

- Beim Lesen fünffarbige Markierungen hinzufügen; jederzeit zu jeder Markierung springen.
- Lesestatistiken: gelesene Zeichen, Dauer, Lesegeschwindigkeit — in Echtzeit während des Lesens angezeigt.
- Videostatistiken: Sehdauer, erstellte Karten und Favoriten.

### Anki-Kartenerstellung

- Karten über [AnkiDroid](https://github.com/ankidroid/Anki-Android) oder AnkiConnect erstellen.
- Eingebauter [Lapis](https://github.com/donkuri/lapis)-Notiztyp (mitgeliefert 1.7.0); Kartenvorlagen und Stapel mit einem Tipp direkt in der App anlegen.
- Kontextsätze automatisch ausfüllen; Audioaufnahme und Screenshot-Zuschnitt.
- Mehrere Export-Profile (Profile) und benutzerdefiniertes Feld-Mapping.
- Wörter als Favoriten markieren; erstellte Karten und Favoriten fließen in die Statistik ein.

### Hörbuch-Synchronisation (Sasayaki)

- Unterstützung für SRT-/LRC-/VTT-/ASS-Untertitel; richtet den Untertiteltext automatisch am EPUB-Text aus.
- Mitlaufendes Satz-Highlighting und automatisches Umblättern während der Wiedergabe.
- Wiedergabegeschwindigkeit, Spulaktionen und System-Mediensteuerung.
- „Ab diesem Satz abspielen“ mit nahtloser kapitelübergreifender Fortsetzung.

### Nachschlagen in Videountertiteln

- Eingebauter Videoplayer auf Basis von [media_kit](https://github.com/media-kit/media-kit) (libmpv-Kern).
- Eingebettete (Text- + Grafikspuren) und externe Untertitel; Import von .m3u8-Wiedergabelisten.
- Während der Wiedergabe Wörter direkt aus den Untertiteln nachschlagen und Karten erstellen.
- Verwaltung der Videobibliothek, Tag-Filter, Serien-Gruppierung und Stapeloperationen.

### Datensynchronisation

- Sieben Sync-Backends: Google Drive, OneDrive, Dropbox, WebDAV, FTP, SFTP und Hibiki P2P.
- Lesefortschritt, Statistiken und Bücher synchronisieren.

### Mehr

- **17 Oberflächensprachen**, vollständig auf allen Plattformen lokalisiert.
- Text aus anderen Apps teilen, um Wörter direkt nachzuschlagen.

## Plattform-Unterstützung

| Plattform | Status | Rendering / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material |

> Mindestens Android 7.0 (API 24). Welche Sprachen zum Nachschlagen verfügbar sind, hängt von den importierten Wörterbüchern und den Yomitan-Transformationstabellen ab — unabhängig von der Oberflächensprache.

### Oberflächensprachen (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installation & Build

Vorbereitung mit einem Befehl (`flutter pub get` + Patches anwenden), dann bauen:

```bash
# Vom Repository-Stammverzeichnis aus
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd hibiki
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Windows-Desktop
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` fassen `flutter pub get` und `ci/apply-patches.sh` zu einem einzigen Befehl zusammen. Dieses Projekt ist auf Flutter 3.44.0 festgelegt (Dart SDK `>=3.5.0 <4.0.0`); einige Upstream-Abhängigkeiten sind unter `third_party/` mitgeliefert oder werden durch `ci/apply-patches.sh` gepatcht — Details siehe [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Technologie-Stack</b></summary>

| Schicht | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plattformen | Android / Windows (Material Design 3) |
| Reader | WebView-Seitenmaschine (abgeleitet von der Hoshi-Reader-Familie) |
| Video | media_kit (libmpv-Kern) |
| Speicher | Drift (SQLite, WAL) + hoshidicts (C++-FFI-Wörterbuch-Engine) |
| NLP | Yomitan-Transformationstabellen (mehrsprachige Lemmatisierung) + kana_kit (Kana-Konvertierung); Tokenisierung über hoshidicts-FFI |
| Kartenerstellung | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 Sprachen) |

</details>

<details>
<summary><b>Projektstruktur</b></summary>

```
hibiki/                      # Repository-Stammverzeichnis (Melos-Workspace: hibiki_workspace)
├── hibiki/                  # Hauptverzeichnis der Flutter-App
│   ├── lib/
│   │   ├── i18n/            # Internationalisierung (17 Sprachen, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Seiten (Bücherregal, Reader, Wörterbuch, Einstellungen usw.)
│   │   │   ├── reader/      # Reader-WebView-JS-/CSS-Skripte
│   │   │   ├── media/       # Hörbuch, Untertitel-Parsing, Reader-Quelle
│   │   │   └── models/      # Datenmodelle und Zustandsverwaltung (AppModel)
│   │   └── main.dart
│   └── android/             # Android-Projekt (Manifest, natives hoshidicts)
├── packages/                # Interne Pakete + flutter_inappwebview_windows (Fork) + gamepads_android_stub
├── native/                  # hoshidicts C++-Wörterbuch-Engine (FFI)
├── third_party/             # Mitgelieferte gepatchte Pakete (dependency_overrides)
├── ci/                      # Build-Patches und Integrationstest-Skripte
├── tool/                    # bootstrap / i18n_sync und weitere Skripte
└── docs/                    # Entwicklungsdokumentation (inkl. docs/agent/ Betriebshandbuch)
```

</details>

## Datenschutz & Daten

hibiki speichert importierte Bücher, Wörterbücher, Schriften, Hörbuchdaten, Videos, Lesefortschritt, Markierungen, Statistiken und Einstellungen im lokalen Speicher der App.

Cloud-Sync (Google Drive / OneDrive / Dropbox) verwendet vom Benutzer konfigurierte OAuth-Anmeldedaten; WebDAV / FTP / SFTP verwendet vom Benutzer angegebene Serveradressen und Anmeldedaten; Hibiki P2P verbindet sich direkt über eine vom Benutzer konfigurierte Adresse. Die Anki-Kartenerstellung kommuniziert mit AnkiDroid oder einer konfigurierten AnkiConnect-Adresse.

## Danksagungen

hibiki baut auf den folgenden Projekten und dem folgenden Ökosystem auf:

| Projekt | Beschreibung |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanisches immersives Lernwerkzeug |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS-Japanisch-Reader; Referenz für die Reader-Seitenmaschine |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Nativer japanischer Reader für Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++-Wörterbuch-Engine |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Lösung für die Hörbuch-Synchronisation |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referenz für Wörterbuchformat, Transformationstabellen und Nachschlage-Erlebnis |
| [Lapis](https://github.com/donkuri/lapis) | Anki-Notiztyp |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android-Kartenerstellungs-Integration |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referenz für lokales Audio und AnkiDroid-Interaktion |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referenz für Reader, Statistiken und Sync-Kompatibilität |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter-Videowiedergabe-Framework (libmpv-Kern) |

## Lizenz

Vertrieben unter der GNU General Public License v3.0. Details siehe [LICENSE](../../LICENSE).

<div align="center">

<br>

[简体中文](../../README.md) | [English](README.en.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | **Deutsch** | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
