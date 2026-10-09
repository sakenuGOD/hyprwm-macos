# native_hooks: механизмы самой macOS 26, на которые можно опереться вместо обходов

Статус: статический разбор, 2026-10-09. macOS 26.7.1 (25G241), arm64e.
Режим: только чтение. lldb не запускал, к процессам не подключался, код проекта не менял, в канал и сокет демона
не писал. Единственный записанный файл — этот.

Источники:
- `cache/sl_dis.txt`, `cache/sl_syms.tsv` (SkyLight);
- полный листинг AppKit, сделанный для этой работы: `ipsw dsc disass --image AppKit` → `/tmp/nh/ak_dis.txt`,
  5 млн строк, временный файл;
- отдельные функции QuartzCore, AppKit, WindowManagement через `ipsw dsc disass --vaddr/--symbol`
  по `dyld_shared_cache_arm64e`;
- `nm` и `strings` по `extracted/{QuartzCore,appkit/AppKit,wm/WindowManagement,wmapp/WindowManager}`;
- исходник hyprutils `cache/hyprutils-src/src/animation/Spring.cpp`;
- `codesign` по приложениям из `/Applications`.

Метки:
- **[V]** — видно в листинге или исходнике, адрес указан;
- **[H]** — гипотеза, указано, как проверить.

Адреса статические, в живом процессе к ним прибавляется slide.

Опираюсь на уже сделанные разборы и не повторяю их: `compositor.md`, `beyond_bounds.md` (locked bounds, freeze,
«невидимая широкая тень»), `decor_v2.md` (z-порядок, тег 3), `close_clone.md` (клон по 0x3ea/0x3e9),
`windowctl.md`, `resize_re.md`, `exotic.md`.

---

## 0. Главный разрыв и что делать в первую очередь

**Главный разрыв.** Геометрию окна мы анимируем внутри WindowServer, а содержимое окно получает от приложения
через AX, позже и в непредсказуемый момент: от 30 до 500 мс, на каждое окно по-разному. Поэтому смена старого
буфера на новый всегда приходится на середину хода, и каждый обход (обрезка, заливка полосы, «сжатие сразу или
в конце», снимок) лишь прячет этот скачок по-разному. Сама macOS 26 так не делает. Её тайлинг просит приложение
изменить размер через особый канал, и AppKit сам меняет рамку и перерисовывает окно в одном CA-коммите. Новое
окно AppKit рисует до вывода на экран.

У нас уже есть всё, чтобы пойти тем же путём: свой код внутри WS (движок) и внутри приложений (модуль
hyprforce, согласие пользователя есть). Не хватает связи между ними. Нашлись системные механизмы, которые эту
связь дают без AX, без файлов и без ограничений песочницы.

**Что делать первым (по порядку):**
1. **Configure через систему, а не через AX** (§1). Движок в WS в момент старта события отправляет
   приложению-владельцу окна конечную рамку штатным уведомлением WS
   (`WSPostNotificationToConnection` 0x186e7430c). Модуль в приложении применяет её родным путём AppKit
   `-[NSWindow _resizeFromWindowManagerWithTargetGeometry:springSettings:completion:]` (0x1857476c4) — так
   рамку окну меняет сама macOS 26. Это заменяет `_cfg_many`/`ax_frame` (3 синхронных AX-вызова на окно) и
   очередь потоков. Цель: одна волна, детерминированный момент configure, коммит рамки и содержимого вместе.
2. **Configure до показа для новых окон** (§2). Модуль ловит `NSWindowWillOrderOnScreenNotification`.
   AppKit рассылает его до вывода окна на сервер и после этого сам рисует содержимое (`displayIfNeeded`). Если
   в обработчике поставить рамку плитки (взять её синхронно из свойства соединения WS), первый кадр окна уже
   будет размера плитки. Это заменяет `F_WAIT`, prehide и `hide_newbies`/`optimistic` и убирает прыжок
   растянутого popin. Так поступает Hyprland (`predictSizeForNewTiledTarget` до map).
3. **Всё, что не геометрия, отдать CoreAnimation в момент рендера** (§3): прозрачность, кроссфейды рамки и
   тени, масштаб popin/закрытия в пределах рамки. Пружина CA математически та же, что hyprutils [V]. А вот
   перемещение и размер обязаны оставаться в серверной модели (наш трансформ или настоящая рамка окна): область
   рисования WS считает по `win+0x498`, а не по представлению CA [V]. Слои оформления — с `autoresizingMask`:
   тогда их подгоняет сам CA в той же транзакции, где WS ставит размер окна [V].
4. **Минимумы окна — из системы, а не выучкой** (§4): `NSWindowAlwaysUpdateTilingConstraints` в приложениях
   и `WSWindowGetPackagesData` в WS либо прямо `minSize`/`resizeIncrements` из модуля. Это заменяет
   `minsize_app.json` с ложными минимумами (Terminal 455/448, Ghostty на весь экран) и вторые волны от
   `configured()`.
5. Запасной путь для окон без модуля и для медленных приложений (Word 350–500 мс) — `beyond_bounds.md`:
   locked bounds и заморозка содержимого. Для жалобы «окно стирается при свайпе» есть отдельная нить: WS
   сплющивает окна во время свайпа (§5), это проверяется одним флагом.

Честная оговорка: ни один пункт не проверен вживую — это статический разбор. Порядок проверок — в §7.

---

## 1. Configure через систему: WS → приложение → AppKit (главное)

### 1.1 Как macOS 26 сама меняет размер чужого окна [V]

