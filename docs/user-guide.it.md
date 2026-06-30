# Guida utente di hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | **Italiano** | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> La guida in cinese semplificato è ospitata su Feishu (link sopra). La guida in inglese è disponibile anche [su GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## Introduzione

Questo è un software gratuito per Android / Windows (iOS / macOS pianificati): un'app open source multipiattaforma rivoluzionaria che unisce la lettura di romanzi, la riproduzione di audiolibri, la riproduzione di video e la ricerca nei dizionari.

### URL del progetto

https://github.com/hajisensai/hibiki

In sviluppo attivo: il tuo feedback verrà gestito tempestivamente. Le segnalazioni di bug e le richieste di funzionalità sono benvenute. Se trovi Hibiki utile, ti saremmo grati se lo condividessi con altri o lasciassi una ⭐ al repository.

### Download

https://github.com/hajisensai/hibiki/releases/latest

Android: scegli **arm64**. Windows: scegli il file **.exe**.

## Tutorial di configurazione

### 1. Importare i dizionari consigliati e l'audio locale (facoltativo)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

Nell'app: Impostazioni -> Sincronizzazione e backup -> tocca **Importa backup**.

**Nota: l'importazione di un backup cancellerà i dati locali. Questo flusso verrà migliorato in un futuro aggiornamento.**

![Schermata di importazione del backup](static-assets/user-guide/import-backup.png)

### 2. Scaricare e configurare Anki dal sito ufficiale di Anki

Anki — il cui nome deriva da 暗記 (あんき) — è il [sistema di ripetizione dilazionata (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) più usato al mondo, e uno strumento molto importante.

Link: [Sito ufficiale di Anki](https://apps.ankiweb.net/) · [Manuale (cinese)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(cinese)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Immagine: illustrazione / legenda]*

Puoi affidare ad Anki qualsiasi materiale che desideri memorizzare, e ti permette di ottenere la migliore memorizzazione con il minor tempo di studio.

Anki integra [FSRS](https://github.com/open-spaced-repetition/fsrs4anki), uno dei migliori algoritmi di ripetizione dilazionata al mondo.

**MA!!!** L'algoritmo predefinito di Anki è SM2, un algoritmo di oltre 30 anni fa con prestazioni scadenti. Assicurati di impostare l'algoritmo usato da Anki su **FSRS**.

#### Anki

##### Android

1. Installa e apri Anki.
2. Torna a hibiki, vai su Impostazioni -> Creazione carte.
3. Tocca **Aggiorna mazzi e tipi di nota** (contrassegnato con "1" nell'immagine); hibiki richiederà un'autorizzazione: tocca Consenti.
4. Tocca **Crea mazzo Lapis** (contrassegnato con "2" nell'immagine).
5. Se non compare alcun avviso o errore in rosso, la configurazione è riuscita.

![Configurazione di Anki su Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Installa e apri Anki.
2. Fai clic su **Strumenti (Tools)** in alto a sinistra.

![Menu Strumenti di Anki su Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Incolla il codice del componente aggiuntivo di Anki qui sotto per installarlo: `2055492159`
4. Torna a hibiki, vai su Impostazioni -> Creazione carte.
5. Tocca **Aggiorna mazzi e tipi di nota** (contrassegnato con "1").
6. Tocca **Crea mazzo Lapis** (contrassegnato con "2").
7. Se non compare alcun avviso o errore in rosso, la configurazione è riuscita.

![Configurazione di Anki su Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Esamina le opzioni di configurazione nelle Impostazioni e verifica se c'è qualcosa che desideri modificare. (Facoltativo)

## Ringraziamenti

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
