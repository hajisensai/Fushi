<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="fushi-Logo" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | **Deutsch** | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Neueste Version herunterladen](https://img.shields.io/badge/%E2%AC%87%20Neueste%20Version%20herunterladen-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Discord beitreten](https://img.shields.io/badge/Discord%20beitreten-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Plattform-Unterstützung

| Plattform | Status | Hinweise |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) oder neuer |
| Windows | ✅ | Das Hooking von Galgame-Text und -Sprache gibt es nur unter Windows |
| macOS | ✅ | Nur Apple Silicon; Intel-Macs werden nicht unterstützt |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | Keine Entdeckung, Online-Quellen oder Download-Center (App-Store-Richtlinien) |
| Linux | 🔧 Aus dem Quellcode bauen | Noch kein vorkompiliertes Release; der EPUB-Reader benötigt WPE WebKit |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | Headless-Host für Linux / Windows / macOS mit Web-Oberfläche — siehe [packages/fushi_server](../../packages/fushi_server/README.md) |

**Designsystem** — auf allen Plattformen ist **Material 3 Expressive** voreingestellt; ein **Cupertino**-Designsystem (Apple-Stil) lässt sich unter *Einstellungen › Erscheinungsbild › Designsystem* auswählen; mit Cupertino nutzt der Fensterhintergrund Mica unter Windows 11 und Vibrancy unter macOS (sofern nicht die Systemeinstellung „Transparenz reduzieren“ oder „Hoher Kontrast“ aktiv ist).

> Welche Sprachen zum Nachschlagen verfügbar sind, hängt von den importierten Wörterbüchern und den Yomitan-Transformationstabellen ab — unabhängig von der Oberflächensprache. iOS-Updates kommen über TestFlight einige Tage später als auf den anderen Plattformen.

### Oberflächensprachen (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installation