Отправитель — WindowManager.app. Он шлёт приложению `_WMClientResizeWindowRequest` по BSService
(`resize_re.md` ★★★). В приложении путь такой:

1. Запрос принимает `-[WMClientWindowManager performResizeWindowRequest:]` 0x27ccf423c (WindowManagement.framework).
2. Затем `-[NSWMWindowCoordinator clientWindowManager:performResizeWindowRequest:]` 0x18590b688.
   Он ставит блок на главный runloop: `CFRunLoopPerformBlock` @0x18590b714 + `CFRunLoopWakeUp` @0x18590b71c.
3. Блок 0x18590b75c:
   - `_windowWithWindowIdentifier:` @0x18590b80c;
   - `targetGeometry`, `springSettings`;
   - `-[NSWindow _resizeFromWindowManagerWithTargetGeometry:springSettings:completion:]` @0x18590b8a8.
4. Ответ WindowManager приходит в транзакции `performTransactionUsingBlock:` с fence (блок 0x18590b96c, @0x18590ba2c).

**Что делает сам метод** — `-[NSWindow _resizeFromWindowManagerWithTargetGeometry:springSettings:completion:]`
0x1857476c4:
- `_stopWindowManagerResizeAnimation` @0x185747708: новый запрос снимает предыдущий, то есть ретаргет встроен.
- `geometryType`: 1 = рамка, 2 = только размер.
- `_confirmSize:force:` @0x185747750 / @0x185747788: AppKit сам применяет свои ограничения (минимум, шаг размера).
- `contentsGravity` (jump table @0x1857477fc) — к какому краю прижимать при смене размера.
- Подгонка под `screen.visibleFrame` @0x185747990.
- **Если `springSettings == nil`:** сразу `_setFrameCommon:display:NO fromServer:NO` @0x185747bb8 и
  `completion(YES)` @0x185747bcc. Это мгновенный configure.
- **Если пружина есть** (@0x185747a30…b68):
  - `NSSpringAnimation initWithDuration:1` с `setAnimationCurve:3`;
  - `setMass/setStiffness/setDamping/setVelocity(initialVelocity)` из настроек;
  - `durationForEpsilon:` → `setDuration:`;
  - `_setSendProgressAllTheTime:YES`, `setAnimationBlockingMode:1`;
  - `_startLiveResize` @0x185747adc;
  - обработчик прогресса — блок 0x185747c7c;
  - `startAnimation`; анимация запоминается в `_auxiliaryStorage.windowManagerResizeAnimation` @0x185747b7c.
- **Блок прогресса** 0x185747c7c на каждом шаге берёт `currentValue` (@0x185747d80), считает
  `frame = start + (target − start)·value` (`fmadd` @0x185747da4…dc4) и вызывает
  `_setFrameCommon:display:NO fromServer:NO` (@0x185747e2c).
  В конце — `_endLiveResize` @0x185747d44 и `completion`.

**Чем движется анимация:**
- `NSSpringAnimation` — это `NSAnimation` + внутренний `CASpringAnimation`:
  - `initWithDuration:` @0x185a66f88: `[CASpringAnimation new]` в ivar `_animation`;
  - `currentValue` 0x185a670bc → `[CASpringAnimation _solveForInput:currentProgress]`.
- `NSAnimation` продвигается по display link главного экрана:
  - `_displayLinkProvider` → `NSScreen.screens.firstObject` (0x1851c6f34);
  - `-[NSAnimation _advanceTimeWithDisplayLink:]` 0x1851c7508:
    `progress = clamp((link.timestamp − startTime)/duration)` @0x1851c754c…756c, где startTime — поле
    `+0x28`, и `setCurrentProgress:` внутри `_NSPerformVisuallyAtomicChange` @0x1851c75c0;
  - затем `[CATransaction flush]` (блок 0x1851c7624).
- `_NSPerformVisuallyAtomicChange` 0x184a36274 = `[CATransaction begin]` → блок → `commit`. Новая рамка уходит
  одним CA-коммитом.
- Время старта можно задать снаружи: `-[NSAnimation _setStartTime:]` 0x1851c6758 = `str d0, [x0, #0x28]`.

**Математика пружины совпадает с Hyprland.** Подробно — в §3.1. Коротко: `CA::Render::SpringAnimation`
(QuartzCore 0x18a90de54 / 0x18a6371cc) — то же аналитическое решение затухающего осциллятора, что
hyprutils `advanceSpring`. При mass 1, stiffness 210, damping 24 это кривая drift.

**Часы общие [V]:**
- `SLSCurrentRealTime` 0x186d8b4d8 = `mach_absolute_time` × масштаб;
- `CACurrentMediaTime` 0x18a604f74 = `mach_absolute_time` → `CATimeWithHostTime`.

Значит, одно число t0 годится и для `te` движка, и для startTime анимации в приложении. [H — что
`CADisplayLink.timestamp` в той же шкале, что `CACurrentMediaTime`: это так по документации Apple, но в листинге
не прослеживал.]

### 1.2 Канал WS → приложение без AX и без файлов [V]

- **Асинхронный толчок.** `WSPostNotificationToConnection(CGXConnection* conn, u32 type, void* data, u32 len)`
  0x186e7430c: собирает датаграмму `{type, seq, 0, data}` и пишет её в канал уведомлений соединения
  (`WSConnectionWriteNotifyDatagram` @0x186e7438c). Фильтра по типу нет, ответа не ждёт. Этим же путём WS
  шлёт приложениям configure полноэкранного тайла (тип 0x528, `resize_re.md` §2).
  У клиента `SLSRegisterConnectionNotifyProc(cid, cb, type, ctx)` 0x18703f36c регистрирует колбэк на тип.
  Белого списка типов при регистрации не видно (@0x18703f3a0…3c0: `CGSConnectionGetNotifier` →
  `CGSConnectionNotifierAddCallback`).
