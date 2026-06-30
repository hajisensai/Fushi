# hibiki Benutzerhandbuch

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | **Deutsch** | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Der Leitfaden auf Vereinfachtem Chinesisch wird auf Feishu gehostet (Link oben). Der englische Leitfaden ist außerdem [auf GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md) verfügbar.

## Einführung

Dies ist kostenlose Software für Android / Windows (iOS / macOS geplant) – eine bahnbrechende, plattformübergreifende Open-Source-App, die Romanlesen, Hörbuchwiedergabe, Videowiedergabe und Wörterbuchsuche vereint.

### Projekt-URL

https://github.com/hajisensai/hibiki

Aktiv in Entwicklung – dein Feedback wird zeitnah bearbeitet. Fehlerberichte und Funktionswünsche sind willkommen. Wenn dir Hibiki nützlich ist, freuen wir uns, wenn du es weiterempfiehlst oder dem Repository einen ⭐ gibst.

### Download

https://github.com/hajisensai/hibiki/releases/latest

Android: Wähle **arm64**. Windows: Wähle die **.exe**-Datei.

## Einrichtungs-Tutorial

### 1. Empfohlene Wörterbücher und lokales Audio importieren (optional)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

In der App: Einstellungen -> Synchronisierung & Sicherung -> tippe auf **Sicherung importieren**.

**Hinweis: Beim Importieren einer Sicherung werden lokale Daten gelöscht. Dieser Ablauf wird in einem zukünftigen Update verbessert.**

![Bildschirm zum Importieren der Sicherung](static-assets/user-guide/import-backup.png)

### 2. Anki von der offiziellen Anki-Website herunterladen und einrichten

Anki – benannt nach 暗記 (あんき) – ist das weltweit am weitesten verbreitete [System für verteiltes Wiederholen (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) und ein sehr wichtiges Werkzeug.

Links: [Offizielle Anki-Website](https://apps.ankiweb.net/) · [Handbuch (Chinesisch)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Chinesisch)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Bild: Illustration / Legende]*

Du kannst Anki beliebiges Material geben, das du dir merken möchtest, und es ermöglicht dir, mit der geringsten Lernzeit die beste Behaltensleistung zu erzielen.

Anki hat [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) integriert – einen der besten Algorithmen für verteiltes Wiederholen weltweit.

**ABER!!!** Ankis Standardalgorithmus ist SM2, ein über 30 Jahre alter Algorithmus mit schlechter Leistung. Stelle den von Anki verwendeten Algorithmus unbedingt auf **FSRS** um.

#### Anki

##### Android

1. Installiere und öffne Anki.
2. Kehre zu hibiki zurück und gehe zu Einstellungen -> Kartenerstellung.
3. Tippe auf **Stapel und Notiztypen aktualisieren** (im Bild mit „1“ markiert); hibiki fragt nach einer Berechtigung – tippe auf „Zulassen“.
4. Tippe auf **Lapis-Stapel erstellen** (im Bild mit „2“ markiert).
5. Wenn keine rote Warnung oder Fehlermeldung erscheint, war die Einrichtung erfolgreich.

![Anki-Einrichtung unter Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Installiere und öffne Anki.
2. Klicke oben links auf **Werkzeuge (Tools)**.

![Anki-Werkzeugmenü unter Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Füge den folgenden Anki-Add-on-Code ein, um es zu installieren: `2055492159`
4. Kehre zu hibiki zurück und gehe zu Einstellungen -> Kartenerstellung.
5. Tippe auf **Stapel und Notiztypen aktualisieren** (mit „1“ markiert).
6. Tippe auf **Lapis-Stapel erstellen** (mit „2“ markiert).
7. Wenn keine rote Warnung oder Fehlermeldung erscheint, war die Einrichtung erfolgreich.

![Anki-Einrichtung unter Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Gehe die Konfigurationsoptionen in den Einstellungen durch und sieh nach, ob du etwas anpassen möchtest. (Optional)

## Danksagungen

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
