# La guida di Fushi che perfino Yui Hirasawa configura in 5 minuti

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | **Italiano** | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> La guida in cinese semplificato è ospitata su Feishu (link sopra). La guida in inglese è disponibile anche [su GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## Introduzione

**Fushi: trasforma le maratone di lettura e di visione in input linguistico.**

Tocca una parola qualsiasi per cercarla mentre leggi romanzi, guardi anime o ascolti audiolibri, e invia le parole nuove ad Anki insieme alla frase da cui provengono.

Nessuna lista di vocaboli preimpostata: ripassi solo le parole in cui ti sei davvero imbattuto. Funziona con qualsiasi lingua.

- 📖 Lettura di EPUB · tocca per cercare
- 🎧 Audiolibri con evidenziazione frase per frase
- 🎬 Ricerca nei sottotitoli dei video e creazione di carte
- 🃏 Creazione di carte Anki con un tocco + statistiche di ripasso
- 📚 Lettura di manga · cerca le parole direttamente dalla pagina tramite OCR
- ⬇️ Download nell'app con un tocco per anime e manga: vengono aggiunti automaticamente alla tua libreria e sono riproducibili già durante il download
- 🎮 Mining vocale da Galgame (Windows) · la battuta vocale originale finisce nella carta insieme al testo

Piattaforme: Android / Windows / macOS / iOS (Linux può essere compilato dai sorgenti; non ci sono ancora pacchetti precompilati)

### URL del progetto

https://github.com/hajisensai/Fushi

In sviluppo attivo: il tuo feedback verrà gestito tempestivamente. Le segnalazioni di bug e le richieste di funzionalità sono benvenute. Se trovi Fushi utile, ti saremmo grati se lo condividessi con altri o lasciassi una ⭐ al repository.

### Download

https://github.com/hajisensai/Fushi/releases/latest

Scegli il file corrispondente alla tua piattaforma: **Android** — l'APK `arm64-v8a` (lo usano tutti i telefoni degli ultimi anni; solo i dispositivi più vecchi hanno bisogno di `armeabi-v7a`, mentre gli emulatori usano `x86_64`); **Windows** — `windows-setup.exe`; **macOS** — `macos.zip`; **iOS** — `ios.ipa`. Per **Linux** non esiste ancora un pacchetto precompilato, quindi va compilato dai sorgenti.

Gli APK il cui nome inizia con `bridge-` sono ponti di migrazione per gli **utenti del vecchio Hibiki**; puoi ignorarli.

## Tutorial di configurazione

### 1. Importare i dizionari consigliati (dizionari di parole + accento tonale + frequenza) e l'audio locale (database audio giapponese e inglese) (Altamente consigliato per i principianti!!! · facoltativo)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Download da Cloudflare (9,5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

Nell'app: Impostazioni -> Sincronizzazione e backup -> tocca **Importa backup**.

![Schermata di importazione del backup](static-assets/user-guide/import-backup.png)

### 2. Scaricare e configurare Anki dal sito ufficiale di Anki

Anki — il cui nome deriva da 暗記 (あんき) — è il [sistema di ripetizione dilazionata (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) più usato al mondo, e uno strumento molto importante.

Link: [Sito ufficiale di Anki](https://apps.ankiweb.net/) · [Manuale (cinese)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(cinese)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Pagina di download di Anki](static-assets/user-guide/anki-download.png)

Puoi affidare ad Anki qualsiasi materiale che desideri memorizzare, e ti permette di ottenere la migliore memorizzazione con il minor tempo di studio.

Anki integra [FSRS](https://github.com/open-spaced-repetition/fsrs4anki), uno dei migliori algoritmi di ripetizione dilazionata al mondo.

**MA!!!** L'algoritmo predefinito di Anki è SM2, un algoritmo di oltre 30 anni fa con prestazioni scadenti. Assicurati di impostare l'algoritmo usato da Anki su **FSRS**.

#### Anki

##### Android

1. Installa e apri Anki.
2. Torna a Fushi, vai su Impostazioni -> Creazione carte.
3. Tocca **Aggiorna mazzi e tipi di nota** (contrassegnato con "1" nell'immagine); Fushi richiederà un'autorizzazione: tocca Consenti.
4. Tocca **Crea mazzo Lapis** (contrassegnato con "2" nell'immagine).
5. Se non compare alcun avviso o errore in rosso, la configurazione è riuscita.

![Configurazione di Anki su Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Installa e apri Anki.
2. Fai clic su **Strumenti (Tools)** in alto a sinistra.

![Menu Strumenti di Anki su Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Incolla il codice del componente aggiuntivo di Anki qui sotto per installarlo: `2055492159`
4. Torna a Fushi, vai su Impostazioni -> Creazione carte.
5. Tocca **Aggiorna mazzi e tipi di nota** (contrassegnato con "1").
6. Tocca **Crea mazzo Lapis** (contrassegnato con "2").
7. Se non compare alcun avviso o errore in rosso, la configurazione è riuscita.

![Configurazione di Anki su Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Esamina le opzioni di configurazione nelle Impostazioni e verifica se c'è qualcosa che desideri modificare. (Facoltativo)

È ora di iniziare l'immersione.

## Funzioni consigliate

### Cercare parole fuori dall'app

**Android:** seleziona una parola, poi tocca **Traduci** o **Fushi** nel menu di selezione.

**Windows:** seleziona una parola, poi premi **Ctrl+Alt+D** (la scorciatoia si può cambiare in Impostazioni -> Scorciatoie).

### Ricerca dagli appunti

Tutto ciò che copi viene cercato automaticamente. Sono disponibili due modalità di presentazione — il **pannello fluttuante** e la **finestra di testo trasparente** — entrambe configurabili in Impostazioni -> Ricerca.

### Ricerca nel browser / mining dei sottotitoli in streaming (Netflix)

Installa l'estensione per browser dalla pagina iniziale di Fushi.

## Ringraziamenti

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
