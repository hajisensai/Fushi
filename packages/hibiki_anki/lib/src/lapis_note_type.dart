/// Authoritative Lapis note type definition.
///
/// `front` / `back` / `css` are vendored verbatim from donkuri/lapis v1.7.0
/// (tag `1.7.0`, src/front.html · src/back.html · src/styling.css).
/// Upstream: https://github.com/donkuri/lapis  — License: GPL-3.0
/// Authors: Ruri, itokatsu, kuri (donkuri). Hibiki is itself GPL-3.0.
/// Do not hand-edit; re-vendor from the pinned tag when bumping versions.
library;

/// A backend-agnostic note-type creation template (name + fields + one card).
class AnkiNoteTypeTemplate {
  const AnkiNoteTypeTemplate({
    required this.name,
    required this.fields,
    required this.cardName,
    required this.front,
    required this.back,
    required this.css,
  });

  final String name;
  final List<String> fields;
  final String cardName;
  final String front;
  final String back;
  final String css;
}

class LapisNoteType {
  static const String modelName = 'Lapis';
  static const String deckName = 'Lapis';
  static const String cardName = 'Card 1';

  static const List<String> fields = <String>[
    'Expression',
    'ExpressionFurigana',
    'ExpressionReading',
    'ExpressionAudio',
    'SelectionText',
    'MainDefinition',
    'DefinitionPicture',
    'Sentence',
    'SentenceFurigana',
    'SentenceAudio',
    'Picture',
    'Glossary',
    'Hint',
    'IsWordAndSentenceCard',
    'IsClickCard',
    'IsSentenceCard',
    'IsAudioCard',
    'PitchPosition',
    'PitchCategories',
    'Frequency',
    'FreqSort',
    'MiscInfo',
  ];

  /// 字段 → Hibiki 占位符默认映射。未列出的字段（DefinitionPicture /
  /// SentenceFurigana / Hint / IsClickCard / IsSentenceCard / IsAudioCard）
  /// 故意留空：Lapis 官方建议 SentenceFurigana 留空，卡型选择器一次只填一个。
  static const Map<String, String> defaultFieldMappings = <String, String>{
    'Expression': '{expression}',
    'ExpressionFurigana': '{furigana-plain}',
    'ExpressionReading': '{reading}',
    'ExpressionAudio': '{audio}',
    'SelectionText': '{popup-selection-text}',
    'MainDefinition': '{glossary-first}',
    'Sentence': '{sentence}',
    'SentenceAudio': '{sasayaki-audio}',
    'Picture': '{book-cover}',
    'Glossary': '{glossary}',
    'PitchPosition': '{pitch-accent-positions}',
    'PitchCategories': '{pitch-accent-categories}',
    'Frequency': '{frequencies}',
    'FreqSort': '{frequency-harmonic-rank}',
    'MiscInfo': '{document-title}',
    'IsWordAndSentenceCard': 'x',
  };

