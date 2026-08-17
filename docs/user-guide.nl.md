# De Fushi-handleiding die zelfs Yui Hirasawa in 5 minuten instelt

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | **Nederlands** | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> De handleiding in Vereenvoudigd Chinees wordt gehost op Feishu (link hierboven). De Engelse handleiding is ook beschikbaar [op GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## Inleiding

**Fushi — maak van bingelezen en bingekijken taalinput.**

Tik op een willekeurig woord om het op te zoeken terwijl je romans leest, anime kijkt of naar luisterboeken luistert, en stuur nieuwe woorden samen met de zin waarin je ze tegenkwam naar Anki.

Geen vooraf samengestelde woordenlijsten — je herhaalt alleen de woorden die je echt bent tegengekomen. Werkt met elke taal.

- 📖 EPUB lezen · tik om op te zoeken
- 🎧 Luisterboeken met zin-voor-zin markering
- 🎬 Opzoeken in video-ondertitels en kaarten maken
- 🃏 Anki-kaarten maken met één tik + herhalingsstatistieken
- 📚 Manga lezen · woorden rechtstreeks vanaf de pagina opzoeken via OCR
- ⬇️ Anime en manga met één tik downloaden in de app — automatisch aan je bibliotheek toegevoegd en afspeelbaar terwijl het downloaden nog bezig is
- 🎮 Galgame-stemmining (Windows) · de originele stemregel komt samen met de tekst op de kaart

Platforms: Android / Windows / macOS / iOS (Linux kan vanaf de broncode worden gebouwd; nog geen kant-en-klare pakketten)

### Project-URL

https://github.com/hajisensai/Fushi

Actief in ontwikkeling — je feedback wordt snel afgehandeld. Bugmeldingen en functieverzoeken zijn welkom. Als je Fushi nuttig vindt, stellen we het op prijs als je het met anderen deelt of een ⭐ aan de repository geeft.

### Downloaden

https://github.com/hajisensai/Fushi/releases/latest

Kies het bestand dat bij jouw platform hoort: **Android** — de `arm64-v8a`-APK (elke telefoon van de afgelopen jaren gebruikt deze; alleen oudere toestellen hebben `armeabi-v7a` nodig, en emulators gebruiken `x86_64`); **Windows** — `windows-setup.exe`; **macOS** — `macos.zip`; **iOS** — `ios.ipa`. Voor **Linux** is er nog geen kant-en-klaar pakket, dus dat moet vanaf de broncode worden gebouwd.

De APK's waarvan de naam met `bridge-` begint, zijn migratiebruggen voor **oude Hibiki-gebruikers**; die kun je negeren.

## Configuratiehandleiding

### 1. Aanbevolen woordenboeken (woord- + toonhoogteaccent- + frequentiewoordenboeken) en lokale audio (Japanse en Engelse audiodatabases) importeren (Sterk aanbevolen voor beginners!!! · optioneel)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Cloudflare-download (9,5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

In de app: Instellingen -> Synchronisatie en back-up -> tik op **Back-up importeren**.

![Scherm voor back-up importeren](static-assets/user-guide/import-backup.png)

### 2. Anki downloaden en configureren via de officiële Anki-website

Anki — vernoemd naar 暗記 (あんき) — is wereldwijd het meest gebruikte [systeem voor gespreide herhaling (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) en een zeer belangrijk hulpmiddel.

Links: [Officiële Anki-website](https://apps.ankiweb.net/) · [Handleiding (Chinees)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(Chinees)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Anki-downloadpagina](static-assets/user-guide/anki-download.png)

Je kunt Anki elk materiaal geven dat je wilt onthouden, en het stelt je in staat de beste retentie te bereiken met de minste studietijd.

Anki heeft [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) ingebouwd — een van de beste algoritmen voor gespreide herhaling ter wereld.

**MAAR!!!** Het standaardalgoritme van Anki is SM2, een algoritme van meer dan 30 jaar geleden dat slecht presteert. Zorg ervoor dat je het door Anki gebruikte algoritme omschakelt naar **FSRS**.

#### Anki

##### Android

1. Installeer en open Anki.
2. Ga terug naar Fushi en ga naar Instellingen -> Kaarten maken.
3. Tik op **Decks en notitietypen vernieuwen** (gemarkeerd met "1" in de afbeelding); Fushi vraagt om toestemming — tik op Toestaan.
4. Tik op **Lapis-deck maken** (gemarkeerd met "2" in de afbeelding).
5. Als er geen rode waarschuwing of fout verschijnt, is de installatie geslaagd.

![Anki-installatie op Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Installeer en open Anki.
2. Klik linksboven op **Hulpmiddelen (Tools)**.

![Anki-menu Hulpmiddelen op Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Plak de onderstaande Anki-add-oncode om deze te installeren: `2055492159`
4. Ga terug naar Fushi en ga naar Instellingen -> Kaarten maken.
5. Tik op **Decks en notitietypen vernieuwen** (gemarkeerd met "1").
6. Tik op **Lapis-deck maken** (gemarkeerd met "2").
7. Als er geen rode waarschuwing of fout verschijnt, is de installatie geslaagd.

![Anki-installatie op Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Loop de configuratieopties in Instellingen door en kijk of er iets is dat je wilt aanpassen. (Optioneel)

Tijd om je onder te dompelen.

## Aanbevolen functies

### Woorden opzoeken buiten de app

**Android:** selecteer een woord en tik vervolgens op **Vertalen** of **Fushi** in het selectiemenu.

**Windows:** selecteer een woord en druk op **Ctrl+Alt+D** (de sneltoets kun je wijzigen onder Instellingen -> Sneltoetsen).

### Opzoeken via het klembord

Alles wat je kopieert, wordt automatisch opgezocht. Er zijn twee weergavemodi — het **zwevende paneel** en het **transparante tekstvenster** — beide in te stellen onder Instellingen -> Opzoeken.

### Opzoeken in de browser / ondertitels minen bij streaming (Netflix)

Installeer de browserextensie via de startpagina van Fushi.

## Dankbetuigingen

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
