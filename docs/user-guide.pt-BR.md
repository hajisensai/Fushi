# O guia do Fushi que até a Yui Hirasawa configura em 5 minutos

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | **Português** | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> O guia em chinês simplificado está hospedado no Feishu (link acima). O guia em inglês também está disponível [no GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## Introdução

**Fushi — transforme maratonas de leitura e de séries em input linguístico.**

Toque em qualquer palavra para consultá-la enquanto lê romances, assiste a animes ou ouve audiolivros, e envie as palavras novas para o Anki junto com a frase de onde vieram.

Sem listas de palavras predefinidas — você só revisa as palavras com que realmente se deparou. Funciona com qualquer idioma.

- 📖 Leitura de EPUB · toque para consultar
- 🎧 Audiolivros com destaque frase a frase
- 🎬 Consulta em legendas de vídeo e criação de cartões
- 🃏 Criação de cartões no Anki com um toque + estatísticas de revisão
- 📚 Leitura de mangá · consulte palavras direto da página via OCR
- ⬇️ Downloads de anime e mangá dentro do app com um toque — adicionados automaticamente à sua biblioteca e reproduzíveis mesmo enquanto ainda baixam
- 🎮 Mineração de voz em Galgame (Windows) · a fala original vai para o cartão junto com o texto

Plataformas: Android / Windows / macOS / iOS (Linux pode ser compilado a partir do código-fonte; ainda não há pacotes prontos)

### URL do projeto

https://github.com/hajisensai/Fushi

Em desenvolvimento ativo — seu feedback será tratado prontamente. Relatórios de bugs e pedidos de recursos são bem-vindos. Se o Fushi for útil para você, agradecemos se compartilhá-lo com outras pessoas ou deixar uma ⭐ no repositório.

### Download

https://github.com/hajisensai/Fushi/releases/latest

Escolha o arquivo correspondente à sua plataforma: **Android** — o APK `arm64-v8a` (todos os celulares dos últimos anos usam esse; apenas aparelhos mais antigos precisam do `armeabi-v7a`, e emuladores usam `x86_64`); **Windows** — `windows-setup.exe`; **macOS** — `macos.zip`; **iOS** — `ios.ipa`. O **Linux** ainda não tem pacote pronto, então precisa ser compilado a partir do código-fonte.

Os APKs cujos nomes começam com `bridge-` são pontes de migração para **usuários do antigo Hibiki**; você pode ignorá-los.

## Tutorial de configuração

### 1. Importar os dicionários recomendados (dicionários de palavras + acento tonal + frequência) e o áudio local (bancos de dados de áudio em japonês e inglês) (Altamente recomendado para iniciantes!!! · opcional)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Download pelo Cloudflare (9,5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

No aplicativo: Configurações -> Sincronização e backup -> toque em **Importar backup**.

![Tela de importação de backup](static-assets/user-guide/import-backup.png)

### 2. Baixar e configurar o Anki no site oficial do Anki

O Anki — cujo nome vem de 暗記 (あんき) — é o [sistema de repetição espaçada (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) mais usado no mundo e uma ferramenta muito importante.

Links: [Site oficial do Anki](https://apps.ankiweb.net/) · [Manual (chinês)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(chinês)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Página de download do Anki](static-assets/user-guide/anki-download.png)

Você pode dar ao Anki qualquer material que queira memorizar, e ele permite alcançar a melhor retenção com o menor tempo de estudo.

O Anki tem o [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) embutido — um dos melhores algoritmos de repetição espaçada do mundo.

**MAS!!!** O algoritmo padrão do Anki é o SM2, um algoritmo de mais de 30 anos com desempenho ruim. Certifique-se de alterar o algoritmo usado pelo Anki para **FSRS**.

#### Anki

##### Android

1. Instale e abra o Anki.
2. Volte ao Fushi e vá em Configurações -> Criação de cartões.
3. Toque em **Atualizar baralhos e tipos de nota** (marcado com "1" na imagem); o Fushi solicitará permissão — toque em Permitir.
4. Toque em **Criar baralho Lapis** (marcado com "2" na imagem).
5. Se não houver nenhum aviso ou erro em vermelho, a configuração foi bem-sucedida.

![Configuração do Anki no Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Instale e abra o Anki.
2. Clique em **Ferramentas (Tools)** no canto superior esquerdo.

![Menu Ferramentas do Anki no Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Cole o código do complemento do Anki abaixo para instalá-lo: `2055492159`
4. Volte ao Fushi e vá em Configurações -> Criação de cartões.
5. Toque em **Atualizar baralhos e tipos de nota** (marcado com "1").
6. Toque em **Criar baralho Lapis** (marcado com "2").
7. Se não houver nenhum aviso ou erro em vermelho, a configuração foi bem-sucedida.

![Configuração do Anki no Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Percorra as opções de configuração nas Configurações e veja se há algo que você gostaria de ajustar. (Opcional)

Hora de começar a imersão.

## Recursos recomendados

### Consultar palavras fora do aplicativo

**Android:** selecione uma palavra e toque em **Traduzir** ou **Fushi** no menu de seleção.

**Windows:** selecione uma palavra e pressione **Ctrl+Alt+D** (o atalho pode ser alterado em Configurações -> Atalhos).

### Consulta pela área de transferência

Tudo o que você copia é consultado automaticamente. Há dois modos de exibição — o **painel flutuante** e a **janela de texto transparente** — ambos configuráveis em Configurações -> Consulta.

### Consulta no navegador / mineração de legendas de streaming (Netflix)

Instale a extensão de navegador a partir da página inicial do Fushi.

## Agradecimentos

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