- **Синхронное чтение.** `CGXSetConnectionProperty(u32 cid, CFStringRef key, CFTypeRef value)` 0x186f54760
  кладёт значение в словарь свойств соединения (`CFDictionarySetValue` @0x186f54844). Несколько
  зарезервированных ключей сравниваются через `CFEqual` @0x186f547c0…80c. Клиент читает
  `SLSCopyConnectionProperty` 0x18703da20 → `__XGetConnectionProperty` 0x1871ab424 → `get_connection_property`
  @0x1871ab4e4. Проверки прав в этом пути не увидел; есть только проверки размера сообщения @0x1871ab460.
- Оба канала идут по соединению с WS, которое есть у любого GUI-процесса. Песочница их не ограничивает:
  Telegram, Word и TextEdit в песочнице, но это их собственное соединение с WS. Файлы в контейнере и
  `mach-lookup` не нужны.

### 1.3 Как опереться

**Движок (`anim4.c`), в момент публикации пачки (тот же тик, тот же t0):**
- Для каждого окна, у которого меняется размер:
  `WSPostNotificationToConnection(*(win+0x30), HYPR_CFG, {wid, rect, t0, mode, k, d, m, seq}, len)`.
- Для новых окон заранее: `CGXSetConnectionProperty(cid_приложения, CFSTR("hyprwm.next"), rect)`.

**Модуль (`hyprforce.m`):**
- Регистрирует `SLSRegisterConnectionNotifyProc(SLSMainConnectionID(), cb, HYPR_CFG, 0)`.
- В колбэке — на главный поток (как делает сам AppKit для WindowManager), затем окно по `windowNumber`:
  - **режим «как Hyprland»** (по умолчанию): `_resizeFromWindowManagerWithTargetGeometry:` с
    `+[_WMResizeTargetGeometry targetGeometryWithFrame:contentsGravity:]` (0x27cce8568, gravity 2 = left, как
    шлёт сама система), `springSettings:nil`, `completion:^{}`. Конечный размер — один раз, сразу. Движок, как
    сейчас, показывает старый буфер 1:1 в боксе B, пока не увидит коммит нового размера (bbox `win+0x170` /
    `GetLastChangeDataForContext`);
  - **режим «живой» (как тайлинг macOS 26)**: с `-[_WMSpringAnimationSettings initWithMass:stiffness:damping:epsilon:]`
    = 1/210/24/0.001. После вызова — `[aux.windowManagerResizeAnimation _setStartTime:t0]`, чтобы все окна
    шли от общего t0. Приложение само ведёт свою рамку по пружине и перерисовывается каждый кадр.

**Что это заменяет:**
- `hyprwm.py` `_cfg_many`/`configure` (3 AX-вызова на окно и опрос 30 мс до 0.6 с), `self.cfg_final`,
  `SHRINK_LATE`/`SHRINK_SNAP`/`SNAP`;
- `hold_max 0.2` — в режиме «как Hyprland» ожидание остаётся, но становится коротким и детерминированным;
- вторые волны (минимум применяет сам AppKit в `_confirmSize:force:` до коммита — см. §4).

**Чем лучше AX:**
- нет трёх синхронных IPC из демона;
- нет порядка «окно за окном» внутри приложения;
- configure уходит из того же тика, что и старт движения, — одна волна, A1;
- рамка ставится тем же путём AppKit, каким её ставит система, а не через AX-обёртку `setFrame`.

**Риски и неизвестное:**
- [H] **Время перерисовки самого приложения не исчезнет.** Ghostty 1.3.1 рисует в `IOSurfaceLayer` из своего
  потока рендера по своему display link (строки `IOSurfaceLayer`, `renderer_thread`, `updating display link`
  в бинаре). Новый буфер у него приходит асинхронно, а не в коммите рамки. Выигрыш на Ghostty — только AX и
  очередь, не его рендер. Мерить.
- **Режим «живой» меняет вид относительно эталона.** В Hyprland содержимое с первого кадра в конечной раскладке
  (`anim_feel.md` §2, L1: шрифт 1:1, обрезка). В «живом» режиме текст переносится на ходу, как при ручном
  ресайзе на маке. Это нативно для macOS, но не 1:1 с Hyprland. Решать по видео A/B.
- [H] Если приложение пропускает кадр (тяжёлый layout), в «живом» режиме его окно отстаёт на кадр от соседа:
  шов дрожит. Лечение — позицию оставить за движком (наш трансформ = B − A), а приложению давать только
  размер (`geometryType 2`).
- [H] `_setFrameCommon:display:NO` — рисуется ли содержимое в том же коммите, что форма. `windowctl.md` п.2
  говорит, что форма идёт в CA-payload (method 3), но выбор метода вживую не подтверждён.
- `_startLiveResize` (0x184c61bac) рассылает `NSWindowWillStartLiveResizeNotification` @0x184c61c1c, вызывает
  `_NSSetWindowKeepExcessBackingAllocation` @0x184c61c48 и `setInLiveResize:` @0x184c61c68. Приложения могут
  менять поведение в live resize (Ghostty подписан на `windowWillStartLiveResize:` — строка в бинаре; что он
  делает, не разбирал).
- Модуль должен быть в процессе. Сейчас его грузит lldb, и это замораживает приложение примерно на 2 с
  (`daily_bugs.md` F9). Для окон без модуля остаются AX и запасной путь из §5. Доставку без паузы я не
  исследовал — это отдельная задача.
