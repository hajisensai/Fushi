# دليل Fushi الذي يمكن حتى ليوي هيراساوا إعداده في 5 دقائق

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | **العربية**

> دليل الصينية المبسّطة مُستضاف على Feishu (الرابط أعلاه). الدليل الإنجليزي متوفّر أيضًا [على GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md).

## مقدمة

‏**Fushi — حوّل القراءة بنهم والمشاهدة بنهم إلى مُدخلات لغوية.**

اضغط على أي كلمة للبحث عنها أثناء قراءة الروايات أو مشاهدة الأنمي أو الاستماع إلى الكتب الصوتية، وأرسل الكلمات الجديدة إلى Anki مع الجملة التي وردت فيها.

لا توجد قوائم كلمات جاهزة — أنت تراجع فقط الكلمات التي صادفتها فعلًا. يعمل مع أي لغة.

- 📖 قراءة EPUB · اضغط للبحث عن الكلمة
- 🎧 كتب صوتية مع تمييز جملةً بجملة
- 🎬 البحث في ترجمات الفيديو وإنشاء البطاقات
- 🃏 إنشاء بطاقات Anki بضغطة واحدة + إحصاءات المراجعة
- 📚 قراءة المانغا · ابحث عن الكلمات مباشرةً من الصفحة عبر OCR
- ⬇️ تنزيل الأنمي والمانغا داخل التطبيق بضغطة واحدة — تُضاف تلقائيًا إلى مكتبتك، ويمكن تشغيلها أثناء التنزيل
- 🎮 استخراج أصوات Galgame (‏Windows) · يدخل المقطع الصوتي الأصلي إلى البطاقة مع النص

المنصّات: ‏Android / Windows / macOS / iOS (يمكن بناء Linux من المصدر؛ لا توجد حزم جاهزة بعد)

### رابط المشروع

https://github.com/hajisensai/Fushi

قيد التطوير النشط — ستُعالَج ملاحظاتك على الفور. نرحّب بتقارير الأخطاء وطلبات الميزات. إذا وجدت Fushi مفيدًا، فسنكون ممتنّين إذا شاركته مع الآخرين أو منحت المستودع نجمة ⭐.

### التنزيل

https://github.com/hajisensai/Fushi/releases/latest

اختر الملف المناسب لمنصّتك: **Android** — حزمة APK بصيغة `arm64-v8a` (تستخدمها جميع الهواتف الصادرة في السنوات الأخيرة؛ الأجهزة الأقدم وحدها تحتاج إلى `armeabi-v7a`، والمحاكيات تستخدم `x86_64`)؛ **Windows** — `windows-setup.exe`؛ **macOS** — `macos.zip`؛ **iOS** — `ios.ipa`. أما **Linux** فلا تتوفّر له حزمة جاهزة بعد، لذا يجب بناؤه من المصدر.

ملفات APK التي تبدأ أسماؤها بـ `bridge-` هي جسور ترحيل لـ**مستخدمي Hibiki القديم**؛ يمكنك تجاهلها.

## دليل الإعداد

### 1. استيراد القواميس المُوصى بها (قواميس الكلمات + النبر الصوتي + التكرار) والصوت المحلي (قاعدتا بيانات صوتية لليابانية والإنجليزية) (يُوصى به بشدة للمبتدئين!!! · اختياري)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [التنزيل عبر Cloudflare (‏9.5 غيغابايت)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

داخل التطبيق: الإعدادات -> المزامنة والنسخ الاحتياطي -> اضغط على **استيراد نسخة احتياطية**.

![شاشة استيراد النسخة الاحتياطية](static-assets/user-guide/import-backup.png)

### 2. تنزيل Anki وإعداده من موقع Anki الرسمي

‏Anki — المُسمّى نسبةً إلى 暗記 (あんき) — هو [نظام التكرار المتباعد (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) الأكثر استخدامًا في العالم، وأداة مهمة جدًا.

الروابط: [موقع Anki الرسمي](https://apps.ankiweb.net/) · [الدليل (بالصينية)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [الأسئلة الشائعة](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(بالصينية)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![صفحة تنزيل Anki](static-assets/user-guide/anki-download.png)

يمكنك أن تعطي Anki أي مادة تريد حفظها، فيتيح لك تحقيق أفضل احتفاظ بالمعلومات بأقل وقت دراسة.

يحتوي Anki على [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) مدمجًا — أحد أفضل خوارزميات التكرار المتباعد في العالم.

**لكن!!!** الخوارزمية الافتراضية في Anki هي SM2، وهي خوارزمية عمرها أكثر من 30 عامًا وأداؤها ضعيف. يُرجى التأكد من تبديل الخوارزمية التي يستخدمها Anki إلى **FSRS**.

#### Anki

##### Android

1. ثبّت Anki وافتحه.
2. عُد إلى Fushi، وانتقل إلى الإعدادات -> إنشاء البطاقات.
3. اضغط على **تحديث المجموعات وأنواع الملاحظات** (المُعلَّمة بـ "1" في الصورة)؛ سيطلب Fushi إذنًا — اضغط على السماح.
4. اضغط على **إنشاء مجموعة Lapis** (المُعلَّمة بـ "2" في الصورة).
5. إذا لم يظهر أي تحذير أو خطأ باللون الأحمر، فقد نجح الإعداد.

![إعداد Anki على Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. ثبّت Anki وافتحه.
2. انقر على **أدوات (Tools)** في أعلى اليسار.

![قائمة أدوات Anki على Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. الصق رمز إضافة Anki أدناه لتثبيتها: `2055492159`
4. عُد إلى Fushi، وانتقل إلى الإعدادات -> إنشاء البطاقات.
5. اضغط على **تحديث المجموعات وأنواع الملاحظات** (المُعلَّمة بـ "1").
6. اضغط على **إنشاء مجموعة Lapis** (المُعلَّمة بـ "2").
7. إذا لم يظهر أي تحذير أو خطأ باللون الأحمر، فقد نجح الإعداد.

![إعداد Anki على Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. تصفّح خيارات التهيئة في الإعدادات وتحقّق مما إذا كان هناك شيء ترغب في تعديله. (اختياري)

حان وقت الانغماس في اللغة.

## الميزات المُوصى بها

### البحث عن الكلمات خارج التطبيق

‏**Android:** حدّد كلمة، ثم اضغط على **ترجمة** أو **Fushi** في قائمة التحديد.

‏**Windows:** حدّد كلمة، ثم اضغط **Ctrl+Alt+D** (يمكن تغيير الاختصار من الإعدادات -> الاختصارات).

### البحث من الحافظة

يُبحث تلقائيًا عن كل ما تنسخه. يتوفّر وضعان للعرض — **اللوحة العائمة** و**نافذة النص الشفافة** — وكلاهما قابل للتهيئة من الإعدادات -> البحث.

### البحث في المتصفّح / استخراج ترجمات خدمات البث (‏Netflix)

ثبّت إضافة المتصفّح من الصفحة الرئيسية لـ Fushi.

## شكر وتقدير

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
