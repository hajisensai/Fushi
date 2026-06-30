# hibiki-gebruikershandleiding

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | **Nederlands** | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> De handleiding in Vereenvoudigd Chinees wordt gehost op Feishu (link hierboven). De Engelse handleiding is ook beschikbaar [op GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## Inleiding

Dit is gratis software voor Android / Windows (iOS / macOS gepland) — een baanbrekende, platformonafhankelijke open-source-app die het lezen van romans, het afspelen van luisterboeken, het afspelen van video en het opzoeken in woordenboeken samenbrengt.

### Project-URL

https://github.com/hajisensai/hibiki

Actief in ontwikkeling — je feedback wordt snel afgehandeld. Bugmeldingen en functieverzoeken zijn welkom. Als je Hibiki nuttig vindt, stellen we het op prijs als je het met anderen deelt of een ⭐ aan de repository geeft.

### Downloaden

https://github.com/hajisensai/hibiki/releases/latest

Android: kies **arm64**. Windows: kies het **.exe**-bestand.

## Configuratiehandleiding

### 1. Aanbevolen woordenboeken en lokale audio importeren (optioneel)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

In de app: Instellingen -> Synchronisatie en back-up -> tik op **Back-up importeren**.

**Let op: het importeren van een back-up wist lokale gegevens. Deze flow wordt in een toekomstige update verbeterd.**

![Scherm voor back-up importeren](static-assets/user-guide/import-backup.png)

### 2. Anki downloaden en configureren via de officiële Anki-website

Anki — vernoemd naar 暗記 (あんき) — is wereldwijd het meest gebruikte [systeem voor gespreide herhaling (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) en een zeer belangrijk hulpmiddel.

Links: [Officiële Anki-website](https://apps.ankiweb.net/) · [Handleiding (Chinees)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Chinees)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Afbeelding: illustratie / legenda]*

Je kunt Anki elk materiaal geven dat je wilt onthouden, en het stelt je in staat de beste retentie te bereiken met de minste studietijd.

Anki heeft [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) ingebouwd — een van de beste algoritmen voor gespreide herhaling ter wereld.

**MAAR!!!** Het standaardalgoritme van Anki is SM2, een algoritme van meer dan 30 jaar geleden dat slecht presteert. Zorg ervoor dat je het door Anki gebruikte algoritme omschakelt naar **FSRS**.

#### Anki

##### Android

1. Installeer en open Anki.
2. Ga terug naar hibiki en ga naar Instellingen -> Kaarten maken.
3. Tik op **Decks en notitietypen vernieuwen** (gemarkeerd met "1" in de afbeelding); hibiki vraagt om toestemming — tik op Toestaan.
4. Tik op **Lapis-deck maken** (gemarkeerd met "2" in de afbeelding).
5. Als er geen rode waarschuwing of fout verschijnt, is de installatie geslaagd.

![Anki-installatie op Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Installeer en open Anki.
2. Klik linksboven op **Hulpmiddelen (Tools)**.

![Anki-menu Hulpmiddelen op Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Plak de onderstaande Anki-add-oncode om deze te installeren: `2055492159`
4. Ga terug naar hibiki en ga naar Instellingen -> Kaarten maken.
5. Tik op **Decks en notitietypen vernieuwen** (gemarkeerd met "1").
6. Tik op **Lapis-deck maken** (gemarkeerd met "2").
7. Als er geen rode waarschuwing of fout verschijnt, is de installatie geslaagd.

![Anki-installatie op Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Loop de configuratieopties in Instellingen door en kijk of er iets is dat je wilt aanpassen. (Optioneel)

## Dankbetuigingen

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