- Номер типа уведомления выбрать вне используемых WS ([H] занятые номера не перечислял; разумно 0x7f00+).
- Конфликт с WindowManager.app: если тайлинг или Stage Manager macOS тоже шлёт запрос, `_stopWindowManagerResizeAnimation`
  снимет наш. Держать тайлинг macOS выключенным.

**Как проверить (по одному шагу):**
1. Модуль без движка: команда в модуль `_resizeFromWindowManager…` с `springSettings:nil` на TextEdit.
   Окно встаёт в рамку, текст переносится, `rec2` — без промежуточного кадра.
2. То же с пружиной 1/210/24: траектория края по `rec2` против таблицы drift из `anim_feel.md` §1 (±1 кадр).
3. Канал WS → приложение: движок шлёт тип на соединение TextEdit, модуль пишет в `NSLog` время приёма.
   Мерить задержку «тик → колбэк».
4. Свойство соединения: движок ставит `hyprwm.next`, модуль читает `SLSCopyConnectionProperty`. Значение то же.

---

## 2. Configure до показа: новое окно сразу размера плитки

### 2.1 Где AppKit выводит окно [V]

Цепочка в `-[NSWindow _reallyDoOrderWindowAboveOrBelow:]` 0x18573d138:
1. Свои `setFrame:display:` (@0x18573d4fc, @0x18573d544, @0x18573d60c — подгонка под экран).
2. Для обычного окна `isSheet` = NO → `w2 = 0` (@0x18573d570), затем `_doWindowWillBeVisibleAsSheet:`
   (@0x18573d578).
3. `-[NSWindow _doWindowWillBeVisibleAsSheet:]`:
   - **первым делом** `_postWindowWillOrderOnScreenNotification` (@0x184aecf60), то есть
     `NSWindowWillOrderOnScreenNotification`;
   - затем `_windowWillOrderOnScreen` (@0x184aecf6c) и `update`;
   - в конце `displayIfNeeded` (@0x184aed020) — AppKit сам рисует содержимое перед выводом.
4. Только после этого `_NSOrderWindow` (@0x18573dac0):
   - сначала выводит окно на сервер сам: `__NXOrderWindow` @0x184c40748;
   - потом сообщает WindowManager: `__NSWMOrderWindow` @0x184c4076c →
     `__NSWMTransactionAddOrderingActionWithInfoForOptions` → `actionForOrderingWindowWithInfo:fences:`.
5. После вывода — `NSWindowDidOrderOnScreenNotification` (@0x18573d7f0).

Вывод: WindowManager появление окна не задерживает. Приложение выводит окно само и лишь сообщает об этом.
Поймать момент «до первого кадра» можно только внутри приложения, и AppKit сам даёт для этого уведомление
до своей отрисовки.

### 2.2 Как опереться

- Модуль подписан на `NSWindowWillOrderOnScreenNotification`. Для окна, которое будет тайлиться (eligible в
  `hyprforce.m`, первый показ), он синхронно читает `SLSCopyConnectionProperty(cid, cid, "hyprwm.next")`.
  Если там рамка — `setFrame:display:NO` (или `_resizeFromWindowManager…` без пружины). Дальше AppKit сам
  нарисует окно в этом размере и выведет его.
- Демон заранее (в покое и при каждой смене фокуса или раскладки) кладёт через движок в свойство соединения
  каждого тайлового приложения «куда встанет следующее окно» — пробная вставка `tile.insert` в копию дерева,
  как предлагал `daily_bugs.md` F2(б).
- Движку остаётся то, что у него получается хорошо: прятать окно в тик рождения (prehide) и стартовать popin и
  соседей в одном кадре — буфер уже нужного размера.

**Что заменяет:**
- `F_WAIT` (до 150 мс ожидания);
- «растянуто → обрезано» в конце popin (`daily_bugs.md` F3);
- окна в «рандомном месте» (жалоба 2, F8);
- `hide_newbies`/`optimistic` для приложений с модулем.

**Риски:**
- [H] Приложение может переставить рамку уже после уведомления: восстановление состояния, автосохранение
  рамки, `setFrame:` в `windowDidLoad`. Тогда первый кадр снова будет не тем. Проверять по приложениям.
- Окна, которые не должны тайлиться (диалоги, панели, листы), фильтровать как в `eligible()`. Листы обходят
  уведомление с `w2 = 1`.
- Устаревшее значение `hyprwm.next`: обнулять после использования (модуль ставит своё свойство «взял seq N»,
  движок видит).

**Проверка:** `rec2` при ⌥Enter и при Cmd+N в TextEdit — ни одного кадра нового окна вне плитки и ни одного
кадра растянутого буфера; в журнале траектории старт popin в том же кадре, что и соседи, при `F_WAIT = 0`.

---

## 3. CoreAnimation как часы для всего, кроме геометрии

### 3.1 Пружина CA = пружина hyprutils [V]

**QuartzCore `CA::Render::SpringAnimation::State::update(mass, stiffness, damping, velocity, allowsOverdamping)`
0x18a90de54:**
- `ω₀ = √(k/m)` (@0x18a90de54–58);
- `ζ = d / (2·√(k·m))` (@0x18a90de5c–68);
- при ζ < 1: `ω_d = ω₀·√(1−ζ²)` (@0x18a90de80–90), коэффициент при синусе `(v − ζω₀)/ω_d` (@0x18a90de9c–a0);
- критическая ветка и (только с `allowsOverdamping`) передемпфированная — @0x18a90dea8…ee0.

