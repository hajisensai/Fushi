# Das Fushi-Handbuch, das selbst Yui Hirasawa in 5 Minuten einrichtet

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | **Deutsch** | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Der Leitfaden auf Vereinfachtem Chinesisch wird auf Feishu gehostet (Link oben). Der englische Leitfaden ist außerdem [auf GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md) verfügbar.

## Einführung

**Fushi – mach aus Lese- und Serienmarathons sprachlichen Input.**

Tippe beim Lesen von Romanen, beim Anime-Schauen oder beim Hören von Hörbüchern auf ein beliebiges Wort, um es nachzuschlagen, und schicke neue Wörter zusammen mit dem Satz, aus dem sie stammen, an Anki.

Keine vorgefertigten Wortlisten – du wiederholst nur die Wörter, die dir tatsächlich begegnet sind. Funktioniert mit jeder Sprache.

- 📖 EPUB lesen · zum Nachschlagen antippen
- 🎧 Hörbücher mit satzweiser Hervorhebung
- 🎬 Nachschlagen in Video-Untertiteln und Kartenerstellung
- 🃏 Anki-Karten mit einem Tippen erstellen + Wiederholungsstatistiken
- 📚 Manga lesen · Wörter per OCR direkt von der Seite nachschlagen
- ⬇️ Downloads für Anime und Manga mit einem Tippen direkt in der App – automatisch zu deiner Bibliothek hinzugefügt und schon während des Downloads abspielbar
- 🎮 Galgame-Voice-Mining (Windows) · die originale Sprachaufnahme landet zusammen mit dem Text auf der Karte

Plattformen: Android / Windows / macOS / iOS (Linux kann aus dem Quellcode gebaut werden; noch keine vorgefertigten Pakete)

### Projekt-URL

https://github.com/hajisensai/Fushi

Aktiv in Entwicklung – dein Feedback wird zeitnah bearbeitet. Fehlerberichte und Funktionswünsche sind willkommen. Wenn dir Fushi nützlich ist, freuen wir uns, wenn du es weiterempfiehlst oder dem Repository einen ⭐ gibst.

### Download

https://github.com/hajisensai/Fushi/releases/latest

Wähle die Datei, die zu deiner Plattform passt: **Android** – das `arm64-v8a`-APK (alle Handys der letzten Jahre nutzen dieses; nur ältere Geräte brauchen `armeabi-v7a`, und Emulatoren nutzen `x86_64`); **Windows** – `windows-setup.exe`; **macOS** – `macos.zip`; **iOS** – `ios.ipa`. Für **Linux** gibt es noch kein vorgefertigtes Paket, es muss also aus dem Quellcode gebaut werden.

Die APKs, deren Namen mit `bridge-` beginnen, sind Migrationsbrücken für **Nutzer des früheren Hibiki**; du kannst sie ignorieren.

## Einrichtungs-Tutorial

### 1. Empfohlene Wörterbücher (Wort- + Tonhöhenakzent- + Häufigkeitswörterbücher) und lokales Audio (japanische und englische Audiodatenbanken) importieren (Sehr empfehlenswert für Einsteiger!!! · optional)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Cloudflare-Download (9,5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

In der App: Einstellungen -> Synchronisierung & Sicherung -> tippe auf **Sicherung importieren**.

![Bildschirm zum Importieren der Sicherung](static-assets/user-guide/import-backup.png)

### 2. Anki von der offiziellen Anki-Website herunterladen und einrichten

Anki – benannt nach 暗記 (あんき) – ist das weltweit am weitesten verbreitete [System für verteiltes Wiederholen (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) und ein sehr wichtiges Werkzeug.

Links: [Offizielle Anki-Website](https://apps.ankiweb.net/) · [Handbuch (Chinesisch)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Chinesisch)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Anki-Downloadseite](static-assets/user-guide/anki-download.png)

Du kannst Anki beliebiges Material geben, das du dir merken möchtest, und es ermöglicht dir, mit der geringsten Lernzeit die beste Behaltensleistung zu erzielen.

Anki hat [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) integriert – einen der besten Algorithmen für verteiltes Wiederholen weltweit.

**ABER!!!** Ankis Standardalgorithmus ist SM2, ein über 30 Jahre alter Algorithmus mit schlechter Leistung. Stelle den von Anki verwendeten Algorithmus unbedingt auf **FSRS** um.

#### Anki

##### Android

1. Installiere und öffne Anki.
2. Kehre zu Fushi zurück und gehe zu Einstellungen -> Kartenerstellung.
3. Tippe auf **Stapel und Notiztypen aktualisieren** (im Bild mit „1“ markiert); Fushi fragt nach einer Berechtigung – tippe auf „Zulassen“.
4. Tippe auf **Lapis-Stapel erstellen** (im Bild mit „2“ markiert).
5. Wenn keine rote Warnung oder Fehlermeldung erscheint, war die Einrichtung erfolgreich.

![Anki-Einrichtung unter Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Installiere und öffne Anki.
2. Klicke oben links auf **Werkzeuge (Tools)**.

![Anki-Werkzeugmenü unter Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Füge den folgenden Anki-Add-on-Code ein, um es zu installieren: `2055492159`
4. Kehre zu Fushi zurück und gehe zu Einstellungen -> Kartenerstellung.
5. Tippe auf **Stapel und Notiztypen aktualisieren** (mit „1“ markiert).
6. Tippe auf **Lapis-Stapel erstellen** (mit „2“ markiert).
7. Wenn keine rote Warnung oder Fehlermeldung erscheint, war die Einrichtung erfolgreich.

![Anki-Einrichtung unter Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Gehe die Konfigurationsoptionen in den Einstellungen durch und sieh nach, ob du etwas anpassen möchtest. (Optional)

Zeit, mit dem Immersionslernen zu beginnen.

## Empfohlene Funktionen

### Wörter außerhalb der App nachschlagen

**Android:** Markiere ein Wort und tippe dann im Auswahlmenü auf **Übersetzen** oder **Fushi**.

**Windows:** Markiere ein Wort und drücke dann **Ctrl+Alt+D** (das Tastenkürzel lässt sich unter Einstellungen -> Tastenkürzel ändern).

### Nachschlagen aus der Zwischenablage

Alles, was du kopierst, wird automatisch nachgeschlagen. Es stehen zwei Darstellungsmodi zur Verfügung – das **schwebende Fenster** und das **transparente Textfenster** – beide konfigurierbar unter Einstellungen -> Nachschlagen.

### Nachschlagen im Browser / Untertitel-Mining bei Streaming-Diensten (Netflix)

Installiere die Browser-Erweiterung über die Fushi-Startseite.

## Danksagungen

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