Lade die neueste Version von der [Fushi-Website](https://fushi.moe/) herunter — verfügbar sind das Android-APK, das Windows-Installationsprogramm und macOS-Builds (nur Apple Silicon; Intel-Macs werden nicht unterstützt); iOS wird über [TestFlight](https://testflight.apple.com/join/j88d69jx) installiert. Für Linux gibt es noch kein vorkompiliertes App-Release; baue es aus dem Quellcode. Der Headless-Server Fushi Server wird separat auf [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases) veröffentlicht.

> Erfordert Android 7.0 (API 24) oder höher.

## Build

Vorbereitung mit einem Befehl (`flutter pub get` + Patches anwenden), dann bauen:

```bash
# Vom Repository-Stammverzeichnis aus
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Desktop
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# Headless-Server (aus packages/fushi_server; `dart build cli` verwenden, nicht `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` fassen `flutter pub get` und `ci/apply-patches.sh` zu einem einzigen Befehl zusammen. Dieses Projekt ist auf Flutter 3.47.6 festgelegt (Dart SDK `>=3.8.0 <4.0.0`); frühere Flutter-Versionen können es nicht bauen, da Material und Cupertino als die Pakete `material_ui` / `cupertino_ui` eingebunden werden. Einige Upstream-Abhängigkeiten sind unter `third_party/` mitgeliefert oder werden von `ci/apply-patches.sh` gepatcht — Details, einschließlich der Build-Abhängigkeiten für den Linux-Desktop, siehe [docs/agent/build.md](../agent/build.md).

<details>
<summary><b>Technologie-Stack</b></summary>

| Schicht | Technologie |
|---|---|
| Framework | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| Plattformen | Android / Windows / macOS / iOS / Linux sowie ein Headless-Server |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| Reader | WebView-Paginierungs-Engine (abgeleitet von der Hoshi-Reader-Familie) |
| Video | media_kit (libmpv core) + libplacebo |
| Speicher | Drift (SQLite, WAL) + fushidicts (C++-FFI-Wörterbuch-Engine) |
| NLP | Yomitan-Transformationstabellen (mehrsprachige Lemmatisierung) + kana_kit (Kana-Konvertierung); Tokenisierung über fushidicts FFI |
| KI auf dem Gerät | ONNX Runtime für Spracherkennung (Untertitelerzeugung) und Manga-OCR; die Algorithmen liegen in [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| Downloads | libtorrent 2.x über eine C-ABI-FFI-Brücke (externes qBittorrent als Fallback) |
| Sync | Cloud-Backends + Fushi Interconnect (LAN, Remote-Adressen und ein iroh-P2P-Tunnel) |
| Gemeinsame Engine | `fushi_engine` — reiner Dart-Kern, den die App und Fushi Server gemeinsam nutzen |
| Kartenerstellung | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 Sprachen) |

</details>

<details>
<summary><b>Projektstruktur</b></summary>

```
Fushi/                      # Repository-Stammverzeichnis (Melos-Workspace: fushi_workspace)
├── fushi/                  # Hauptverzeichnis der Flutter-App
│   ├── lib/
│   │   ├── i18n/            # Internationalisierung (17 Sprachen, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Seiten (Bibliotheksseiten, Reader, Videoplayer, Einstellungen usw.)
│   │   │   ├── reader/      # Reader-WebView-JS-/CSS-Skripte
│   │   │   ├── media/       # Bücher, Manga, Video, Hörbücher, Online-Quellen
│   │   │   ├── lookup/      # Wörterbuch-Nachschlage-Popups und -Overlays
│   │   │   ├── mining/      # Kartenerstellung (inkl. Galgame-Mining)
│   │   │   ├── sync/        # Cloud-Sync, Interconnect, Medienserver
│   │   │   └── models/      # Datenmodelle und Zustandsverwaltung (AppModel)
│   │   └── main.dart
│   └── android/             # Android-Projekt
├── packages/                # Dart-Pakete
│   ├── fushi_core/          #   Datenbankschema, Einstellungen
│   ├── fushi_engine/        #   Reine Dart-Engine, die mit dem Server geteilt wird
│   ├── fushi_server/        #   Headless-Server-CLI + Web-Oberfläche
│   ├── fushi_cli/           #   Desktop-Kommandozeilen-Client
│   ├── fushi_dictionary/    #   Bindings der Wörterbuch-Engine und Importer
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # libtorrent- / iroh-FFI-Bindings
│   └── …                    #   Mitgelieferte Forks (inappwebview Windows/Linux, gamepads)
├── native/                  # Native Quellen: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook, …
├── services/                # Log-Collector- und Bestenlisten-Backends (separat bereitgestellt)
├── tools/browser-extension/ # Browser-Erweiterung zum Nachschlagen
├── third_party/             # Mitgelieferte gepatchte Pakete (dependency_overrides)
├── ci/                      # Build-Patches und CI-Skripte
├── tool/                    # bootstrap- / setup_worktree- / Bug-Tracker-Skripte
└── docs/                    # Entwicklungsdokumentation (inkl. docs/agent/ Betriebshandbuch)
```

</details>

Der Video-Import unterstützt die Gruppierung nach Werk oder Ordner. Siehe den [Video-Workflow](../specs/2026-09-07-video-library-workflow.md) und die [MAL/TMDB-Metadaten mit AniDB-Datei-Hashing](../specs/2026-09-07-mal-tmdb-anidb-hash.md) zu Zuordnung und Hintergrundaufgaben.

Die [optionale Einrichtung von Online-Diensten](../specs/2026-09-07-online-services-setup.md) erklärt die mitgelieferten Anwendungsidentitäten, persönliche Zugangsdaten und die ausblendbare Erinnerung zur Video-Einrichtung.

## Datenschutz & Daten

Fushi speichert importierte Bücher, Wörterbücher, Schriften, Hörbuchdaten, Videos, Lesefortschritt, Markierungen, Statistiken und Einstellungen im lokalen Speicher der App.

- **Sync** — Google Drive / OneDrive / Dropbox verwenden eine OAuth-Anmeldung; WebDAV / FTP / SFTP / Fushi Server verwenden die von dir angegebene Serveradresse und Zugangsdaten. Fushi Interconnect verbindet gekoppelte Geräte direkt (LAN, IPv6, Overlay-Netzwerke oder öffentliche Adressen) und weicht auf einen Ende-zu-Ende-iroh-P2P-Tunnel aus, wenn keine direkte Route funktioniert; Kopplungslinks verlangen stets eine Bestätigung.
- **Anki** — die Kartenerstellung kommuniziert mit AnkiDroid oder der von dir konfigurierten AnkiConnect-Adresse.
- **Nutzungsstatistiken** — einmal täglich senden Desktop- und Android-Builds eine zufällige Installations-ID, die App-Version, die Plattform und den Update-Kanal an fushi.moe, um aktive Nutzer zu zählen; Konto-, Bibliotheks- oder Lesedaten sind nicht enthalten und IP-Adressen werden nicht gespeichert. Mit *Nutzungsstatistiken teilen* in den Update-Einstellungen lässt sich das abschalten. iOS-Builds senden nichts davon.
- **Nur auf deine Anfrage** — Log-Upload (nach einer einmaligen Einwilligungsabfrage), In-App-Feedback und die Bestenliste (standardmäßig aus; lädt die Titel deiner Bibliothek und deinen Fortschritt erst hoch, nachdem du zugestimmt hast).
- **Manga-OCR** — die Standard-Engine ist Google Lens, die das Seitenbild an Google sendet; wechsle in den Einstellungen zum Modell auf dem Gerät oder zur System-OCR, um Bilder lokal zu halten.
- **KI-Funktionen** — Anfragen gehen nur an den LLM-Anbieter, den du konfigurierst und einer Funktion zuweist; ohne zugewiesenen Anbieter wird nichts gesendet.
- **Drittanbieterdienste** — Metadaten-, Untertitel- und Online-Quellen-Funktionen kontaktieren die unter [Inhaltsquellen und Integrationen](#inhaltsquellen-und-integrationen) aufgeführten Dienste nur, wenn du sie verwendest.

## Entwicklungsaktivität

[![Entwicklungsaktivität](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

Die tägliche Arbeit landet auf `develop`; `main` erhält nur Release-Merges. Das Diagramm wird hier auf `main` angezeigt, aber aus `develop` erzeugt und spiegelt daher die tatsächliche Entwicklung statt des Merge-Verkehrs wider.

Die drei Bahnen sind die Update-Kanäle, die die App selbst anbietet, und jede ist auf ihren eigenen Höchstwert skaliert — Debug-Builds übertreffen stabile Releases um zwei Größenordnungen, sodass eine gemeinsame Skala die beiden anderen Bahnen auf nichts zusammenstauchen würde.

| Bahn | Was gezählt wird | So erhältst du es |
|---|---|---|
| **Debug (fortlaufend)** | Erfolgreiche Push-Builds von [release.yml](../../.github/workflows/release.yml) | Fortlaufendes Prerelease, bei jedem Push neu veröffentlicht |
| **Beta** | `v<version>-beta.<seq>`-Prereleases | Manuell ausgelöster Test-Build |
| **Stabil** | `v<version>`-Releases | Neuestes Release |

> Das obige Diagramm wird in diesem Repository erzeugt (ohne Drittanbieterdienst) und täglich vom Workflow [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml) aktualisiert.

## Star-Verlauf

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![Star History](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> Das obige Diagramm wird in diesem Repository erzeugt (ohne Drittanbieterdienst) und täglich vom Workflow [Update Star History](../../.github/workflows/star-history.yml) aktualisiert.

## Danksagungen

Fushi baut auf den folgenden Projekten und dem folgenden Ökosystem auf:

### Lernwerkzeuge und Vorbilder

| Projekt | Beschreibung |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japanisches immersives Lernwerkzeug |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS-Japanisch-Reader; Referenz für die Reader-Seitenmaschine |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Nativer Android-Reader für Japanisch |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++-Wörterbuch-Engine |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Lösung zur Hörbuch-Synchronisierung |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | Algorithmus zur zeitlichen Ausrichtung von Untertiteln an einer Referenz (GPL-3.0); Grundlage für das automatische Ausrichten heruntergeladener Untertitel an eingebetteten Spuren |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referenz für Wörterbuchformat, Transformationstabellen und Nachschlageerlebnis |
| [Lapis](https://github.com/donkuri/lapis) | Anki-Notiztyp |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Android-Integration der Kartenerstellung |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referenz für lokales Audio und die Interaktion mit AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referenz für Reader-, Statistik- und Sync-Kompatibilität |
| [media_kit](https://github.com/media-kit/media-kit) | Flutter-Framework für Videowiedergabe (libmpv-Kern) |
| [Niratan](https://github.com/W1ght/Niratan) | Immersive Sprachlern-Suite für macOS |

### Engines und native Komponenten

| Projekt | Beschreibung |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | Galgame-Text-Hooking-Engine (mitgelieferte DLLs, vom Injektor geladen) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | Inline-Hooking-Bibliothek des Galgame-Injektors |
| [libtorrent](https://github.com/arvidn/libtorrent) | Integrierte Torrent-Download-Engine |
| [mpv](https://github.com/mpv-player/mpv) | libmpv-Wiedergabekern hinter media_kit |
| [FFmpeg](https://ffmpeg.org) | Medienanalyse, Zuschneiden und Audio-Extraktion |
| [libplacebo](https://github.com/haasn/libplacebo) | GPU-Video-Shader und HDR-Tone-Mapping |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | WebView-Engine, die den EPUB-Reader rendert |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | Inferenz auf dem Gerät für Spracherkennung und OCR |
| [iroh](https://github.com/n0-computer/iroh) | P2P-Tunnel für Remote-Verbindungen von Fushi Interconnect |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | Abhängigkeiten der Wörterbuch-Engine |

### Modelle auf dem Gerät

| Projekt | Beschreibung |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | Zipformer-Spracherkennungs-Modellpakete und VAD-Builds |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | Japanisches Spracherkennungsmodell |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | Japanisches Spracherkennungsmodell |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | Japanisches Spracherkennungsmodell (CC BY-NC 4.0, wird aus seinem Hugging-Face-Repository heruntergeladen) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | Mehrsprachiges CTC-Spracherkennungsmodell |
| [Silero VAD](https://github.com/snakers4/silero-vad) | Modell zur Spracherkennungsaktivität (Voice Activity Detection) |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | Modell zur Erkennung von Manga-Text und Sprechblasen |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | Modell zur Erkennung von Manga-Panels, trainiert mit [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | Detektion und Erkennung von Textzeilen; das auf Manga abgestimmte rec (trainiert mit [Manga109-s](http://www.manga109.org/en/download_s.html) und [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) treibt das lokale CTC-OCR-Modell pro Spalte an |

> Das Modell zur Manga-Panel-Erkennung und PP-OCRv6_manga werden mit dem Datensatz Manga109-s trainiert (Matsui et al. 2017; Aizawa et al. 2020), dessen Bedingungen verlangen, diese Nutzung des Datensatzes deutlich anzugeben. PP-OCRv6_manga (Apache-2.0) wird zusätzlich mit dem Datensatz AnimeText trainiert, der unter CC BY-NC-SA 4.0 lizenziert ist; die App lädt dieses Modell aus seinem Hugging-Face-Repository herunter und verbreitet es nicht weiter.

### Inhaltsquellen und Integrationen

| Projekt | Beschreibung |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | Ökosystem für Manga-Quellen-Erweiterungen |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | Ökosystem für Anime-Quellen-Erweiterungen (extensions-lib 14–16, von derselben Laufzeit gehostet) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | Manga-Erweiterungslaufzeit für den Desktop (mitgeliefert, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | Referenz für die Anpassung von Mihon-/Aniyomi-Erweiterungen |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | Plugin-Ökosystem für Light-Novel-Quellen |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | Medienserver, die sich aus der Videobibliothek durchsuchen lassen |
| [asbplayer](https://github.com/asbplayer/asbplayer) | Referenz für die Streaming-Untertitel-Brücke der Browser-Erweiterung |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | Architekturreferenz für Anime-Identifikation und -Scraping |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | Referenz für die Informationsarchitektur der Galgame-Bibliothek |
| [AniDB](https://anidb.net) | Identität von Anime, Episoden und Dateien |
| [MyAnimeList](https://myanimelist.net) (über [Jikan](https://jikan.moe)) | Anime-Metadaten |
| [TMDB](https://www.themoviedb.org) | Ergänzende Metadaten und Artwork |
| [VNDB](https://vndb.org) | Metadaten zu Visual Novels |
| [Jimaku](https://jimaku.cc) | Quelle für japanische Untertitel |
| [OpenSubtitles](https://www.opensubtitles.com) | Untertitelquelle |

> Diese Anwendung verwendet TMDB und die TMDB-APIs, ist jedoch nicht von TMDB unterstützt, zertifiziert oder anderweitig genehmigt.

## Lizenz

Vertrieben unter der GNU General Public License v3.0. Details siehe [LICENSE](../../LICENSE).

## Betreuer

Fushi wird von [hajisensai](https://github.com/hajisensai) betreut. Website: [fushi.moe](https://fushi.moe). Kontakt: [contact@fushi.moe](mailto:contact@fushi.moe).

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | **Deutsch** | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