**`State::eval(t)` 0x18a6371cc:** `1 − e^(−ζω₀t)·(cos ω_d t + C·sin ω_d t)`
(`expl` @0x18a637210, `__sincos_stret` @0x18a637220, `1 − …` @0x18a637294).

**hyprutils `advanceSpring`** (`Spring.cpp`): `GAMMA = d/(2m)` (= ζω₀), `OMEGAD = √(ω₀² − GAMMA²)`, те же три
режима.

Это одно и то же аналитическое решение. drift (ζ = 0.828) и bounce (ζ = 0.620) — недодемпфированные, обе
ветки совпадают. Безье Hyprland = `CAMediaTimingFunction functionWithControlPoints::::` (`decor_v2.md`).

Значит, `CASpringAnimation`/`CABasicAnimation` на наших слоях дадут те же кривые, а кадры будет считать
рендер CA в момент показа: без нашего тика и без гонки фаз. `decor_v2.md` и PROGRESS 11:00 (HYPRWM14)
подтверждают вживую, что CA-анимация на слоях локального контекста окна в WS идёт сама.

### 3.2 Граница применимости: область рисования окна считается по модели WS [V]

- `layergen_ca_backed_window` 0x186e224e8 берёт трансформ окна из `win+0x498` (@0x186e22760 `mov w8, #0x498`,
  копия на стек @0x186e22784) и передаёт его в
  `ca_backed_window_create_destination_shape(CGXRedrawState*, WSWindowTransform, Mesh*, CGSRegionObject*)`
  0x186e237a8 (вызов @0x186e227d0).
- Форма источника — `frame_bounds` или прямоугольник содержимого (`beyond_bounds.md` §1.1).

Следствие: всё, что CA-анимация сдвинет за модельную область окна, WS не нарисует. Перемещение и рост окна
нельзя отдать CA — только нашему трансформу (`CGXSetWindowTransform3DList`, он пишет в эту модель) или
настоящей рамке окна (§1). Внутри области можно: прозрачность, кроссфейды рамки, тени и glow, масштаб
popin/windowsOut ≤ 100 %. Пик bounce 101.2 % выходит за рамку на ~1 %; это покрывает выступ «невидимой
тени» из `beyond_bounds.md` §1.4.

Это закрывает старую гипотезу `exotic.md` §1.4 и К12 в MASTER («аддитивная CASpringAnimation для перемещения
окна»): для перемещений — тупик, для остального — рабочий путь.

### 3.3 Слои оформления, которые подгоняет сам CA [V]

- `-[CALayer setBounds:]` 0x18a5fda08 → `CA::Layer::set_bounds` → `resizeSublayersWithOldSize:` (@0x18a5fdc7c).
- `-[CALayer resizeSublayersWithOldSize:]` 0x18a5fddc4 вызывает `resizeWithOldSuperlayerSize:` у каждого подслоя
  (@0x18a5fde40) и у маски (`CA::Layer::mask` @0x18a5fde54 → @0x18a5fde84).
- Значит, слой с `autoresizingMask` (`setAutoresizingMask:` 0x18a603a54) в Server root подстраивается в той же
  транзакции, где ingestion WS ставит bounds окну (бит 3, `compositor.md` §1б).

**Как опереться:** кольцо рамки собрать из подгоняемых слоёв, без пути:
- неактивное кольцо — `CALayer` с `borderWidth`/`cornerRadius`;
- активное — `CAGradientLayer` с маской-`CALayer` с `borderWidth`;
- `autoresizingMask = width|height sizable`.

Тогда в режиме §1 («живой») и при любом коммите размера рамка совпадает с окном в каждом кадре без нашего
пересчёта.

**Что заменяет:** покадровый `border_win`/`probe_layers` и пересборку пути кольца; лечит рассинхрон «маска или
кольцо в одном кадре, размер в другом» (`daily_bugs.md` F14).

**Риск:** `shadowPath` и путь `CAShapeLayer` сами не масштабируются. Тень надо строить без пути (тень от
непрозрачного слоя-подложки с `cornerRadius`) или переставлять путь только при смене размера.

### 3.4 Что AppKit делает сам при появлении и уходе окна [V, как образец и как помеха]

- `-[NSWindow _doOrderWindow:]` 0x18573e290: `_NSAutomaticWindowAnimationsLevel` (@0x18573e308) →
  `_effectiveOrderFrontAnimationTypeIfModal:` / `_windowTransformAnimationForOrdering:animationType:interruptingAnimation:`
  (@0x18573e490, @0x18573e574) → `_reallyDoOrderWindow:`.
- `_NSWindowTransformAnimation` — подкласс `NSAnimation`: `_displayLinkProvider` 0x185921e08,
  `_scaleAmount`/`_setAnimatesAlpha:`/`setAnchorPoint:`. Прогресс применяется в `_NSPerformVisuallyAtomicChange`
  (`setCurrentProgress:` 0x184bd7ed8 @0x184bd7fc0). Есть ветка Tahoe `_NSSolariumWindowAnimationsEnabled` (@0x184bd719c).
- То есть у документных окон, алертов и попапов AppKit сам играет «зум + прозрачность» при появлении и уходе.

Для нас это помеха: она наслаивается на наш popin или клон закрытия. Модулю — выставить
`animationBehavior = NSWindowAnimationBehaviorNone` тайловым окнам. [H — что это выключает именно
`_NSWindowTransformAnimation`: по имени `_effectiveOrderFrontAnimationTypeIfModal:` это вероятно, ветку не
трассировал.]

