# Guia do usuário do hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | **Português** | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> O guia em chinês simplificado está hospedado no Feishu (link acima). O guia em inglês também está disponível [no GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## Introdução

Este é um software gratuito para Android / Windows (iOS / macOS planejados) — um aplicativo de código aberto multiplataforma e revolucionário que combina leitura de romances, reprodução de audiolivros, reprodução de vídeos e consulta a dicionários.

### URL do projeto

https://github.com/hajisensai/hibiki

Em desenvolvimento ativo — seu feedback será tratado prontamente. Relatórios de bugs e pedidos de recursos são bem-vindos. Se o Hibiki for útil para você, agradecemos se compartilhá-lo com outras pessoas ou deixar uma ⭐ no repositório.

### Download

https://github.com/hajisensai/hibiki/releases/latest

Android: escolha **arm64**. Windows: escolha o arquivo **.exe**.

## Tutorial de configuração

### 1. Importar os dicionários recomendados e o áudio local (opcional)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

No aplicativo: Configurações -> Sincronização e backup -> toque em **Importar backup**.

**Observação: importar um backup apagará os dados locais. Esse fluxo será aprimorado em uma atualização futura.**

![Tela de importação de backup](static-assets/user-guide/import-backup.png)

### 2. Baixar e configurar o Anki no site oficial do Anki

O Anki — cujo nome vem de 暗記 (あんき) — é o [sistema de repetição espaçada (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) mais usado no mundo e uma ferramenta muito importante.

Links: [Site oficial do Anki](https://apps.ankiweb.net/) · [Manual (chinês)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(chinês)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Imagem: ilustração / legenda]*

Você pode dar ao Anki qualquer material que queira memorizar, e ele permite alcançar a melhor retenção com o menor tempo de estudo.

O Anki tem o [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) embutido — um dos melhores algoritmos de repetição espaçada do mundo.

**MAS!!!** O algoritmo padrão do Anki é o SM2, um algoritmo de mais de 30 anos com desempenho ruim. Certifique-se de alterar o algoritmo usado pelo Anki para **FSRS**.

#### Anki

##### Android

1. Instale e abra o Anki.
2. Volte ao hibiki e vá em Configurações -> Criação de cartões.
3. Toque em **Atualizar baralhos e tipos de nota** (marcado com "1" na imagem); o hibiki solicitará permissão — toque em Permitir.
4. Toque em **Criar baralho Lapis** (marcado com "2" na imagem).
5. Se não houver nenhum aviso ou erro em vermelho, a configuração foi bem-sucedida.

![Configuração do Anki no Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Instale e abra o Anki.
2. Clique em **Ferramentas (Tools)** no canto superior esquerdo.

![Menu Ferramentas do Anki no Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Cole o código do complemento do Anki abaixo para instalá-lo: `2055492159`
4. Volte ao hibiki e vá em Configurações -> Criação de cartões.
5. Toque em **Atualizar baralhos e tipos de nota** (marcado com "1").
6. Toque em **Criar baralho Lapis** (marcado com "2").
7. Se não houver nenhum aviso ou erro em vermelho, a configuração foi bem-sucedida.

![Configuração do Anki no Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Percorra as opções de configuração nas Configurações e veja se há algo que você gostaria de ajustar. (Opcional)

## Agradecimentos

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