  static const String front = r'''<div id="lapis">
    <!---------- Header ------------->
    <header style="visibility: hidden"></header>

    <main lang="ja" style="width: 100%;">
    <!--------- Vocab card ---------->
    {{^IsSentenceCard}} {{^IsWordAndSentenceCard}} {{^IsClickCard}}
    {{^IsAudioCard}}
    <div lang="ja" class="front-vocab">{{Expression}}</div>
    {{/IsAudioCard}} {{/IsClickCard}} {{/IsWordAndSentenceCard}}
    {{/IsSentenceCard}}

    <!------- Sentence card --------->
    {{#IsSentenceCard}}
    <div lang="ja" class="front-sentence">{{kanji:Sentence}}</div>
    {{/IsSentenceCard}}

    <!--------- Word And Sentence card ----------->
    {{#IsWordAndSentenceCard}}
    <div lang="ja" class="front-vocab">{{Expression}}</div>
    <div lang="ja" id="hint">{{kanji:Sentence}}</div>
    {{/IsWordAndSentenceCard}}

    <!-------- Click card ----------->
    {{#IsClickCard}}
    <div id="click" class="tappable">
        <div lang="ja" class="front-vocab">{{Expression}}</div>
    </div>
    {{/IsClickCard}}

    <!-------- Audio card ----------->
    {{#IsAudioCard}}
    <div id="audio">
        <div lang="ja" class="front-sentence">{{kanji:Sentence}}</div>
        <div>
        {{#SentenceAudio}}{{SentenceAudio}}{{/SentenceAudio}}
        {{^SentenceAudio}}{{ExpressionAudio}}{{/SentenceAudio}}
        </div>
    </div>
    {{/IsAudioCard}}

    <!-- Hint -->
    {{#Hint}}
    <div id="hint">{{Hint}}</div>
    {{/Hint}}
    </main>
</div>

<script>
  function ClickCard() {
    const clickElement = document.getElementById("click");

    // Store original content so that we can click back to it
    const originalContent = clickElement.innerHTML;

    // This is what it is going to click to
    const clickedContent = `<div lang="ja" class="front-sentence">{{kanji:Sentence}}</div>`;

    function toggleContent() {
      if (clickElement.innerHTML === originalContent) {
        clickElement.innerHTML = clickedContent;
      } else {
        clickElement.innerHTML = originalContent;
      }
    }
    // Implement the clicking mechanism
    clickElement.addEventListener("click", (e) => toggleContent());
    document.addEventListener("keydown", (e) => {
      if ((event.key === "c") | (event.key === "C")) toggleContent();
    });
  }

  function HideTargetWord() {
    const targetWords = document.querySelectorAll("#audio b");
    targetWords.forEach((word) => (word.innerText = "[...]"));
  }

  function initialize() {
    // Check what card type it is
    if (`{{IsClickCard}}`) ClickCard();
    if (`{{IsAudioCard}}`) HideTargetWord();
  }

  initialize();
</script>
''';
  static const String back = r'''<div id="lapis" lang="ja">
    <!---------- Header ------------->
    <header>
        <div class="top-container">
            <!-- Show the frequency number -->
            {{FreqSort}}

            <!-- The frequency list -->
            {{#Frequency}}
            <span class="freq-dropdown">
                <svg xmlns="http://www.w3.org/2000/svg" width="15" height="15" class="dropdown-arrow-svg"
                    viewBox="0 0 16 16">
                    <path d="M8 15A7 7 0 1 1 8 1a7 7 0 0 1 0 14zm0 1A8 8 0 1 0 8 0a8 8 0 0 0 0 16z"></path>
                    <path d="M 12.7,6.5 H 3.3 L 8,11 Z"></path>
                </svg>
                <div class="freq-list-container">{{Frequency}}</div>
            </span>
            {{/Frequency}}
        </div>
    </header>

    <main>
        <!-- The first row (vocab box+picture) -->
        <div class="def-header">
            <div class="dh-vocab">
                <div class="vocab">
                    {{#ExpressionFurigana}}{{furigana:ExpressionFurigana}}{{/ExpressionFurigana}}
                    {{^ExpressionFurigana}}{{Expression}}{{/ExpressionFurigana}}
                </div>

                <!-- Reading + Pitch Accent -->
                <div class="info">
                    <div class="pitch">
                        {{#ExpressionFurigana}}{{kana:ExpressionFurigana}}{{/ExpressionFurigana}}
                        {{^ExpressionFurigana}}{{ExpressionReading}}{{/ExpressionFurigana}}
                    </div>

                    <!-- Pitch Accent -->
                    <span id="pitch-tags" class="tags">{{PitchPosition}}</span>
                    <br />
                    <div class="audio-buttons"></div>
                </div>
            </div>

            <!-- Image -->
            {{#Picture}}
            <div class="dh-image">
                <div class="image tappable {{Tags}}">{{Picture}}</div>
            </div>
            {{/Picture}}
        </div>

        <br>
        <div class="sentence">
            {{#Picture}}<div class="image-alt tappable {{Tags}}">{{Picture}}</div>{{/Picture}}
                {{#SentenceFurigana}} {{furigana:SentenceFurigana}} {{/SentenceFurigana}}
                {{^SentenceFurigana}} {{furigana:Sentence}} {{/SentenceFurigana}}
            <div class="audio-buttons-alt"></div>
        </div>

        <!-- The entire definition box -->
        <div class="def-info">First Definition 1/?</div>
        <div class="main-def">
            <div class="edge tappable" id="edge-prev" onclick="changeIndex(-1)"></div>
            <div class="edge tappable" id="edge-next" onclick="changeIndex(1)"></div>
            {{#DefinitionPicture}}
            <div class="def-image tappable">{{DefinitionPicture}}</div>
            {{/DefinitionPicture}}
            <div class="definition">
                {{#SelectionText}}
                <div id="selection" data-display-name="Text Selection">{{SelectionText}}</div>
                {{/SelectionText}}
                {{#MainDefinition}}
                <div id="primary" data-display-name="Primary Definition">{{MainDefinition}}</div>
                {{/MainDefinition}}
                <div id="glossaries" data-display-name="Glossaries">{{Glossary}}</div>
            </div>
        </div>

        <!-- Alternative Sentence Position -->
        <div class="sentence-alt">
            {{#Picture}}<div class="image-alt tappable {{Tags}}">{{Picture}}</div>{{/Picture}}
                {{#SentenceFurigana}} {{furigana:SentenceFurigana}} {{/SentenceFurigana}}
                {{^SentenceFurigana}} {{furigana:Sentence}} {{/SentenceFurigana}}
            <div class="audio-buttons-alt"></div>
        </div>

        <!------- Image modal --------->
        <div class="modal-bg tappable">
            <div class="img-popup"></div>
        </div>

        {{#MiscInfo}}
        <details>
            <summary>Misc. info</summary>
            <div class="misc-info">
                === Details ===
                <br />
                {{MiscInfo}}
            </div>
        </details>
        {{/MiscInfo}}
    </main>

    <!----------- Footer ------------->
    <footer>
        <br>
        <div class="bot-container">
            {{#Tags}}
            <div class="tags-container">
                <div class="tags">{{Tags}}</div>
            </div>
            {{/Tags}}
        </div>
    </footer>
</div>

<!----------- Scripts ------------>
<script>
    // Hack to add multiple buttons without Anki playing them multiple times
    function addAudioButtons() {
        const audioContainers = document.querySelectorAll(".audio-buttons, .audio-buttons-alt");
        audioContainers.forEach(audio => audio.innerHTML = `{{ExpressionAudio}}{{SentenceAudio}}`);
    }

    function getPitchCategories() {
        const validTypes = "(heiban|atamadaka|nakadaka|odaka|kifuku)";
        return [...`{{PitchCategories}}`.matchAll(validTypes)].map(m => m[0]);
    }

    function hasVerbOrAdjEnding() {
        const endings = ["い", "う", "く", "ぐ", "す", "つ", "ぶ", "む", "る"];
        return endings.some(ending => `{{text:Expression}}`.endsWith(ending));
    }

    function getPitchType(word_kana, pitchPosition) {
        if (pitchPosition === 0) return "heiban";
        const pitchCategories = getPitchCategories();
        const kifukuTags = ["adj-i", "v1", "v2", "v4", "v5", "vs-", "vz", "vk", "vn", "vr"];
        let canBeKifuku = pitchCategories.includes("kifuku");
        canBeKifuku ||= kifukuTags.some(tag => `{{PitchCategories}}`.includes(tag));
        if (canBeKifuku || (pitchCategories.length == 0 && hasVerbOrAdjEnding())) {
            return "kifuku";
        } else if (pitchPosition === 1) {
            return "atamadaka";
        } else if (pitchPosition > 1) {
            return removeSmallKana(word_kana).length === pitchPosition ? "odaka" : "nakadaka";
        }
    }

    function handlePitches() {
        const exprKana = `{{kana:ExpressionFurigana}}` || `{{ExpressionReading}}`;
        const isYomitan = document.querySelector("#glossaries .yomitan-glossary");

        // Dirty single katakana to hiragana conversion
        const toHiragana = (kana) => {
            const codePoint = kana?.codePointAt(0)
            const isKatakana = codePoint >= 0x30A1 && codePoint <= 0x30F6;
            return isKatakana ? String.fromCodePoint(codePoint - 0x60) : kana;
        }
        const parsePitch = (pitch) => {
            const number = Number(pitch);
            if (!isNaN(number)) return number;
            // Normalize nasal notations
            const pitchKana = pitch.replace(/([カキクケコかきくけこ])[\u309A°]/g,
                (match, p1) => String.fromCodePoint(p1.codePointAt(0) + 0x01))
                .replace(/[・\\＼ꜜ]/g,"");
            if (pitchKana.length !== exprKana.length) return null;
            const matchKana = Array.from(pitchKana).every((kana, index) => {
                const hira = toHiragana(kana);
                const exprHira = toHiragana(exprKana[index]);
                return hira === exprHira || hira === 'ー' && "あいうえお".includes(exprHira);
            });
            if (!matchKana) return null;
            const pitchArray = pitch.split("・").map(word => {
                const morae = removeSmallKana(word);
                const position = morae.search(/[\\＼ꜜ]/);
                const moraCount = morae.replace(/[\\＼ꜜ]/g,'').length;
                return {position: position === - 1 ? 0 : position, moraCount: moraCount};
            });
            return pitchArray.length === 1 ? pitchArray[0].position : pitchArray;
        }

        const fieldText = `{{text:PitchPosition}}`;
        // Pitch numbers not in a n+m pattern
        const pitchNumbers = fieldText.matchAll(/(?<!\d\+)\d+(?!\+\d)/g) || [];
        // Custom pitch strings
        const pitchStrings = fieldText.matchAll(/[あ-ヺ°ー\\＼ꜜ]+(・[あ-ヺ°ー\\＼ꜜ]+)*/g) || [];
        let pitches = [...pitchNumbers, ...pitchStrings]
            .sort((a, b) => a.index - b.index)
            .map(match => match ? parsePitch(match[0]) : null);

        // Jidoujisho graphs
        const JJGraphs = document.querySelectorAll("#pitch-tags svg");
        JJGraphs.forEach(graph => {
            const graphPaths = Array.from(graph.querySelectorAll("path"));
            const downstep = graphPaths.findIndex(path => path.getAttribute("d").endsWith(",25"));
            pitches.push(downstep === undefined ? 0 : downstep + 1);
        });
        // NHK dictionary pitches
        const NHKDict = document.querySelector(
            '#glossaries li[data-dictionary=\"NHK日本語発音アクセント新辞典\"]');
        let NHKText = NHKDict?.innerHTML.split("<br><br>")[0];
        if (!NHKText && !isYomitan) NHKText = document.querySelector("#glossaries").textContent;
        const NHKPitches = NHKText?.match(/(?<=・\d+］)[あ-ヺ°ー＼]+(・[あ-ヺ°ー＼]+)+/g) || [];
        NHKPitches.forEach(pitch => pitches.push(parsePitch(pitch)));

        pitches = pitches.filter(pitch => pitch !== null);
        if (pitches.length < 1) return;
        if(!Array.isArray(pitches[0])) paintTargetWord(getPitchType(exprKana, pitches[0]));
        constructPitch(new Set(pitches));
    }

    // Show the color
    function paintTargetWord(pitchType) {
        const sentences = Array.from(
            document.querySelectorAll(".sentence, .sentence-alt, .definition"),
        );
        for (const sentence of sentences) {
            for (const targetWord of sentence.getElementsByTagName("b")) {
                targetWord.classList.add(pitchType);
            }
        }

        const vocabElement = document.querySelector(".vocab");
        if (vocabElement !== null) {
            vocabElement.classList.add(pitchType);
        }
    }

    // Seperate Tags by space, and show them in their own boxes
    function splitTags() {
        const tagsContainer = document.querySelector(".tags-container");
        if (!tagsContainer) return;
        const tags = `{{Tags}}`.split(" ");
        tagsContainer.innerHTML = tags.map(tag =>`<div class="tags">${tag}</div>`).join('');
    }

    // Useful to determine morae count
    function removeSmallKana(kana) {
        return kana.replace(/[ァィゥェォャュョヮぁぃぅぇぉゃゅょゎ\u3099\u309A°]/g, "");
    }

    function groupMoras(kana) {
        let currentChar = "", nextChar = "";
        const groupedMoras = [];
        const smallKana = new Set("ァィゥェォャュョヮぁぃぅぇぉゃゅょゎ\u3099\u309A°");

        for (let i = 0; i < kana.length; i++) {
            currentChar = kana[i];
            nextChar = i < kana.length - 1 && kana[i + 1];
            if (smallKana.has(nextChar)) {
                groupedMoras.push(currentChar + nextChar);
                i += 1;
            } else {
                groupedMoras.push(currentChar);
            }
        }
        return groupedMoras;
    }

    function constructPitch(pitchPatterns) {
        const kana = `{{kana:ExpressionFurigana}}` || `{{ExpressionReading}}`;
        const morae = groupMoras(kana);
        const pitch = document.querySelector(".pitch");
        const pitchTags = document.querySelector("#pitch-tags");

        const createPitchSpan = (pitchClass, pitchChar) => {
            const pitchSpan = document.createElement("span");
            const charSpan = document.createElement("span");
            const lineSpan = document.createElement("span");

            pitchSpan.classList.add(pitchClass);
            charSpan.classList.add("pitch-char");
            charSpan.innerText = pitchChar;
            lineSpan.classList.add("pitch-line");

            pitchSpan.appendChild(charSpan);
            pitchSpan.appendChild(lineSpan);

            return pitchSpan;
        };

        pitch.innerHTML = "";
        pitchTags.innerHTML = "";
        const pitchList = document.createElement("ul");
        const pitchTagList = document.createElement("ul");

        for (let pitchPattern of pitchPatterns) {
            const pitchTag = document.createElement("li");
            const pitchItem = document.createElement("li");
            pitchItem.classList.add("pitch-item");

            const isCompound = Array.isArray(pitchPattern);
            if(isCompound) {
                // Filters duplicates
                const tag = pitchPattern.map(({position}) => position).join(",");
                if([...pitchTagList.children].some(pitchTag => pitchTag.innerText === tag)) continue;
                pitchTag.innerText = tag;
            } else {
                pitchItem.classList.add(getPitchType(kana, pitchPattern));
                pitchTag.innerText = pitchPattern;
                pitchPattern = [{position: pitchPattern, moraCount: morae.length}];
            }

            let offset = 0;
            for (const {position, moraCount} of pitchPattern) {
                for (let i = 0; i < moraCount; i++) {
                    let moraPitch = "";
                    if (position <= 0) {
                        moraPitch = i === 0 ? "pitch-low" : "pitch-high";
                    } else if (position === 1) {
                        moraPitch = i === 0 ? "pitch-to-drop" : "pitch-low";
                    } else {
                        moraPitch = i === position - 1 ? "pitch-to-drop" :
                            i === 0 || i >= position ? "pitch-low" : "pitch-high";
                    }
                    if (offset + i >= morae.length) continue;
                    pitchItem.appendChild(createPitchSpan(moraPitch, morae[offset + i]));
                }
                offset += moraCount;
            }
            pitchTagList.appendChild(pitchTag);
            pitchList.appendChild(pitchItem);
        }

        pitch.appendChild(pitchList);
        pitchTags.appendChild(pitchTagList);
    }

    // Returns the dictionary content, without the dictionary name.
    function getDictionaryContent(dictionarySelector) {
        const dictionary = document.querySelector(dictionarySelector);
        if (!dictionary) return null;
        const contentInSpan = dictionary.querySelector(":scope > span");
        if (contentInSpan) return contentInSpan;

        const hasDictName = dictionary.querySelector(":scope > i");
        if (!hasDictName) return dictionary;

        let dictionaryCopy = dictionary.cloneNode(true);
        dictName = dictionaryCopy.querySelector(":scope > i");
        dictName.remove();
        return dictionaryCopy;
    }

    function isPrimaryEqualToGloss() {
        const isJPMNConverted = document.querySelector(".definition li[data-details]");
        if (isJPMNConverted) return false;
        // single dict formatting
        const isSingleDict = document.querySelectorAll("#glossaries > div > ol").length === 0;
        if (isSingleDict) {
            const primaryDictName = document.querySelector("#primary > div > i");
            const glossariesDictName = document.querySelector("#glossaries > div > i");
            // Compare dicts names if present
            if (primaryDictName && glossariesDictName) {
                return primaryDictName.textContent === glossariesDictName.textContent;
            }
            // Compare content otherwise
            const primaryDict = getDictionaryContent("#primary > div");
            const glossariesDict = getDictionaryContent("#glossaries > div");
            if (!primaryDict || !glossariesDict ) return false;
            return primaryDict.innerHTML.trim() === glossariesDict.innerHTML.trim();
        }

        // multiple dicts
        const primaryDicts = document.querySelectorAll("#primary li[data-dictionary]");
        const glossariesDicts = document.querySelectorAll("#glossaries li[data-dictionary]");
        return primaryDicts.length === glossariesDicts.length;
    }

    // Removes Unnecessary definitions
    function cleanUpDefinitions() {
        let selection = document.getElementById("selection");
        let primary = document.getElementById("primary");
        let glossaries = document.getElementById("glossaries");
        if (selection && selection.textContent === "") {
            selection.remove();
        }
        if (primary && primary.textContent === "") {
            primary.remove();
            primary = null;
        }
        if (glossaries && glossaries.textContent === "") {
            glossaries.remove();
            glossaries = null;
        }
        else if (primary && glossaries && isPrimaryEqualToGloss()) {
            glossaries.remove();
        }
    }

    // Display definition corresponding to index
    function updateDefDisplay() {
        const definitions = document.querySelectorAll(
            ".main-def > .definition > div"
        );

        let n_defs = definitions.length;
        if (n_defs === 1) definitions[0].classList.remove("hidden");
        if (n_defs <= 1) return;

        let currentIndex = document.head.dataset.defIndex;
        currentIndex = currentIndex % n_defs;
        while (currentIndex < 0) currentIndex += n_defs;

        for (let idx = 0; idx < n_defs; idx++) {
            definitions[idx].classList.add("hidden");
        }
        definitions[currentIndex].classList.remove("hidden");

        const defDisplayName = definitions[currentIndex].dataset.displayName;
        const indexDisplay = document.querySelector(".def-info");
        indexDisplay.style.visibility = "visible";
        indexDisplay.innerText = `${defDisplayName} ${currentIndex + 1}/${n_defs}`;
    }

    function changeIndex(value) {
        // sync index between clicks and arrowkeys
        index = Number(document.head.dataset.defIndex);
        document.head.dataset.defIndex = index + value;
        updateDefDisplay();
    };

    function setUpDefToggle() {
        document.head.dataset.defIndex = 0;
        cleanUpDefinitions();

        // Show the first definition and ensure the index display, if relevant, is visible on initial load
        updateDefDisplay();

        // Since <head> doesn't change through review sessions
        // Adding and checking for this class ensure each card doesn't add its own listener
        if (document.head.classList.contains("has-listener")) return;
        document.addEventListener("keydown", (e) => {
            if (e.key === "ArrowLeft") changeIndex(-1);
            else if (e.key === "ArrowRight") changeIndex(1);
        });

        document.head.classList.add("has-listener");
    }

    // Image lightbox with fade transition similar to JPMN
    function clickImages() {
        const modalBg = document.querySelector(".modal-bg");
        const imgPopup = document.querySelector(".img-popup");
        let images = Array.from(document.querySelectorAll(".image img, .image-alt img, .def-image img"));
        /* Disable image links that were opening in a browser window */
        const glossImageLinks = document.querySelectorAll(".definition a:has(img)");
        glossImageLinks.forEach(link => link.href = "");

        images = [... images, ... glossImageLinks];
        if(images.length < 1) return;
        for (let image of images) {
            image.addEventListener("click", () => {
                const imgPopupContainer = document.createElement("div");
                const imgPopupImg = document.createElement("img");

                imgPopupContainer.classList.add("img-popup-container");
                imgPopupImg.src = image.src || image.querySelector("img").src;
                imgPopupImg.classList.add("img-popup-img");

                if (image.height > image.width) {
                    imgPopupContainer.style.height = "calc(100% - 20px)";
                    imgPopupContainer.style.width = "max-content";
                }

                imgPopup.innerHTML = "";
                imgPopup.appendChild(imgPopupContainer);
                imgPopupContainer.appendChild(imgPopupImg);

                // Force a reflow before adding active classes to ensure transitions work
                void modalBg.offsetWidth;

                // Show the modal background with fade transition
                modalBg.style.display = "block";

                // Force another reflow to ensure the display change takes effect before transition
                void modalBg.offsetWidth;

                modalBg.classList.add("active");
                imgPopupContainer.classList.add("active");
                document.body.classList.add("img-popup");
            });
        }

        modalBg.addEventListener("click", () => {
            // Removes active classes to trigger fade-out transition
            modalBg.classList.remove("active");
            const activeContainer = document.querySelector(".img-popup-container.active");
            if (activeContainer) {
                activeContainer.classList.remove("active");
            }
            setTimeout(() => {
                document.body.classList.remove("img-popup");
                modalBg.style.display = "none";
                imgPopup.innerHTML = "";
            }, 300);
        });
    }

    // Format plaintext comma-separated frequencies into a list
    function formatFrequencyList() {
        const frequency = document.querySelector('.freq-list-container');
        if (!frequency) return;
        const frequencyList = frequency.querySelector('ul');
        // Already a list; nothing to do
        if (frequencyList) return;

        const freqs = frequency.innerText.split(',');
        const freqHtml = `<ul>${freqs.map(freq => `<li>${freq.trim()}</li>`).join('')}</ul>`
        frequency.innerHTML = freqHtml;
    }

    // Sets the height of dhVocab, dhImage, defHeader as a whole
    function setDHHeight() {
        var dhVocab = document.querySelector('.dh-vocab');
        var dhImage = document.querySelector('.dh-image img');
        var defHeader = document.querySelector('.def-header');

        if (dhVocab && dhImage) {
            var dhVocabHeight = dhVocab.offsetHeight;
            dhImage.style.maxHeight = `${dhVocabHeight}px`;
            defHeader.style.maxHeight = `${dhVocabHeight}px`;
        }
    }

    // Hides the dictionaries user selected in MainDefinition in Glossary field, if any
    function hideCorrectDefinition() {
        // Do nothing if css rule already exists
        if (document.querySelector("style#hide-main-def")) return;

        let primaryDicts = document.querySelectorAll("#primary li[data-dictionary]");
        if (primaryDicts.length === 0) return;

        let style = document.createElement('style');
        style.type = 'text/css';
        style.id = "hide-main-def";

        const cssSelector = Array.from(primaryDicts).map((dict) =>
            `#glossaries li[data-dictionary="${dict.dataset.dictionary}"]`
        ).join(", ");
        const cssRules = `${cssSelector} { display:none !important; }`;
        style.appendChild(document.createTextNode(cssRules));

        let defContainer = document.querySelector(".main-def");
        defContainer.appendChild(style);
    }

    // Fixes list numbering when using multiple primary dicts
    function movePrimaryDicts() {
        let primaryDicts = document.querySelectorAll("#primary li[data-dictionary]");
        let firstList = document.querySelector("#primary .yomitan-glossary > ol:has(li[data-dictionary])");
        for (let idx = 1; idx < primaryDicts.length; idx++) {
            firstList.appendChild(primaryDicts[idx]);
        }
    }

    // Read user settings and set them as html attributes
    function userSettings() {
        const styles = getComputedStyle(document.documentElement);
        const miscInfo = document.querySelector("details:has(.misc-info)");
        const lapis = document.getElementById("lapis");
        const options = [
            "--main-picture-position",
            "--sentence-furigana",
            "--sentence-position",
            "--audio-buttons",
            "--nsfw-blur-contained",
            "--open-misc-info",
            "--glossary-separator",
            "--jitendex-format"
        ];
        for (const opt of options) {
            let value = styles.getPropertyValue(opt);
            value = value.replace(/^['"]|['"]$/g,"").trim().toLowerCase();
            lapis.setAttribute("data-" + opt.slice(2), value);
            if (opt === "--open-misc-info" && value === "on" && miscInfo) {
                miscInfo.open = true;
            }
        }
    }

    // Initialize all functions!!!
    function initialize() {
        addAudioButtons();
        userSettings();
        splitTags();
        handlePitches();
        setUpDefToggle();
        clickImages();
        formatFrequencyList();
        setDHHeight();
        hideCorrectDefinition();
        movePrimaryDicts();
    }

    initialize();
</script>
''';
  static const String css = r''':root {
  /* Color theme */
  --light-mode-bg-color: #fffaf0;
  --light-mode-fg-color: #333333;

  /* Bold color */
  --light-mode-bold: #4660f1;
  --dark-mode-bold: #fffd9e;

  /* PC Font sizes */
  --pc-main-font-size: 16px;
  --pc-main-def-size: 20px;
  --pc-vocab-font-size: 85px;
  --pc-back-vocab-font-size: 60px;
  --pc-sentence-font-size: 52px;
  --pc-back-sentence-font-size: 35px;
  --pc-hint-font-size: 38px;
  --pc-info-font-size: 23px;

  /* Mobile font sizes */
  --mobile-main-font-size: 16px;
  --mobile-main-def-size: 16px;
  --mobile-vocab-font-size: 70px;
  --mobile-back-vocab-font-size: 32px;
  --mobile-sentence-font-size: 38px;
  --mobile-back-sentence-font-size: 24px;
  --mobile-hint-font-size: 24px;
  --mobile-info-font-size: 16px;

  /* Miscellaneous */
  --font-serif: "Hiragino Mincho ProN", "Noto Serif CJK JP", "Noto Serif JP", "Yu Mincho", HanaMinA, HanaMinB, serif;
  --font-sans: "Inter", "SF Pro Display", "Liberation Sans", "Segoe UI", "Hiragino Kaku Gothic ProN", "Noto Sans CJK JP", "Noto Sans JP", "Meiryo", HanaMinA, HanaMinB, sans-serif;
  --light-mode-image-brightness: 85%;
  --dark-mode-image-brightness: 80%;
  --light-mode-tooltip-hover-color: rgb(256, 256, 256, 0.9);
  --dark-mode-tooltip-hover-color: rgba(0, 0, 0, 0.9);
  --def-picture-size: 200px;
  --max-width: 800px;

  /* For an overview of these variables
  See https://github.com/donkuri/lapis/tree/main/docs/user_settings.md */
  --main-picture-position: "right"; /* "right", "left", "alt" */
  --sentence-position: "above"; /* "above", "below" the definition box*/
  --audio-buttons: "header"; /* "header", "fixed", "alt" */
  --sentence-furigana: "hover"; /* "hover", "always", "off" */
  --nsfw-blur-contained: "off"; /* "on", "off" */
  --open-misc-info: "off"; /* "on", "off" */
  --glossary-separator: "off"; /* "on" to separate dictionaries in definition box */
  --jitendex-format: "full"; /* "minimal" or space-separated list of "no-tags", "no-sentence", "no-forms", "no-xref", "no-img" */

  --mobile-main-picture-position: "right"; /* "left", "right", "alt" */
  --mobile-sentence-position: "below";
  --mobile-audio-buttons: "fixed"; /* "fixed", "header", "alt" */

  /* Pitch colors */
  --dark-mode-heiban: #39bae6;
  --dark-mode-atamadaka: #ec464f;
  --dark-mode-nakadaka: #ff8f40;
  --dark-mode-odaka: #6cbf43;
  --dark-mode-kifuku: #af85f4;
  --light-mode-heiban: #1aa0ce;
  --light-mode-atamadaka: #e92a35;
  --light-mode-nakadaka: #ff6b03;
  --light-mode-odaka: #61ad3b;
  --light-mode-kifuku: #7e53c4;

  font-size: var(--main-font-size);
}

.card {
  background-color: var(--bg-color) !important;
  color: var(--fg-color) !important;
}

.card.nightMode {
  --bg-color: var(--canvas, #2c2c2c);
  --fg-color: var(--fg, #fcfcfc);
  --heiban: var(--dark-mode-heiban, initial);
  --atamadaka: var(--dark-mode-atamadaka, initial);
  --nakadaka: var(--dark-mode-nakadaka, initial);
  --odaka: var(--dark-mode-odaka, initial);
  --kifuku: var(--dark-mode-kifuku, initial);

  --bg-elevated: rgba(0, 0, 0, 0.12);
  --bg-inset: rgba(255, 255, 255, 0.03);
  --fg-subtle: rgba(255, 255, 255, 0.3);
  --bold: var(--dark-mode-bold, #7d8590);

  --image-brightness: var(--dark-mode-image-brightness);
  --tooltip-hover-color: var(--dark-mode-tooltip-hover-color);

  /* Code for 明鏡 第三版 by kiwakiwaa
    and can be found here https://github.com/kiwakiwaa/vertical-cards?tab=readme-ov-file#my-yomitan-dictionaries */
  --meikyo-white: #000000;
  --meikyo-black: #cccccc;
  --meikyo-blue: #33ccff;
  --meikyo-red: #ff3333;
  --meikyo-gray: #bbbbbb;
  --meikyo-pink: #cc6666;
  --meikyo-dark-red: #993333;
  --meikyo-fbox-white: #ffffff;
  --meikyo-fbox-gray: #cccccc;
  --meikyo-box-gray: #663333;
  /* Support for oubunsha kogo */
  --ozk5-blue: #00aaff;
  --ozk5-red: #ff6666;
  --ozk5-light-red: #b24747;
  --ozk5-gray: #888;
  --ozk5-hinshi-mark: #cccccc;
  --ozk5-kakomi-border: #888;
  --ozk5-metadata-background: #888;
  --ozk5-example-katsuyou-mark: #aaaaaa;
  --ozk5-mark-border: #acac04;
  --ozk5-gogi-panel-header: #331414;
  --ozk5-ruigo-panel-background: #cccccc;
  --ozk5-ruigo-panel-border: #777;
  --ozk5-appendix-title-background: #bf6666;
  --ozk5-gendai-mark: #cccccc;
  /* --background-color: #1e1e1e; */

  /* Support for sanseido kogo */
  --skogo-blue: #00aaff;
  --skogo-red: #ff6666;
  --skogo-light-red: #a54447;
  --skogo-extra-light-red: #481d1e;
  --skogo-hinshi-mark: #cccccc;
  --skogo-shubetsu-mark: #cccccc;
  --skogo-gendai-mark: #cccccc;
}

.android .nightMode {
  --bg-color: black;
  --fg-color: white;
}

.android .nightMode:not(.ankidroid_dark_mode) {
  /* make it brighter since bg is black */
  --bg-elevated: rgba(255, 255, 255, 0.06);
}

.android .nightMode.ankidroid_dark_mode {
  --bg-color: #303030;
}

.card:not(.nightMode) {
  --bg-color: var(--light-mode-bg-color);
  --fg-color: var(--light-mode-fg-color);
  --heiban: var(--light-mode-heiban, initial);
  --atamadaka: var(--light-mode-atamadaka, initial);
  --nakadaka: var(--light-mode-nakadaka, initial);
  --odaka: var(--light-mode-odaka, initial);
  --kifuku: var(--light-mode-kifuku, initial);

  --bg-elevated: rgba(0, 0, 0, 0.03);
  --bg-inset: rgba(0, 0, 0, 0.06);
  --fg-subtle: rgba(0, 0, 0, 0.6);
  --bold: var(--light-mode-bold, #999999);

  --image-brightness: var(--light-mode-image-brightness);
  --tooltip-hover-color: var(--light-mode-tooltip-hover-color);

  /* Code for 大辞泉 二版 by kiwakiwaa
    and can be found here https://github.com/kiwakiwaa/vertical-cards?tab=readme-ov-file#my-yomitan-dictionaries */
  --daijisen-black: #ffffff;
  --daijisen-white: #000000;
  --daijisen-blue: #00aaff;
  --daijisen-header-djs: #a0484f;
  --daijisen-header-djsp: #7a7a7a;
  --daijisen-header-text: #000000;
  --daijisen-logo-color: #dddddd;
  --daijisen-background-l3: #c0c0c0;
  --daijisen-accent-mark: #ff6666;
  --daijisen-accent-slash: #a0a0a0;

  --ozk5-blue: #4a8ade;
  --ozk5-red: #c00000;
  --ozk5-light-red: #d96666;
  --ozk5-gray: #888;
  --ozk5-hinshi-mark: #444;
  --ozk5-kakomi-border: #999;
  --ozk5-metadata-background: #999;
  --ozk5-example-katsuyou-mark: #666;
  --ozk5-mark-border: #660;
  --ozk5-gogi-panel-header: #f9e6e6;
  --ozk5-ruigo-panel-background: #444;
  --ozk5-ruigo-panel-border: #aaa;
  --ozk5-appendix-title-background: #633;
  --ozk5-gendai-mark: #888;
  /* --background-color: #f5f5f5; */

  --skogo-blue: #4a8ade;
  --skogo-red: #c00000;
  --skogo-light-red: #dfa6a8;
  --skogo-extra-light-red: #ffeeee;
  --skogo-hinshi-mark: #444;
  --skogo-shubetsu-mark: #707070;
  --skogo-gendai-mark: #888;
}

html {
  --main-font-size: var(--pc-main-font-size);
  --main-def-size: var(--pc-main-def-size);
  --vocab-font-size: var(--pc-vocab-font-size);
  --back-vocab-font-size: var(--pc-back-vocab-font-size);
  --sentence-font-size: var(--pc-sentence-font-size);
  --back-sentence-font-size: var(--pc-back-sentence-font-size);
  --hint-font-size: var(--pc-hint-font-size);
  --info-font-size: var(--pc-info-font-size);
}

html.mobile {
  --main-font-size: var(--mobile-main-font-size);
  --main-def-size: var(--mobile-main-def-size);
  --vocab-font-size: var(--mobile-vocab-font-size);
  --back-vocab-font-size: var(--mobile-back-vocab-font-size);
  --sentence-font-size: var(--mobile-sentence-font-size);
  --back-sentence-font-size: var(--mobile-back-sentence-font-size);
  --hint-font-size: var(--mobile-hint-font-size);
  --info-font-size: var(--mobile-info-font-size);
  --main-picture-position: var(--mobile-main-picture-position);
  --sentence-position: var(--mobile-sentence-position);
  --audio-buttons: var(--mobile-audio-buttons);
}

#lapis {
  display: flex;
  align-items: stretch;
  flex-direction: column;
  min-height: calc(100vh - 40px);
  font-family: var(--font-serif);
  font-size: var(--main-font-size);
  text-align: center;
}

/* ------- Mobile css ------- */
@media (max-width: 512px) {
  .images-container {
    justify-content: space-around;
    flex-direction: row !important;
    max-width: 100% !important;
    width: 100%;
    flex-wrap: wrap;
  }

  .images-container img {
    width: 44%;
  }

  .img-popup-container {
    max-width: 100vw;
    max-height: 60vh;
  }

  .img-popup-img {
    object-fit: contain;
  }
}

@media (min-width: 768px) and (max-width: 1024px) {
  .img-popup-container {
    max-height: 70vh;
  }

  .img-popup-img {
    object-fit: contain;
  }
}

/* ----- Front elements ----- */

.front-vocab {
  font-size: var(--vocab-font-size);
  line-height: 1.5;
}

.front-sentence {
  font-size: var(--sentence-font-size);
  display: inline-block;
  line-height: 1.5;
}

#hint {
  font-size: var(--hint-font-size);
  margin-top: -5px;
  line-height: 1.5;
}

#click {
  user-select: none;
}

#click .front-vocab {
  display: inline-block;
  line-height: 1.2;
  margin-bottom: 20px;
  border-bottom: 2px dotted var(--fg-subtle);
}

/* ----- Back elements ----- */

/* Vocab on the back (for mobile) */
.vocab {
  line-height: 1.5;
  font-size: var(--back-vocab-font-size);
}

a {
  color: #3b82f6 !important;
}

.nightMode a {
  color: #93c5fd !important;
}

/* Header */
header {
  color: var(--fg-subtle);
  height: 40px;
  text-align: right;
  width: 100%;
  font-size: 1rem;
}

.top-container {
  font-family: var(--font-sans);
  max-width: calc(var(--max-width) + 20px);
  margin: 0px auto;
  width: calc(100% - 20px);
  fill: var(--fg-subtle) !important;
  position: relative;
  display: inline-block;
}

.freq-dropdown {
  cursor: pointer;
}

.freq-list-container {
  display: none;
  position: absolute;
  top: 100%;
  right: 0;
  background-color: var(--tooltip-hover-color);
  color: var(--fg-color);
  padding: 10px;
  border-radius: 5px;
  z-index: 1000;
  width: 200px;
}

.freq-list-container ul {
  list-style-type: none;
  line-height: 1.5;
  margin: 0;
  padding: 0;
}

.freq-dropdown:hover .freq-list-container {
  display: block;
}

main {
  width: min(var(--max-width), calc(100% - 20px));
  margin-inline: auto;
}

/* Info (audio, reading) */
.info {
  font-family: var(--font-sans);
  font-size: var(--info-font-size, 0.9rem);
  color: var(--fg-color);
}

.mobile .info {
  padding-top: 7px;
}

/* Replay button */
.replay-button svg {
  width: 32px;
  height: 32px;
}

.mobile .audio-buttons {
  position: fixed;
  bottom: 0;
  left: 0;
  z-index: 1000;
}

.audio-buttons-alt {
    font-size: 0;
}

/* Pitch */
.pitch {
  display: inline;
}

#pitch-tags {
  background-color: var(--fg-color);
  color: var(--bg-color);
  font-family: var(--font-sans);
  font-weight: 500;
  display: none;
  vertical-align: top;
  padding: 1px 3px;
  margin-right: -5px;
  &:has(li) {
    display: inline-block;
  }
}

.mobile .nightMode #pitch-tags {
  color: #000 !important;
  background-color: #fff;
}

/* When multiple pitch */
.pitch ul,
#pitch-tags ul {
  list-style: none;
  display: inline;
  margin: 0;
  padding: 0;
}

.pitch li,
#pitch-tags li {
  display: inline;
}

.pitch ul > li:not(:last-child)::after {
  content: "・";
  color: var(--fg-color);
}

#pitch-tags ul > li:not(:last-child)::after {
  content: "・";
  color: var(--bg-color);
  font-size: 0.8em;
}

/* Definition container */
.main-def {
  background-color: var(--bg-elevated);
  font-family: var(--font-sans);
  font-size: var(--main-def-size);
  line-height: 1.75em;
  text-align: left;
  border-left: 5px solid #ccc;
  padding: 0.5em 10px;
  margin: 5px auto 10px auto;
  overflow: hidden;
  position: relative;
}

.main-def ol {
  margin-block: 0em;
}

/* Definition info display */
.def-info {
  font-family: var(--font-sans);
  color: var(--fg-subtle);
  font-size: 0.9rem;
  text-align: right;
  pointer-events: none;
  visibility: hidden;
}

.mobile .def-info {
  margin-bottom: -5px;
}

/* MainDefinition */
.definition {
  text-align: left;
  width: fit-content;
  max-width: 100%;
}

/* Definition toggle css */
.edge {
  position: absolute;
  top: 0;
  width: 50px;
  height: 100%;
  cursor: pointer;
  opacity: 0.4;
}

.edge:hover {
  background-color: var(--bg-inset);
}

#edge-prev {
  left: 0;
  border-radius: 8px 0px 0px 8px;
}

#edge-next {
  right: 0;
  border-radius: 0px 8px 8px 0px;
}

/* Hide edges when not needed */
.edge:has(~ .definition > :last-child:first-child) {
  display: none;
}

/* Primary Image */
.image img, .image-alt img {
  max-height: 400px;
  width: auto;
  border-radius: 5px;
  cursor: pointer;
  transition: filter 0.3s;
}

.image-alt img {
  margin: auto;
  max-width: 60%;
  max-height: 250px;
  border: solid var(--fg-subtle) 2px;
  font-size: 0;
}

.image img:hover,
.image-alt img:hover,
.def-image img:hover {
  filter: brightness(var(--image-brightness));
}

/* Definition Image(s) */
.def-image {
  float: right;
  margin-left: 10px;
  max-width: min(35%, var(--def-picture-size));
  display: flex;
  flex-flow: column nowrap;
  justify-content: flex-start;
  gap: 10px;
}

.def-image img {
  object-fit: contain;
  max-height: var(--def-picture-size);
  border-radius: 3px;
  cursor: pointer;
  transition: filter 0.3s;
}

.def-image ol {
  list-style-type: none;
  padding: 0;
  margin: 0;
}

/* Image modal css */
.modal-bg {
  position: fixed;
  top: 0;
  right: 0;
  bottom: 0;
  left: 0;
  background-color: rgba(0, 0, 0, 0.8);
  z-index: 1000;
  cursor: pointer;
  opacity: 0;
  visibility: hidden;
  transition:
    opacity 0.3s ease,
    visibility 0.3s ease;
}

.modal-bg.active {
  opacity: 1;
  visibility: visible;
}

.img-popup-container {
  position: absolute;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  width: min(calc(100% - 20px), calc(var(--max-width) + 200px));
  z-index: 1001;
  overflow: hidden;
  display: flex;
  opacity: 0;
  visibility: hidden;
  transition:
    opacity 0.3s ease,
    visibility 0.3s ease;
}

.img-popup-container.active {
  opacity: 1;
  visibility: visible;
}

.img-popup-img {
  width: auto;
  height: auto;
  margin: 0 auto;
  transition: transform 0.3s ease;
}

/* Hide NFSW Images -- make sure you use the tag `NSFW` EXACTLY */
.NSFW img,
.nsfw img,
.Nsfw img {
  filter: blur(30px);
  transition: filter 0.2s;

  &:hover {
    filter: blur(0px);
  }
}

/* Back sentence */
.sentence,
.sentence-alt {
  line-height: 1.5;
  font-size: var(--back-sentence-font-size);
  display: inline-block;

  /* show furigana on hover */
  & rt {
    visibility: hidden;
  }

  & ruby:hover rt {
    visibility: visible;
  }
}

/* Footer */
footer {
  margin-top: auto;
  width: 100%;
}

.bot-container {
  display: flex;
  justify-content: flex-end;
  max-width: calc(var(--max-width) + 20px);
  margin: 0px auto;
  width: calc(100% - 20px);
}

.tags-container {
  flex-grow: 1;
}

.tags-container .tags {
  min-height: 1.6em;
}

.tags {
  font-family: var(--font-sans);
  background-color: var(--bg-elevated);
  color: var(--fg-color);
  display: inline-grid;
  place-items: center;
  padding: 1px 5px;
  cursor: pointer;
  border-radius: 5px;
  font-size: 0.9rem;
  margin: auto 3px;
  text-overflow: ellipsis;
  overflow: hidden;
  max-width: 60dvw;
  white-space: nowrap;
}

.mobile .tags {
  padding: 1px 3px;
  font-size: 9px;
}

/* Definition Header */
.def-header {
  display: flex;
  font-size: 30px;
  justify-content: center;
  align-items: center;
  max-width: 820px;
  margin-inline: auto;
  position: relative;
  gap: min(20px, 2vw);
}

.dh-vocab {
  background: var(--bg-elevated);
  padding: 0.52em;
  border-radius: 5px;
  flex: 1;
  /* takes up all available space */
}

.dh-image {
  max-width: 400px;
  position: relative;
  font-size: 0;
  /* weird hack needed to make the image stay in line with the .def-header */
}

.mobile .dh-vocab {
  background: none;
  padding: 0em;
  border-radius: 0px;
}

.mobile .dh-vocab:has(~ .dh-image) {
  max-width: 60vw;
}

.mobile .dh-image {
  max-width: 40vw;
}

/* Misc. info */
.misc-info {
  font-family: var(--font-sans);
  background-color: var(--bg-elevated);
  border-radius: 8px;
  padding: 10px;
  margin: 0 auto;
}

.misc-info ul {
  margin: 0;
}

/* ----- Misc ----- */

/* Furigana */
ruby rt {
  user-select: none;
}

/* Bold */
b {
  color: var(--bold);
  font-weight: 600;
}

.mobile b {
  font-weight: 400;
}

/* Hide scrollbar */
.card {
  -ms-overflow-style: none;
  scrollbar-width: 0;

  &::-webkit-scrollbar {
    display: none;
  }
}

/* Dropdown */
details {
  font-family: var(--font-sans);
  margin: 5px 0px;
}

summary {
  user-select: none;
  cursor: pointer;
  margin: 0px auto;
}

/* Pitch overline */
.pitch-item>span {
    position: relative;
    white-space: nowrap;
}

.pitch-line {
    display: block;
    position: absolute;
    top: -0.1em;
    left: 0;
    right: 0;
    border-width: 0.1em;
    border-top-style: solid;
}

.pitch-low>.pitch-line {
    border-top-style: none;
}

.pitch-to-drop {
    padding-right: 0.1em;
    margin-right: 0.1em;
    &>.pitch-line {
        height: 0.4em;
        right: -0.1em;
        border-right-style: solid;
    }
}

/* Pitch coloring */
.heiban {
  color: var(--heiban);
}

.atamadaka {
  color: var(--atamadaka);
}

.nakadaka {
  color: var(--nakadaka);
}

.odaka {
  color: var(--odaka);
}

.kifuku {
  color: var(--kifuku);
}

/* Format Definitions */
ul[data-sc-content="glossary"],
[data-sc-content="forms"] ul,
[data-dictionary^="JMdict"] ul:not([data-sc-content]) {
    display: inline;
    list-style: none;
    padding-left: 0!important;

    &>li:not(:first-child)::before {
        white-space: pre-wrap;
        content: " | ";
        display: inline;
    }

    & > li {
        display: inline;
    }
}

[data-sc-content="glossary"] ~ ul,
[data-sc-content="glossary"] ~ div {
  line-height: normal;
}

[data-sc-content="attribution"],
[data-sc-content="graphic-attribution"] {
  display: none;
}

/* reduce indentations of Jitendex for mobile */
.mobile li[data-dictionary^="Jitendex"] ul,
.mobile li[data-dictionary^="Jitendex"] ol,
.mobile li[data-details^="Jitendex"] ul,
.mobile li[data-details^="Jitendex"] ol {
  padding-left: 0.3em;
}

/* Turn off italics */
.definition i {
  font-style: normal;
}

li[data-dictionary^="JMdict"] i {
  font-style: italic;
}

.definition a span {
  max-width: 300px !important;
}

.definition .hidden {
  display: none;
}

/* Prevent wrapping in the middle of a Jitendex tags */
span[data-sc-code] {
  white-space: nowrap;
}

/* backwards compatibility code for JPMN definitions */
li[data-details="JMdict (English)"] .dict-group__glossary > ul,
li[data-details="JMdict (English)"]
  .dict-group__glossary
  ul[data-sc-content="glossary"],
li[data-details="JMdict"] .dict-group__glossary > ul,
li[data-details="JMdict"] .dict-group__glossary ul[data-sc-content="glossary"],
li[data-details="JMdict Extra"] .dict-group__glossary > ul,
li[data-details="JMdict Extra"]
  .dict-group__glossary
  ul[data-sc-content="glossary"] {
  display: inline;
  padding-left: 0em;
}

li[data-details="JMdict (English)"] .dict-group__glossary > ul > li,
li[data-details="JMdict (English)"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li,
li[data-details="JMdict"] .dict-group__glossary > ul > li,
li[data-details="JMdict"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li,
li[data-details="JMdict Extra"] .dict-group__glossary > ul > li,
li[data-details="JMdict Extra"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li {
  display: inline;
  padding-right: 0em;
  margin-right: 0em;
}

li[data-details="JMdict (English)"] .dict-group__glossary > ul > li::after,
li[data-details="JMdict (English)"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li::after,
li[data-details="JMdict"] .dict-group__glossary > ul > li::after,
li[data-details="JMdict"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li::after,
li[data-details="JMdict Extra"] .dict-group__glossary > ul > li::after,
li[data-details="JMdict Extra"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li::after {
  content: " | ";
  white-space: pre-wrap;
}

li[data-details="JMdict (English)"]
  .dict-group__glossary
  > ul
  > li:last-of-type:after,
li[data-details="JMdict (English)"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li:last-of-type:after,
li[data-details="JMdict"] .dict-group__glossary > ul > li:last-of-type:after,
li[data-details="JMdict"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li:last-of-type:after,
li[data-details="JMdict Extra"]
  .dict-group__glossary
  > ul
  > li:last-of-type:after,
li[data-details="JMdict Extra"]
  .dict-group__glossary
  ul[data-sc-content="glossary"]
  > li:last-of-type:after {
  display: none;
}

/*
 * customization for specific dictionaries
 */
/* Makes JMdict italic */
ol li[data-details="JMdict (English)"] .dict-group__tag-list,
ol li[data-details="JMdict"] .dict-group__tag-list,
ol li[data-details="JMdict Extra"] .dict-group__tag-list {
  font-style: italic;
}

/* removes the dictionary entry for jmdict */
ol
  li[data-details="JMdict (English)"]
  .dict-group__tag-list
  .dict-group__tag--dict,
ol li[data-details="JMdict"] .dict-group__tag-list .dict-group__tag--dict,
ol
  li[data-details="JMdict Extra"]
  .dict-group__tag-list
  .dict-group__tag--dict {
  display: none;
}

/* Makes Nico/Pixiv italic */
ol li[data-details="Nico/Pixiv"] .dict-group__tag-list {
  font-style: italic;
}

/* Removes the extra text for the collapsed 新和英 display */
ol
  li[data-details="新和英"]
  details.glossary-text__details
  .glossary-text__summary
  .dict-group__glossary--first-line {
  display: none;
}

/*
 * --------------------
 *  dictionary entries
 * --------------------
 */
.dict-group__tag-list .dict-group__tag:not(:first-child)::before {
  content: ", ";
}

.dict-group__tag-list::before {
  content: "(";
}

.dict-group__tag-list::after {
  content: ") ";
}

.definition ol:has(> li[data-dictionary]),
.definition ol:has(> li[data-details]) {
  padding-inline-start: 1.3em;
}

/* Removes list numbering when only one list element  */
.definition ol:has(> li[data-dictionary]:only-of-type),
.definition ol:has(> li[data-details]:only-of-type) {
  list-style-type: none;
  padding-inline-start: 0;
}

/* Better formatting meikyo 3rd edition */
li[data-dictionary="明鏡国語辞典 第三版"] span {
  width: 25em !important;
  vertical-align: bottom !important;
}

li[data-dictionary="明鏡国語辞典 第三版"]
  div:has(> span[data-sc-class="品格"]) {
  margin-bottom: 5px !important;
}

li[data-dictionary="明鏡国語辞典 第三版"] [data-sc-body] {
  font-size: var(--main-def-size) !important;
}

/* Formatting for sanseido kogo dict */
li[data-dictionary="三省堂 全訳読解古語辞典"] span[data-sc-body] {
  line-height: 1.4em;
}
[data-dictionary="三省堂 全訳読解古語辞典"] span[data-sc-rectr][data-sc-fill] {
  color: #f5f5f5 !important;
}
.nightMode
  [data-dictionary="三省堂 全訳読解古語辞典"]
  span[data-sc-rectr][data-sc-fill] {
  color: #1e1e1e !important;
}

/* Formatting for oubunsha kogo dict */
li[data-dictionary="旺文社 全訳古語辞典"] [data-sc-audio_play_button],
li[data-dictionary="旺文社 全訳古語辞典"] [data-sc-audio_stop_button] {
  display: none !important;
}
li[data-dictionary="旺文社 全訳古語辞典"] div[data-sc用例囲み-g],
li[data-dictionary="旺文社 全訳古語辞典"] div[data-sc和歌俳句囲み-g],
li[data-dictionary="旺文社 全訳古語辞典"] div[data-sc冒頭文囲み-g],
li[data-dictionary="旺文社 全訳古語辞典"] div[data-sc小倉囲み-g] {
  margin-top: 0 !important;
}
[data-dictionary="旺文社 全訳古語辞典"] span[data-sc-rectr][data-sc-fill] {
  color: #f5f5f5 !important;
}
.nightMode
  [data-dictionary="旺文社 全訳古語辞典"]
  span[data-sc-rectr][data-sc-fill] {
  color: #1e1e1e !important;
}

/* Default Layouts */
html.mobile .sentence, html:not(.mobile) .sentence-alt,
.audio-buttons-alt, .image-alt {
  display: none;
}

/*
 *  USER SETTINGS
 *  Please modify the variables at the top of the file.
 */
/* Layout changes */
#lapis[data-main-picture-position="left"] .def-header {
  flex-flow: row-reverse;
}

#lapis[data-main-picture-position="alt"] .dh-image,
#lapis[data-audio-buttons="alt"] .audio-buttons,
#lapis[data-sentence-position="above"] .sentence-alt,
#lapis[data-sentence-position="below"] .sentence {
  display: none;
}

#lapis[data-main-picture-position="alt"] .image-alt,
#lapis[data-audio-buttons="alt"] .audio-buttons-alt,
#lapis[data-sentence-position="above"] .sentence,
#lapis[data-sentence-position="below"] .sentence-alt {
  display: block;
}

/* Audio Buttons Settings */
#lapis[data-audio-buttons="fixed"] .audio-buttons {
  position: fixed;
  bottom: 0;
  left: 0;
  z-index: 1000;
}

#lapis[data-audio-buttons="header"] .audio-buttons {
  position: static;
}

/* Other Settings */
#lapis[data-sentence-furigana="always"] .sentence rt,
#lapis[data-sentence-furigana="always"] .sentence-alt rt {
  visibility: visible;
}

#lapis[data-sentence-furigana="off"] .sentence rt,
#lapis[data-sentence-furigana="off"] .sentence-alt rt {
  display: none;
}

#lapis[data-nsfw-blur-contained="on"] .NSFW,
#lapis[data-nsfw-blur-contained="on"] .nsfw,
#lapis[data-nsfw-blur-contained="on"] .Nsfw {
  overflow: hidden;
}

#lapis[data-glossary-separator="on"] .definition {
  & li[data-dictionary]:not(:last-of-type),
  & li[data-details]:not(:last-of-type) {
    border-bottom: 1px dashed var(--fg-subtle);
  }
}

#lapis[data-jitendex-format~="minimal"] .definition [data-sc-content]:not([data-sc-content="glossary"]),
#lapis[data-jitendex-format~="no-sentence"] .definition [data-sc-content|="example-sentence"],
#lapis[data-jitendex-format~="no-forms"] .definition [data-sc-content="forms"],
#lapis[data-jitendex-format~="no-xref"] .definition [data-sc-content|="xref"],
#lapis[data-jitendex-format~="no-img"] .definition [data-sc-content|="graphic"] {
  display: none;
}

#lapis[data-jitendex-format~="minimal"] .definition,
#lapis[data-jitendex-format~="no-tags"] .definition {
  & [data-sc-code] {
    display: none;
  }
  & ul {
    padding-inline-start: 0px;
    margin-block: 0px;
    & > li::marker {
      content: "";
    }
  }
}
''';

  static const AnkiNoteTypeTemplate template = AnkiNoteTypeTemplate(
    name: modelName,
    fields: fields,
    cardName: cardName,
    front: front,
    back: back,
    css: css,
  );
}