---

## 4. Минимумы и шаг размера окна — из системы

**[V]**
- AppKit сам отдаёт серверу min, max и preferred размеры окна:
  `-[NSWindow(NSFullScreen) _setTileMinSize:tileMaxSize:tilePreferredSize:]` →
  `SLSPackagesSetWindowConstraints` (@0x184b287a8).
- Значения: `_actualMinFullScreenContentSize`, `maxFullScreenContentSize`, `_tilePreferredSize` (@0x184b283b8…d8,
  `_doUpdateTilingConstraintsImmediately`). Внутри — `_getConstrainedWindowMinSize:maxSize:` (@0x184b28544).
- Вызывают это `-[NSWindow _commonMinMaxSizeChanged]`, `_changeWindowFrameFromConstraintsIfNecessary`,
  `setMin/MaxFullScreenContentSize:` и другие.
- **Гейт:** `-[NSWindow(NSFullScreen) _refreshTilingConstraints:]` 0x184a32740 обновляет, только если
  `_needsTilingConstraintUpdate` (@0x184a32788). Это `__NSGetBoolAppConfig` с
  `_sNSWindowAlwaysUpdateTilingConstraintsComputedValue` и `_NSWindowAlwaysUpdateTilingConstraintsDefaultValueFunction`
  (@0x184a328d4…910), иначе — только у активного приложения (`NSApp isActive` @0x184a32924).
  Строка ключа в AppKit — `NSWindowAlwaysUpdateTilingConstraints`.
- **Сервер:** `__XPackagesSetWindowConstraints` 0x18719a7a0 пишет 3×CGSize в `*WSWindowGetPackagesData(win, 1)`
  (0x186fb18dc; malloc 0x30 @0x18719a874, записи @0x18719a8a4/8c8/8e8).

**[H]** Ключ читается как обычная настройка приложения: `defaults write <bundle id> NSWindowAlwaysUpdateTilingConstraints -bool YES`
или глобально. Тогда у всех окон ограничения всегда лежат на сервере, и движок читает их в тик рождения окна:
`WSWindowGetPackagesData(win, 0)` → три CGSize. Порядок полей (min, max, preferred) — гипотеза по порядку
аргументов `_setTileMinSize:…`; сверить по `__XPackagesGetWindowConstraints` 0x18719a6a8.

**Проще и точнее — из модуля:** `[w minSize]`, `[w contentMinSize]`, `[w resizeIncrements]` /
`contentResizeIncrements` (0x185735db0 / 0x185735e08) — прочитать и положить в свойство соединения для движка
и демона.

**Что заменяет:** `minsize_app.json`, «учить минимум по ответу AX», ложные минимумы:
- Terminal 455 против 448 — это его `resizeIncrements`, сетка строк;
- Ghostty «весь экран» — асинхронный ответ.

Также убирает вторую волну от `configured()` (`daily_bugs.md` F7) и позволяет раскладке учесть минимумы
до первого хода.

---

## 5. Сервер сам держит старый кадр: запасной путь и жалоба на свайп

### 5.1 Locked bounds и freeze

Разобраны в `beyond_bounds.md` §2, повторять не буду: `window_list_set_locked_bounds` 0x186e50174,
`WSWindowFreezeContent` 0x187073bf0, `WSWindowThawContent` 0x187073d98. Это запасной путь для окон без модуля
и для приложений, которые перерисовываются дольше пары кадров.

### 5.2 Сплющивание окон во время свайпа столов [V механизм, H связь с жалобой 1]

- WS умеет рисовать CA-окно из закэшированной плоской копии:
  `WSCAWindowBacking::Flatten` 0x186ea72c4, `PrepareFlattenedTree` 0x186ea86fc, `PopulateFlattenedContent` 0x186ea8e14,
  `UnFlattenWindow` 0x186ea7200, `UpdateFlatteningIfNeeded` 0x186ea6f74.
- Причины — биты `FlatteningPolicyReason` (`FlatteningPolicyData::stringify` 0x186d7733c, проверки @0x186d7735c…):
  0 unknown, 1 windowless, …, 5 idle, 6 change, 7 animation, …, 15 sharing, **16 expose**, **17 swipe**,
  18 empty-clip, 19 stage-manager, 20 non-visible, ….
- В `ca_window_prep_ingestion_phase`:
  - при свайпе дисплея (`[[[0x1ea5fb550]+0x20]+0xd8]+0x3e0 != 0`, @0x186e2510c–25114) окну ставится причина
    `swipe` (0x20000, @0x186e25524);
  - режим выбирает байт `cgdebug::allow_unflatten_during_swipe` (0x1ea5f9bb2, @0x186e2551c):
    0 → `set_should_flatten_or_reflatten` (@0x186e25158), 1 → `set_should_flatten_barring_change` (@0x186e254a0);
  - для Mission Control то же с причиной `expose` (0x10000, @0x186e25494) и флагом
    `allow_unflatten_during_mc` (0x1ea5f9bb1);
  - у окна с неединичным трансформом и битом 4 в `win+0x930` — причина `sharing` (0x8000, @0x186e250ac…25158).
- Размер плоской копии: `PrepareFlattenedTree` ставит рамку по bbox региона из объекта `backing+0x348`
  (@0x186ea87a0–a8). Что это за регион (форма A или `frame_bounds`) и попадают ли в копию маска Hosting и наш
  трансформ — **не установил**. На этом остановился.

**[H]** Жалоба 1 («Telegram на своём минимуме стирается при медленном свайпе тремя пальцами»). Окно на минимуме
держится маской больше своей плитки. Во время свайпа WS рисует его из плоской копии, которая может не учитывать
нашу маску или трансформ. Проверка — одна запись байта: `allow_unflatten_during_swipe` (0x1ea5f9bb2 + slide)
= 1 на время опыта, медленный свайп, `rec2`. Если артефакт меняется — причина здесь. Тег окна
`NeverFlattenSurfacesDuringSwipes` (бит 55, `exotic.md` §5.1) — второй, точечный рычаг на одно окно. Его
действие на CA-окна не прослеживал.

---

## 6. Дополнительно: WindowManager.app — встроенный в macOS 26 протокол «приложение ↔ оконный менеджер»

**[V] клиентская часть:**
- AppKit отправляет WindowManager транзакции с fences почти на каждый шаг жизни окна. В WindowManagement.framework:
  - `actionForCreatingWindow:fences:` 0x27ccea060, `actionForDestroyingWindow:fences:`;
  - `actionForOrderingWindowWithInfo:fences:` 0x27ccea1f0;
  - `actionForMiniaturizingWindows:fences:`, `actionForHidingApplicationWithFences:`;
  - `actionForProposingKeyWindowWithInfo:fences:`;
  - `actionForClientResizeWindowResponseActionInfo:fences:` 0x27cceade4 и другие.
- Отправка — `-[NSWMWindowCoordinator performTransactionUsingBlock:]` → `_createTransactionIfNeeded` (`fence`,
  `deferCompletionUntil`) → `_sendCompletedTransactions` → `sendWindowTransaction:` и `fence invalidate`
  (0x185908788…870).
- В AppKit через это идут, среди прочего, `-[NSWindow _commonInitFrame:…]`, `+[NSWindow _miniaturizeWindows:forRestoration:]`,
  `-[NSWindow deminiaturize:]`, `__NSWMOrderWindow`, `-[NSWindow _destroyWMWindow]`.
- Обратно WindowManager может попросить приложение изменить размер (§1.1), сделать окно ключевым
  (`clientWindowManager:requestMakeKeyWindowWithIdentifier:` 0x18590aa68 → блок → `makeKeyWindow` @0x18590abb4)
  и ответить на hide/miniaturize.
- Настройки AppKit по этой теме: `NSWMWindowCoordinatorFenceIPC` (строка;
  `_NSWMWindowCoordinatorFenceIPCDefaultValueFunction`), `-[NSWMWindowCoordinator disableTransactionFencing]`.

**[H] Как это может пригодиться.** В WindowManager.app сходятся события всех приложений с fences — это самое
«нативное» место для оконного менеджера на macOS 26. Серверную часть (Swift, без символов) не трассировал.
Постоянный код внутри WindowManager.app — по-прежнему конец очереди (MASTER П13), но §1–§2 дают то же для
наших задач через модуль в приложении, без WindowManager.

**Тот же модуль закрывает Cmd+H и Cmd+M.** Они идут через AppKit приложения (`hideApplication…`,
`_miniaturizeWindows:`), поэтому их надёжнее перенаправлять в наш `hide` перехватом в модуле, а не биндом.
Бинд не ловит скрытие из меню, Dock и AppleScript (P17, P44). [H — точку перехвата (`-[NSApplication hide:]`,
`-[NSWindow miniaturize:]`) не выбирал.]

---

## 7. Тупики и отвергнутое (с причиной)

| что | почему нет | где остановился |
|---|---|---|
| Перемещение и рост окна аддитивной CASpringAnimation на Server root (EX §1.4, К12) | Область рисования окна строится по модельному трансформу `win+0x498`, а не по представлению CA; всё за модельной областью не рисуется | [V] `layergen_ca_backed_window` @0x186e22760–227d0 |
| `NSSpringAnimation` как есть для синхронного хода нескольких окон | Свой display link в каждом приложении, выборка по `timestamp` (прошлая развёртка), без общего t0 | Лечится `_setStartTime:` (0x1851c6758) или своим драйвером в модуле; без этого шов между окнами разных приложений может дрожать на кадр [H] |
| Configure через shape + WindowMoved изнутри WS | AppKit из WindowMoved берёт только позицию | проверено вживую раньше, `resize_re.md` |
| Configure через WindowManager.app по BSService | Нужен код внутри WindowManager (мост lldb ~250 мс, таблица wid → UUID) | §1 даёт тот же метод AppKit напрямую из модуля |
| Ждать от WindowManager «configure до map» | WindowManager появление окна не задерживает: `_NSOrderWindow` выводит окно сам (`__NXOrderWindow` @0x184c40748) и лишь потом сообщает WM | [V] |
| `PKGAnimation`, genie- и sheet-анимации SkyLight | Только 6 безье, тот же таймер; genie — заглушки | `exotic.md` §1 |
| Связь сплющивания при свайпе с жалобой 1 | Не доказана статикой | §5.2, регион `backing+0x348` |
| Ограничения окна на сервере «всегда есть» (MASTER К22) | Не всегда: только при `_needsTilingConstraintUpdate` или активном приложении | [V] §4 |
| Отдельный файл или Mach-сервис для связи с модулем | Песочница Telegram, Word и TextEdit (`app-sandbox`, у Word узкие `mach-lookup` исключения) | Не нужно: канал через соединение WS, §1.2 |

---

## 8. Что проверить вживую (по одному, с откатом; к WS — только основной агент)

1. **Модуль, без WS.** `_resizeFromWindowManagerWithTargetGeometry:… springSettings:nil` на TextEdit и Ghostty:
   время от вызова до коммита нового размера (`rec2`, журнал bbox движка в режиме чтения). Затем с пружиной
   1/210/24 — траектория против drift.
2. **Модуль, configure до показа.** Обработчик `NSWindowWillOrderOnScreenNotification` ставит фиксированную рамку
   (без WS): Cmd+N в TextEdit — первый кадр окна в этой рамке.
3. **Канал WS → приложение.** Движок: `WSPostNotificationToConnection` своим типом на соединение TextEdit;
   модуль: `SLSRegisterConnectionNotifyProc`, лог времени. Затем `CGXSetConnectionProperty` +
   `SLSCopyConnectionProperty` синхронно.
4. **Ограничения окна.** `NSWindowAlwaysUpdateTilingConstraints = YES` для TextEdit или Terminal → перезапуск
   приложения → `SLSPackagesGetWindowConstraints` из демона на его окно: не нули, min совпадает с
   `minSize` (сравнить через модуль).
5. **Свайп.** Байт `allow_unflatten_during_swipe` = 1 на время опыта, медленный свайп с Telegram на минимуме,
   `rec2`; вернуть 0.
6. **Подгоняемые слои.** Одно кольцо с `autoresizingMask` в Server root тестового окна, ручной ресайз за угол —
   кольцо совпадает с краем в каждом кадре (крупный план `rec2`).
7. **Отключение AppKit-анимаций появления.** `animationBehavior = None` из модуля у TextEdit — при Cmd+N нет
   «зума» AppKit поверх нашего popin.

---

## 9. Проверено мной (сводка адресов)

**AppKit:**
- `_resizeFromWindowManagerWithTargetGeometry:springSettings:completion:` 0x1857476c4, блок прогресса 0x185747c7c;
- `-[NSWMWindowCoordinator clientWindowManager:performResizeWindowRequest:]` 0x18590b688, блоки 0x18590b75c / 0x18590b96c;
- `-[NSAnimation _advanceTimeWithDisplayLink:]` 0x1851c7508, `_setStartTime:` 0x1851c6758, `_displayLinkProvider` 0x1851c6f34;
- `_NSPerformVisuallyAtomicChange` 0x184a36274;
- `NSSpringAnimation initWithDuration:` 0x185a66f44, `currentValue` 0x185a670bc;
- `_startLiveResize` 0x184c61bac;
- `_reallyDoOrderWindowAboveOrBelow:` 0x18573d138 (@0x18573d578, @0x18573dac0), `_doWindowWillBeVisibleAsSheet:`
  (@0x184aecf60, @0x184aed020), `_NSOrderWindow` (@0x184c40748, @0x184c4076c);
- `_doOrderWindow:` 0x18573e290, `_NSWindowTransformAnimation setCurrentProgress:` 0x184bd7ed8;
- `_setTileMinSize:tileMaxSize:tilePreferredSize:` (@0x184b287a8), `_refreshTilingConstraints:` 0x184a32740;
- `requestMakeKeyWindowWithIdentifier:` 0x18590aa68;
- `-[NSWMWindowCoordinator performTransactionUsingBlock:]` и `_sendCompletedTransactions` (0x185908788).

**QuartzCore:**
- `CASpringAnimation _solveForInput:` 0x18a8d089c → `_timeFunction:` 0x18a636f6c;
- `SpringAnimation::State::update` 0x18a90de54, `State::eval` 0x18a6371cc;
- `CACurrentMediaTime` 0x18a604f74;
- `CALayer setBounds:` 0x18a5fda08 → `resizeSublayersWithOldSize:` 0x18a5fddc4.

**SkyLight:**
- `SLSCurrentRealTime` 0x186d8b4d8;
- `WSPostNotificationToConnection` 0x186e7430c, `SLSRegisterConnectionNotifyProc` 0x18703f36c;
- `CGXSetConnectionProperty` 0x186f54760, `SLSCopyConnectionProperty` 0x18703da20, `__XGetConnectionProperty` 0x1871ab424;
- `__XPackagesSetWindowConstraints` 0x18719a7a0, `WSWindowGetPackagesData` 0x186fb18dc;
- `layergen_ca_backed_window` 0x186e224e8 (@0x186e22760–227d0), `ca_backed_window_create_destination_shape` 0x186e237a8;
- `FlatteningPolicyData::stringify` 0x186d7733c;
- `ca_window_prep_ingestion_phase` (@0x186e250ac…25158, @0x186e25494–254a0, @0x186e25514–25524);
- `WSCAWindowBacking::PrepareFlattenedTree` 0x186ea86fc.

**WindowManagement:** `WMClientWindowManager performResizeWindowRequest:` 0x27ccf423c, `WMWindowTransactionAction`
`actionFor…:fences:` (список в §6), `_WMResizeTargetGeometry targetGeometryWithFrame:contentsGravity:` 0x27cce8568.

**Приложения (codesign / otool):**
- Telegram — AppKit, песочница;
- Ghostty 1.3.1 — AppKit + SwiftUI, `IOSurfaceLayer`;
- Word — AppKit, песочница, `disable-library-validation`;
- TextEdit — песочница;
- Terminal, Finder, OpenRunner — AppKit;
- Zen — Gecko (`disable-library-validation`; AppKit через libxul, напрямую в исполняемом файле не виден).

**Не нашёл и не проверял:**
- где серверная часть WindowManager.app обрабатывает fences (Swift без символов);
- какие пружины шлёт тайлинг macOS;
- регион `backing+0x348` у плоской копии;
- точный порядок полей ограничений окна на сервере;
- как Ghostty реагирует на live resize;
- способ загрузки модуля без паузы приложения.
