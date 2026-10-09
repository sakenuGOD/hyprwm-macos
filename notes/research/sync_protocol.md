# sync_protocol: свой configure/ack на macOS — разбор идеи пользователя

Статус: статика, 2026-10-09. Исследователь, только чтение: lldb не запускал, к процессам не подключался, канал/сокет
демона не трогал, код проекта не менял. Записан только этот файл.

Источники: `notes/MASTER.md`, `notes/PROGRESS.md` (08:00–14:50), `notes/research/{beyond_bounds,windowctl,compositor,timing,
daily_bugs,live_test_1}.md`; `hook/src/anim4.c`, `hook/hyprwm.py`, `hook/src/axlib.c`, `hook/active/hyprforce.m`;
SkyLight — `cache/sl_dis.txt`, `cache/sl_syms.tsv`, `extracted/SkyLight`; AppKit и QuartzCore — `extracted/appkit/AppKit`,
`extracted/QuartzCore`, дизассемблирование общего кеша (`ipsw dyld disass … --vaddr`); строки в бинарниках Ghostty,
Telegram, Zen (XUL), Microsoft Word; Hyprland `/tmp/hyprland-src` (5e04ae1, VERSION 0.56.0).

Метки: **[V]** — проверено по листингу, адрес указан; **[H]** — гипотеза, рядом написано, как её проверить. Адреса
статические (macOS 26.7.1, 25G241). В живом процессе к ним прибавляется slide.

> **Оговорка о задании.** Текст задания пришёл обрезанным (дважды одинаково) на словах «1. Собрать свой configure/ack:
> модуль в приложении меняет размер окна изн…». Остальные идеи до меня не дошли. Пункт 1 я понимаю так: модуль внутри
> приложения сам меняет размер окна и сообщает движку, какой кадр к какому размеру относится. Разбираю его полностью,
> а заодно все смежные варианты, которые нашлись по ходу (§5). Если идей было больше, их нужно прислать отдельно.

---

## 0. Вывод (прочитать первым)

1. **В Hyprland «соответствие кадра размеру» нужно для учёта, а не для того, чтобы ждать** [V исходники, §1].
   Композитор запоминает, под какой configure закоммичен каждый буфер (`ackedSize`). Но анимацию бокса он не
   задерживает: configure уходит в том же вызове, что и старт анимации. Буфер всегда рисуется в анимируемом боксе
   1:1 от левого верхнего угла: лишнее обрезается, недостающее дотягивается краевым пикселем. Новый буфер просто
   подменяет старый внутри того же бокса. Телепорта там нет по двум причинам: (а) геометрия бокса не зависит от
   буфера; (б) клиент отвечает за 1–2 кадра, и подмена приходится на начало хода, когда окно почти не сдвинулось
   (drift @60 Гц: 2.6 % и 8.9 % пути за 1-й и 2-й кадр).

2. **Самая вероятная главная причина «30–500 мс» — сама AppKit, и её можно проверить одним чтением.** [V листинг, §3.1]
   `-[NSWindow accessibilitySetSizeAttribute:]` и `…SetPositionAttribute:` **анимируют** рамку окна силами
   приложения (`[[window animator] setFrame:display:]`), если у приложения включён `AXEnhancedUserInterface`
   (глобал AppKit `_gEnhancedUserInterfaceEnabled`):
   - изменение меньше 5 pt — сразу;
   - от 5 до 200 pt — анимация 0.1 с;
   - 200 pt и больше — анимация с длительностью по умолчанию: формула `animationResizeTime` даёт до **0.35 с**.

   Числа из PROGRESS совпадают с этим подозрительно точно: Ghostty «стоял в старом размере ≥0.35 с» (08:00),
   Ghostty ~140–160 мс, Word 350–500 мс (13:45). Если флаг включён, приложение само проводит окно через десятки
   промежуточных размеров поверх нашей анимации. Отсюда содержимое, которое меняется «посреди и в конце», и
   неверные минимумы. Наш `axlib.c` этот флаг не трогает. Включить его мог любой сторонний AX-клиент
   (VoiceOver, «Голосовое управление», утилиты, которые включают дерево доступности у Chromium/Electron).
   **Шаг 0 плана (§6)** — прочитать атрибут у всех тайловых приложений.

3. **Идея 1 подтверждается частично, с важными поправками.**
   - **«Размер изнутри приложения» — да, и Apple делает именно так** [V, §2.2]. WindowManager.app (нативный тайлинг
     macOS 26) шлёт приложению `_WMClientResizeWindowRequest`. AppKit сам ограничивает размер (`_confirmSize:force:`),
     сам ставит рамку или ведёт её пружиной в режиме live resize. Ответом служит `CAFenceHandle`:
     WindowManager.app сцепляет с ним свою транзакцию. Это и есть родной configure → ack → commit. Модуль в
     приложении может пойти тем же путём и получить то, чего нет у AX:
     - одна атомарная рамка (позиция и размер одним `setFrame:display:`) без аниматора AppKit;
     - **заранее известный точный размер, который окно примет** (`_validSize:force:` учитывает min/max, шаг
       сетки, соотношение сторон, ограничения Auto Layout, тайлинг) — без «выучки минимумов» и второй волны;
     - включение live resize, в котором Qt/Gecko/Word рисуют синхронно с рамкой.
   - **Подтверждение (ack) — да, реализуемо.** Оболочка окна (форма) у macOS уже подтверждается атомарно: смена
     формы приходит в том же CA-коммите (method 3), и движок видит её как смену `bbox(win+0x170)`
     [V windowctl + §2.1]. Не хватает подтверждения **содержимого** у асинхронных рендереров (Metal в отдельном
     потоке — Ghostty; отложенная отрисовка). Его даёт метка, которую модуль ставит на окно сервером
     (`SLSTransactionSetWindowProperty`): движок читает её каждый тик (`WSWindowGetProperty`) [V путь, §4.3].
   - **Само подтверждение телепорт не убирает.** Оно сообщает, *когда* пришёл кадр, но не делает этот момент
     *раньше*. Телепорт — это подмена содержимого посреди хода. Убрать её можно только двумя способами:
     (а) приложение отвечает за 1–2 кадра, как клиент Wayland; (б) старт держится до подтверждения, и это
     стоит задержки. Поэтому главный выигрыш даёт быстрый путь (п. 2 и §4.1), а подтверждение — точная политика
     старта вместо таймаутов 150/200 мс.

4. **Найден отдельный механизм рывка на один кадр, который не зависит от приложения** [V QuartzCore + код, §3.3].
   Маска видимой рамки (`put_mask`) ставится от **нижнего** края слоя Hosting (ось Y вверх), а размер Hosting меняет
   ingestion WindowServer позже нашего тика. В кадр, когда окно меняет высоту, маска стоит со смещением ΔH:
   окно «прыгает» на высоту изменения. Исправление без подтверждения: `mask.autoresizingMask = kCALayerMinYMargin`.
   QuartzCore сама двигает маску в том же `setBounds`, который делает WindowServer: `CA::Layer::set_bounds` →
   `resizeSublayersWithOldSize:` обходит и подслои, **и маску**.

5. **Рекомендуемый порядок** (подробно в §6):
   1. проверить и выключить `AXEnhancedUserInterface` (одна строчка вокруг `ax_frame`, как делает yabai);
   2. автоподстройка маски и колец к верхнему краю;
   3. перехват AX-сеттеров в `hyprforce` (атомарный `setFrame`, live resize, запрос точного размера);
   4. метка подтверждения содержимого и старт по ней (≤1–2 кадра ожидания);
   5. только для хвоста медленных приложений — короткий кроссфейд клона (не 1:1, честно помечено).

---

## 1. Эталон: как это в Wayland / Hyprland (исходники 5e04ae1)

- **configure уходит сразу вместе со стартом анимации** [V]. `CWindowTarget::setPositionGlobal` → `m_window->setBox(wb)`
  (цель анимации) → `sendWindowSize()` (`src/layout/target/WindowTarget.cpp:252–256`) →
  `backend().configure(GOAL box)` (`:461–467`) → `TOPLEVEL->setSize(size)` + `m_configureAcks.add(serial, size)`
  (`WaylandBackend.cpp:304–316`). Ожидания ответа нет.
- **ack — учёт** [V]. `onAck(serial)` → `m_configureAcks.acknowledge(serial)` → `acknowledgeConfigure()` пишет
  `m_pending.ackedSize` (`WaylandBackend.cpp:318–324, 441–447`). На commit — `m_reportedSize = m_current.ackedSize`
  (`:142–147`). Значит, у каждого показанного буфера известно, под какой размер он нарисован.
- **Рисование в анимируемом боксе** [V]. `calculateUVForSurface` (`src/render/ElementRenderer.cpp:61`):
  `RATIO = projSize / EXPECTED_SIZE` (`:111`), где EXPECTED — размер текущего буфера или `ackedSize` (`:42–57`);
  - RATIO > 1 и `expand_undersized_textures` → `uvBR *= RATIO`: буфер 1:1, за краем повтор краевого пикселя (`:113–116`);
  - RATIO < 1 (кроме `animatingIn`) → `uvBR *= RATIO`: буфер 1:1 от левого верхнего угла, лишнее отрезано (`:119–123`);
  - у popin (`animatingIn`) — растяжение.
  Буфер, который меньше `ackedSize` (клиент сам выбрал размер меньше, например по сетке терминала), центрируется
  (`CWLSurface::small/correctSmallVec`, `src/desktop/view/WLSurface.cpp:43–67`).
- **Итог для переноса.** Hyprland не ждёт кадр приложения, а соответствие «кадр ↔ размер» использует только для
  расчёта UV. Телепорта не видно, потому что геометрия бокса не зависит от буфера, а клиент успевает за 1–2 кадра.
  На macOS вторая часть не выполняется: 30–500 мс. Задача сводится к тому, чтобы либо сократить это время до
  1–2 кадров, либо не начинать ход, пока кадр не пришёл, — и знать это точно, а не угадывать.

---

## 2. Что на macOS уже работает как configure/ack (путь Apple)

### 2.1 Форма окна подтверждается атомарно с CA-коммитом приложения [V]
- AppKit кладёт новую форму в `SLSTransactionSetWindowShape` и коммитит её внутри своего CA-коммита (method 3)
  (windowctl.md п.2, `_NSCGSTransactionRunPreCommitActions_` 184b0fc18).
- Клиентская сторона: `sls_transaction_commit_ca` 186ddbc80 → `SLSTransactionGetFencingContext` →
  `-[CAContext setPayload:@{bytes, connID, txnID}]`. В QuartzCore `setPayload:` 18a958524 — это
  `CA::Transaction::add_command`, то есть payload уходит **командой этого же CA-коммита** [V].
- На сервере `WS::CA::callback::context_payload_did_change` 186de6f40: на главном потоке payload сразу
  декодируется и исполняется (`PKGTransactionDecodeCAPayload` → `shape_window`). Иначе он ставится в очередь
  `CGXConnectionPayloadOperationQueue` и переносится на главный поток (`_scheduleExecutionForSession` →
  `WSMainThreadBlockHoistEnqueueBlock` 186e2f1e4) [V].
  **[H]** Значит, дерево слоёв приложения (новое содержимое) и форма окна могут примениться **в разные моменты**.
  Это согласуется с замером PROGRESS 08:30: «слой Hosting меняет размер на кадр-два позже формы».
- Каждый коммит контекста приложения отмечается в `context_did_change` 186de7380: `tracking_map[ctx].time
  (+0x20) = SLSCurrentRealTime`, `.seed (+0x30) = CARenderContextGetChangedSeed`. Это
  `GetLastChangeDataForContext` 186de75e4 [V]. Движок может видеть **каждый** коммит приложения (время + seed),
  а не только смену формы.

### 2.2 Родной протокол WindowManager.app → AppKit (configure/ack с забором) [V]
- `-[NSWMWindowCoordinator clientWindowManager:performResizeWindowRequest:]` 18590b688 → блок на главном runloop
  18590b75c: `[NSApp _windowWithWindowIdentifier:]`, `targetGeometry`, `springSettings` →
  **`-[NSWindow _resizeFromWindowManagerWithTargetGeometry:springSettings:completion:]`** 1857476c4.
- Внутри (1857476c4):
  - `_confirmSize:force:` — ограничения размера;
  - без пружины — один `_setFrameCommon:display:fromServer:` 184a37114;
  - с пружиной — `NSSpringAnimation` (mass/stiffness/damping/initialVelocity из настроек WM,
    `durationForEpsilon:`, `setAnimationBlockingMode:1` — неблокирующий, `_setSendProgressAllTheTime:YES`),
    **`_startLiveResize`**, на каждом шаге `currentValue` → `_setFrameCommon:display:fromServer:`, в конце
    `_endLiveResize` (блок 185747c7c).
- Ответ (блоки 18590b96c / 18590ba7c): если `requiresResponse`, то `initWithRequestID:` →
  `[WMWindowTransaction performTransactionUsingBlock:]` → блок получает `(WMWindowTransaction, CAFenceHandle)` →
  `actionForClientResizeWindowResponseActionInfo:fences:` → `addAction:`. Значит, **ack = забор (fence), сцепленный
  с CA-коммитом приложения**. WindowManager.app сцепляет с ним свою транзакцию раскладки
  (`-[_NSCGSTransaction entangleFenceHandle:]` 18591045c, `+[NSCGSWindow entanglingFenceHandle]` 18598c5b0), и оба
  коммита применяются вместе.
- **Важно для «1:1».** При пружине нативный тайлинг macOS 26 анимирует окно **силами приложения**: каждый кадр —
  настоящий `setFrame` в режиме live resize, содержимое перекладывается непрерывно. Hyprland так не делает
  (у него один configure и обрезка в боксе). Этот путь — источник идей, но не образец вида (§5.3).

### 2.3 Режим live resize: в нём приложения рисуют синхронно с рамкой
- `-[NSWindow _startLiveResize]` 184c61bac: счётчик `aux+0x258`; на первом входе — `NSWindowWillStartLiveResizeNotification`,
  `[borderView _startLiveResizeAsTopLevel]` (→ `viewWillStartLiveResize` всем видам), `_NSSetWindowKeepExcessBackingAllocation`,
  `[aux+0x2e0 setInLiveResize:YES]`, `_NSSetWindowTags`. Выход — `_endLiveResize` 184c623a4 [V].
- Строки в бинарниках [V строки, H логика]:
  - Telegram (Qt 6): `setPresentsWithTransaction:`, `inLiveResize`, `viewWillStartLiveResize`, `waitUntilScheduled`;
  - Zen (Gecko XUL): `presentsWithTransaction`, `viewWillStartLiveResize`, `waitUntilScheduled`;
  - Word: `inLiveResize`, `viewWillStartLiveResize`;
  - Ghostty: только `setDrawableSize:`/`setContentsGravity:` — синхронного режима нет.

  Это классический приём Apple для Metal: на время live resize `presentsWithTransaction = YES` и
  `waitUntilScheduled`, чтобы кадр нового размера ушёл в той же CA-транзакции, что и рамка. **[H]** Если обрамить
  наш configure `_startLiveResize`/`_endLiveResize`, Telegram и Zen начнут отдавать кадр нового размера атомарно
  с формой. Проверить вживую по шагу 3 в §6.

---

## 3. Откуда «телепорты» сейчас: механизмы

### 3.1 AppKit сама анимирует AX-размер и AX-позицию, если включён `AXEnhancedUserInterface` [V]
`-[NSWindow(NSWindowAccessibility) accessibilitySetSizeAttribute:]` 18574dcb8:
```
new = [self _frame:frame resizedFromEdge:6 withDelta:… withEvent:nil]     // ограничения как у перетаскивания края
if (_gEnhancedUserInterfaceEnabled /*1ea5e3cc8*/ != 1) return [self setFrame:new display:YES];   // обычный путь
new = [self constrainFrameRect:new toScreen:nil];
d = max(|old.w-new.w|, |old.h-new.h|);
if (d < 5)   [self setFrame:new display:YES];
else if (d < 200) { [NSAnimationContext beginGrouping]; [[NSAnimationContext currentContext] setDuration:0.1];
                    [[self animator] setFrame:new display:YES]; [NSAnimationContext endGrouping]; }
else         [[self animator] setFrame:new display:YES];                  // длительность по умолчанию
```
- Константы: 5.0 и 200.0 (`0x4069000000000000`) — непосредственные значения в коде; 0.1 — @185bba4a0.
- `accessibilitySetPositionAttribute:` 18574da00 — та же логика для позиции (те же 5/200/0.1, `animator setFrame:`).
- Флаг ставит только `-[NSApplication accessibilitySetEnhancedUserInterfaceAttribute:]` 1851e3dc0 →
  `__NSAccessibilitySetEnhancedUserInterfaceEnabled` 1851916dc (`stlrb` в 1ea5e3cc8). Значит, флаг включает
  **внешний AX-клиент** через атрибут приложения `AXEnhancedUserInterface`.
- Длительность по умолчанию **[H]**. Аниматор окна берёт `-[NSWindow animationResizeTime:]` 184c5b9d4 [V формула]:
  `t = min(0.35, 181·ln(1 + d/100) / v)` (×0.65 при флаге `aux+0x103 & 0x20`), где
  `d = max(|Δx|,|Δy|,|Δw|,|Δh|)`, `v = +[NSMoveHelper _windowAnimationVelocity]` (значение из `dispatch_once`,
  статически неизвестно). Верхний предел — 0.35 с.

**Что это даёт при включённом флаге.**
- Демон делает `ax_frame` (позиция → размер → позиция).
- Приложение 0.1–0.35 с само ведёт окно через промежуточные рамки. Каждая из них — новый CA-коммит с новой
  формой и своим содержимым.
- Движок (`anim4.c` 1335–1368) снимает «держание» по **первой** смене формы и стартует. Дальше форма A и
  содержимое продолжают меняться **посреди нашего хода**: телепорты, пульсирующая обрезка `cw=min(bw,aw)`,
  ложные «стабилен N тиков» и ложные минимумы (F7).
- AX-позиция при устаревшей у AppKit рамке (после нашего серверного `CGXMoveWindowList`, флаг F_MOVE) даёт сдвиг
  ≥5 pt, и AppKit анимирует **перемещение** обратно-вперёд за 0.1 с [H, следствие из листинга].

**Как убрать (то, что делает yabai).** Перед `ax_frame` прочитать у элемента приложения `AXEnhancedUserInterface`.
Если `true` — выставить `false`, сделать `ax_frame`, вернуть `true`. Либо ставить рамку изнутри (§4), минуя AX-сеттер.

### 3.2 Старт по смене формы, а не по готовому содержимому [V код]
`anim4.c:1335–1368`: пачка держится, пока у окон с `needs` не изменится форма (`|aw−a0|<0.5 && |ah−a0|<0.5` →
ждать), не дольше `hold_max` (0.2 с, `engine.py:157`). Popin (`F_WAIT`) ждёт форму ≈ плитке (`settle_px` 8).
Форма — это ещё не содержимое. У Ghostty (Metal в своём потоке, без `presentsWithTransaction`) и у приложений с
отложенной отрисовкой форма меняется раньше кадра. Ход стартует, кадр приходит посреди хода — телепорт.
Подтверждение содержимого (§4.2) заменяет это условие точным.

### 3.3 Маска отстаёт от слоя Hosting на кадр при смене высоты [V код + QuartzCore]
- `put_mask` (`anim4.c:317–363`) ставит маску `{hb.x, hb.y + hb.h − hh, cw, hh}` по `bounds` слоя Hosting,
  прочитанным **в нашем тике** (ось Y вверх, `mask_flip`).
- Bounds слоя Hosting меняет ingestion WindowServer (`ca_window_prep_ingestion_phase` 186e23c1c, бит 3 →
  `setBounds` всем слоям, compositor.md §1б) в своём проходе `UpdateDisplays` — позже нашего тика.
- В кадре, где у окна меняется высота H→H+Δ, низ маски остаётся на старом расстоянии от **низа** слоя. Видимая
  область сдвигается на Δ на один кадр: окно «прыгает» на высоту изменения. По ширине так не бывает, потому что
  ось X идёт от левого края.
- **Исправление без подтверждения** [V механизм]. `CA::Layer::set_bounds` (QuartzCore @18a5fdc04–18a5fdc7c) при смене
  bounds, если у слоя не стоят флаги `0x60000`, зовёт `-[CALayer resizeSublayersWithOldSize:]` 18a5fddc4. Тот
  обходит подслои **и маску** (`CA::Layer::mask` @18a5fde54 → `resizeWithOldSuperlayerSize:` @18a5fde84).
  Достаточно один раз выставить маске `autoresizingMask = kCALayerMinYMargin` (8: гибкий нижний отступ =
  привязка к верхнему краю). Тогда setBounds от WindowServer сам переставит маску в той же транзакции. Так же
  стоит выставить кольцу/тени/заливке в Server root (`kCALayerMinYMargin`; ширину/высоту по-прежнему ставит тик).
  **[H]** Что у Hosting нет флагов `0x60000`: проверить чтением `*(u32*)(layer_impl+4)` или просто опытом.

### 3.4 Сдвиг трансформа считается от фактического начала окна [V код]
`put_xform(c, w, sx, sy, (w->ax − bx)·sx, (w->ay − by)·sy)` (`anim4.c:1052`). Если коммит приложения меняет
**начало** окна (анимация позиции из §3.1; `setContentSize:` сохраняет нижний левый угол в координатах Cocoa;
асинхронное применение размера), то сервер пересоберёт трансформ с новым началом (`window_update_transform`), а
наш сдвиг до следующего тика старый. Получается кадр со смещением на Δ начала. Лечится не в движке, а у источника:
атомарный `setFrame` изнутри, который сохраняет верхний левый угол (§4.1), и выключенный аниматор (§3.1).

### 3.5 Задуманный скачок: сжимающаяся сторона сразу
`hyprwm.py:414–418` (`SHRINK_SNAP`, по умолчанию 1): стартовая рамка сразу обрезается по цели на сжимающейся оси.
Это осознанная замена прыжка «обои в полосе» (PROGRESS 13:45). Когда `frame_bounds` будет раздут
(beyond_bounds §1.7) и подтверждение даст старт с новым содержимым, этот скачок можно вернуть к анимации.

---

## 4. Идея 1 по существу: свой configure/ack через модуль в приложении

### 4.1 Что даёт «размер изнутри» (настоящий configure)
Механизм — то, что AppKit делает для WindowManager.app (§2.2), без пружины. На главном потоке приложения:

1. `size = [win _confirmSize:target force:YES]` (184ad6edc → `_validSize:force:` 184ad6fdc →
   `_validSize:forFullScreen:force:` 184ad7030). Учитываются: `minSize/maxSize`, ограничения Auto Layout
   (`_getConstrainedWindowMinSize:maxSize:`), `resizeIncrements` (сетка Терминала, `_quantizeOneDimension`),
   `aspectRatio`, `contentMin/MaxSize`, `tilingState`, а также делегат `windowWillResize:toSize:` (через
   `_confirmSize`) [V вызовы]. **Это и есть ответ «какой размер ты примешь» до раскладки.** Модуль отдаёт его
   демону, и `tile.py` раскладывает с настоящими минимумами и сеткой. Отпадают выучка минимумов, ложный
   «Терминал [0,455]», вторая волна (F7/P2) и «держу в плитке» у окна с известным минимумом.
2. (По желанию, только для приложений, где это помогает.) `[win _startLiveResize]`.
3. `[win setFrame:rect display:YES]` (184a3701c): позиция и размер **одним** коммитом, верхний левый угол
   неподвижен, аниматора нет, отрисовка синхронная (`display:YES`). Без тройного AX «позиция → размер → позиция»
   и без анимации из §3.1.
4. Подтверждение — §4.2. Потом (если было п.2) `_endLiveResize`.

**Чего не даёт [V/H].** Приложение быстрее рисовать не станет. Если Telegram раскладывается 100 мс, ответ придёт
через 100 мс. Выигрыш: минус AX-круг (AX-сообщение и так исполняется на главном потоке приложения), минус
анимация AppKit (до 0.35 с), минус промежуточные рамки, плюс синхронная отрисовка в live resize у Qt/Gecko/Word [H].

### 4.2 Что подтверждать и как узнать готовность содержимого
| Класс приложения | Когда кадр нового размера готов | Как модулю узнать | Атомарно с формой? |
|---|---|---|---|
| AppKit рисует сам (Finder, TextEdit, Терминал, SwiftUI) | в том же CA-коммите, что и форма (`setFrame:display:YES` → отрисовка до коммита) | `+[CATransaction addCommitHandler:forPhase:]` 18a604618 (фаза post-commit), поставленный сразу после `setFrame` | да [V путь method 3; H что отрисовка попадает в тот же коммит у всех] |
| Qt 6 (Telegram), Gecko (Zen), Word — с live resize | в live resize — синхронно, `presentsWithTransaction` (строки §2.3) | как выше, внутри `_start/_endLiveResize` | [H] — проверить шагом 3 |
| CAMetalLayer в своём потоке (Ghostty) | позже, когда поток отрисовки отдаст drawable размера `drawableSize` | перехват `-[CAMetalLayer nextDrawable]` + `-[MTLCommandBuffer presentDrawable:]`/`-[CAMetalDrawable present]`: drawable с `texture.width/height == layer.drawableSize` | нет (present идёт мимо CA-транзакции); погрешность ±1 кадр [H] |
| Не знаем, как рисует | — | на стороне WindowServer: `GetLastChangeDataForContext(ca_client_context_id)` — seed вырос ≥1 после смены формы и N мс тишины | нет (эвристика, как сейчас, только точнее) |

Насильно включать `presentsWithTransaction` у Ghostty **не рекомендую** [H, риск]: present идёт из потока Zig без
runloop. Неявная CA-транзакция там может не закоммититься, и содержимое застынет.

### 4.3 Транспорт: как configure доходит до модуля, а ack — до движка
Ограничение: Telegram и другие приложения в песочнице. inject.py уже кладёт модуль в контейнер, потому что
открыть файл вне контейнера нельзя. Mach-lookup к нашему демону песочница почти наверняка закроет [H].

- **configure — через тот же AX (рекомендую).** Модуль подменяет (swizzle)
  `-[NSWindow accessibilitySetPositionAttribute:]` и `…SetSizeAttribute:` (§3.1). Позицию запоминает, на размер
  применяет **полную** рамку одним `setFrame:display:` по §4.1, без аниматора. Демон не меняется: тот же
  `ax_frame`, AX-транспорт работает в любой песочнице. «Вопрос» о точном размере — как отдельный
  AX-атрибут: модуль отвечает на свой `AXHyprConfirmSize` (подмена `accessibilityAttributeValue:` или
  `accessibilitySetValue:forAttribute:`) [H: что AppKit передаёт неизвестное имя атрибута в эти методы —
  проверить одним вызовом].
- **ack — через WindowServer, движок читает напрямую (рекомендую).** Модуль ставит своему окну свойство:
  `SLSTransactionSetWindowProperty(txn, wid, CFSTR("hyprwm.ack"), CFNumber(packed w,h | seq))` 186dce220 [V сигнатура:
  x1=wid, x2=key, x3=value]. Сервер: `PKGTransactionSetWindowProperty` 1870ca710 → проверка доступа
  `_PKGTransactionCheckWindowAccess(conn, wid, 1, 0x15, 0)` (своё окно — проходит) → `WSWindowSetUntrustedProperty`
  187071d6c. Зарезервированные ключи отсеиваются через `CFEqual`, свой ключ уходит в `CGXWindow::set_property`
  18705b90c. Для неизвестного ключа это просто `CFDictionarySetValue`, без уведомлений и перерисовок [V].
  Движок в тике читает `WSWindowGetProperty(win, key, &v, …)` 187071b5c → `CGXWindow::get_property` 18705a140 —
  только у окон в состоянии «держу».
  - Коммитить методом 1 (`SLSTransactionCommit`, отдельное сообщение — безопасно, погрешность ±1 кадр) или
    `SLSSetWindowProperty` 187022470.
  - **Не коммитить методом 3 своей транзакцией** [H, риск]. `setPayload:` добавляет команду в тот же
    CA-коммит, что и payload AppKit. Если сервер хранит у контекста один payload, вторая команда может затереть
    форму AppKit. Атомарную метку (в том же коммите, что форма) делать только через транзакцию самой AppKit:
    `+[_NSCGSTransaction currentTransaction]` 184ae4204 / `NSCGSTransactionAddAction` 184ae4724 [V существование,
    H сигнатура].
- **Забор (fence) как у WindowManager.app** — не нужен. Потребитель забора — CA-коммит другого контекста.
  Сцепить наш **локальный** контекст WindowServer (маска/кольца) с забором приложения статически не доказано
  [H]. Политика §4.4 обходится меткой.

### 4.4 Политика движка с подтверждением (что видит пользователь)
1. **Строго как Wayland по смыслу: «буфер под размер до хода».** Держать старт пачки до метки содержимого
   (не до смены формы), предел — `T_hold`. Все окна стартуют в одном кадре (A1 сохраняется).
   - Цена: задержка старта = задержка приложения.
   - Когда приложение отвечает за 1–2 кадра (быстрый путь §3.1 + §4.1), разницы с Hyprland нет: там подмена
     приходится на кадры 1–2 хода.
   - Предлагаю `T_hold` = 2 кадра (33 мс) по умолчанию, а не 200 мс. Сейчас 200 мс — это задержка, которую
     пользователь уже называл «подвисанием» (P10).
2. **Хвост медленных приложений (метки нет за `T_hold`).** Ход стартует со старым содержимым (буфер 1:1 в маске, как
   Hyprland). Когда метка придёт посреди хода — **короткий кроссфейд 3–5 кадров**: клон старого содержимого
   (`CreateCloneOfWindow`, уже есть машинерия P8/`OP_SNAP`) **поверх** окна, в той же маске/боксе, α→0.
   Не 1:1 (в Hyprland подмена мгновенная, но ранняя), зато без «бац». Прежняя отвергнутая «подложка-снимок» была
   **под** окном и тянула край — это другое.
3. **Не делать**: держать до конца хода и подменять в конце (отвергнуто пользователем как «превращение в конце»).

### 4.5 Вердикт по идее 1
| Часть идеи | Вердикт | Основание |
|---|---|---|
| Модуль в приложении сам ставит размер | **подтверждаю**, это путь Apple | §2.2 [V]; атомарная рамка, нет аниматора AX (§3.1 [V]) |
| Модуль заранее знает итоговый размер | **подтверждаю**, сильнейший выигрыш | `_validSize:force:` [V]; убирает выучку минимумов и вторую волну |
| Подтверждение, какой кадр к какому размеру | **подтверждаю частично** | форма атомарна уже сейчас [V]; содержимое — метка-свойство [V путь] + детектор готовности по классу приложения [H для Metal/Qt] |
| «Это уберёт телепорты» | **опровергаю как самостоятельное средство** | подтверждение не ускоряет приложение; без быстрого пути выбор — задержка старта или подмена посреди хода (§4.4) |
| Атомарная подмена в WindowServer «как в Wayland» | **частично** | для приложений, которые рисуют синхронно, — да (method 3); для Metal в своём потоке — ±1 кадр, атомарность только с live resize / `presentsWithTransaction` [H] |

---

## 5. Смежные варианты: проверено и отвергнуто или отложено

### 5.1 `SLSDisableUpdate` / `SLSReenableUpdate` вокруг смены размера — отложить
[V] Классический приём macOS. `_SLSDisableUpdate` 186edb7bc → `__CGSDisableUpdateForConnection` →
сервер `disable_update_for_connection` 186e0a4e0: `conn+0xb4`++, таймер `disable_update_timeout`, предел
`gWSDisableUpdateTimeout` = **1.0 с** (float @1ea5f6084, прочитано из файла). `ca_prepare_begin_window_update`
(defenestrator3) 186e26e34 читает `+0xb4` соединения [V по списку загрузок]. **[H]** Пока обновления выключены,
окна приложения не обновляются целиком, включая наши трансформ и маску. Годится только для фазы держания
до старта, а её и так даёт метка. Риск — заморозка всех окон приложения до 1 с.

### 5.2 Выдавать себя за WindowManager.app — не делать
`_WMClientResizeWindowRequest` приходит в AppKit через `WMClientWindowManager` (FrontBoard/BSService). Это
соединение держит WindowManager.app. Через lldb-мост было 250 мс (resize_re.md). Тот же эффект модуль получает
прямым вызовом `_resizeFromWindowManager…`/`setFrame` у себя в процессе (§4.1).

### 5.3 Анимировать рамку силами приложения (пружина AppKit, как нативный тайлинг) — не как основной путь
[V §2.2] Можно звать в модуле `NSSpringAnimation` + `_startLiveResize` + `setFrame` по кадрам с пружиной Hyprland
(m1 k210 d24). Несовпадений «кадр ↔ размер» не будет вообще. Против:
- содержимое перекладывается каждый кадр, а у Hyprland — обрезка готового буфера;
- у каждого приложения свои часы (`NSAnimation`, не vsync WindowServer) — нет общего t0 (A1);
- тяжёлые приложения (Telegram, Word) будут дёргаться на каждом кадре.

Вывод: не 1:1. Можно оставить как режим для лёгких приложений, если пользователь захочет посмотреть.

### 5.4 `window_list_set_locked_bounds` / заморозка (beyond_bounds §2) — дополняют, не заменяют
locked bounds пересчитывает масштаб в кадре коммита (атомарно), но это **растяжение**, которое пользователь не
принимает. Заморозка — тоже растяжение. Обе нужны только как запасной путь для хвоста медленных приложений
вместо кроссфейда §4.4 п.2 — по выбору пользователя на A/B.

---

## 6. План проверки (для основного агента, по порядку; каждый шаг — до/после rec2 + журнал траектории)

**Шаг 0 — дёшево, решающе, только чтение.** Для каждого тайлового pid (Ghostty, Telegram, Word, Zen, Finder,
Терминал): `AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), CFSTR("AXEnhancedUserInterface"))`.
- Если где-то `true` — §3.1 подтверждён как причина «30–500 мс» у этих приложений.
- Затем в `ax_frame` (`axlib.c:73`): прочитать флаг → `false` → три вызова → вернуть. Замер «AX → форма стабильна»
  по журналу траектории: ожидаю 140–160 мс → 1–3 кадра у Ghostty и 350–500 → ≤100 мс у Word.
- Параллельно найти, кто включает флаг: список AX-клиентов — Системные настройки → Конфиденциальность →
  Универсальный доступ.

**Шаг 1 — маска и кольца привязаны к верху** (§3.3). `autoresizingMask = 8` маске Hosting и слоям в Server root при
создании. Сценарий: togglesplit h↔v (меняется высота), rec2 120 к/с. Критерий — 0 кадров со сдвигом видимой
области на Δh в момент смены формы (сейчас ожидаю 1 такой кадр на событие).

**Шаг 2 — замер внутри приложения (без поведения).** В `hyprforce` — только `os_log` с `mach_absolute_time`:
- приход AX-размера;
- `setFrame` начат и закончен;
- `CATransaction` post-commit;
- у Metal-слоёв — `nextDrawable`/`present` с размером текстуры.

Читать `log stream --predicate 'eventMessage CONTAINS "hyprsync"'`. Это раскладывает 30–500 мс на AX, AppKit,
рендер и WindowServer и решает, что делать дальше.

**Шаг 3 — перехват AX-сеттеров в модуле** (§4.3). Атомарный `setFrame:display:YES` без аниматора; опционально
обрамление `_startLiveResize`/`_endLiveResize` — A/B на Telegram и Zen. Критерий: одна смена формы на событие
(сейчас при флаге из §3.1 — десятки); у Telegram время до кадра нового размера в live resize меньше, чем без него.
Риск: `_endLiveResize` может вызвать финальную «чистовую» перерисовку — смотреть, нет ли второй подмены
содержимого в конце.

**Шаг 4 — запрос точного размера** (`_validSize:force:` через AX-атрибут или ответ модуля). Демон раскладывает с
настоящими минимумами и сеткой. Критерий: в логе нет «минимум …: выучен» и «держу в плитке» у окон с известными
ограничениями; одна пачка на событие (F7).

**Шаг 5 — метка подтверждения и старт по ней** (§4.3–4.4). Модуль: `SLSTransactionSetWindowProperty("hyprwm.ack")`
после post-commit (AppKit) или после present нужного размера (Metal). Движок: в цикле держания (`anim4.c:1335`)
вместо «форма изменилась» — «`hyprwm.ack` == цель», `T_hold` = 2 кадра. Критерий: rec2 — подмена содержимого не
позже 2-го кадра хода у Finder/TextEdit/Терминала и (после шага 3) у Telegram; у Ghostty — по замеру шага 2.

**Шаг 6 (если останется хвост) — кроссфейд клона поверх** при метке посреди хода (§4.4 п.2), 3–5 кадров.
Сравнить с locked bounds на видео. Решает пользователь.

---

## 7. Справочник адресов

| Что | Адрес | Метка |
|---|---|---|
| AppKit `-[NSWindow(NSWindowAccessibility) accessibilitySetSizeAttribute:]` | 18574dcb8 | V (ветки 5/200/0.1, `animator`) |
| AppKit `…accessibilitySetPositionAttribute:` | 18574da00 | V |
| AppKit `_gEnhancedUserInterfaceEnabled` (глобал) | 1ea5e3cc8 | V |
| AppKit `-[NSApplication accessibilitySetEnhancedUserInterfaceAttribute:]` → `__NSAccessibilitySetEnhancedUserInterfaceEnabled` | 1851e3dc0 → 1851916dc | V |
| AppKit `-[NSWindow animationResizeTime:]` (`min(0.35, 181·ln(1+d/100)/v)`) | 184c5b9d4; константы 185bbc980 (181), 185bbc068 (0.35), 185bbe2c8 (0.65) | V формула; v — H |
| AppKit `-[NSWMWindowCoordinator clientWindowManager:performResizeWindowRequest:]` + блоки | 18590b688; 18590b75c, 18590b96c, 18590ba7c | V |
| AppKit `-[NSWindow _resizeFromWindowManagerWithTargetGeometry:springSettings:completion:]` + блок | 1857476c4; 185747c7c | V |
| AppKit `-[NSWindow _startLiveResize]` / `_endLiveResize` | 184c61bac / 184c623a4 | V |
| AppKit `-[NSWindow _confirmSize:force:]` / `_validSize:force:` / `_validSize:forFullScreen:force:` | 184ad6edc / 184ad6fdc / 184ad7030 | V |
| AppKit `-[NSWindow setFrame:display:]` / `_setFrameCommon:display:fromServer:` | 184a3701c / 184a37114 | V |
| AppKit `+[_NSCGSTransaction currentTransaction]` / `NSCGSTransactionAddAction` / `_NSCGSTransactionRunPreCommitActions_` | 184ae4204 / 184ae4724 / 184b0fc18 | V существование |
| AppKit `-[_NSCGSTransaction entangleFenceHandle:]` / `+[NSCGSWindow entanglingFenceHandle]` | 18591045c / 18598c5b0 | V существование |
| QuartzCore `+[CATransaction addCommitHandler:forPhase:]` | 18a604618 | V существование |
| QuartzCore `-[CAContext setFencePort:]` / `createFencePort` / `+[CAFenceHandle newFenceFromDefaultServer]` | 18a9574e0 / 18a957554 / 18a83ee40 | V существование |
| QuartzCore `CA::Layer::set_bounds` → `resizeSublayersWithOldSize:` (если `!(flags & 0x60000)`) | вызов @18a5fdc7c | V |
| QuartzCore `-[CALayer resizeSublayersWithOldSize:]` (подслои + маска) | 18a5fddc4 (маска @18a5fde54/…e84) | V |
| QuartzCore `-[CAContext setPayload:]` → `CA::Transaction::add_command` | 18a958524 | V |
| SkyLight `sls_transaction_commit_ca` (setPayload на «fencing context») | 186ddbc80 | V |
| SkyLight `WS::CA::callback::context_payload_did_change` | 186de6f40 | V |
| SkyLight `…context_did_change` (tracking time/seed, `WSScheduleUpdateForCAContextChange` 186f91de8) | 186de7380 | V |
| SkyLight `WS::CA::GetLastChangeDataForContext` (time +0x20, seed +0x30) | 186de75e4 | V |
| SkyLight `CGXConnectionPayloadOperationQueue::_scheduleExecutionForSession` → `WSMainThreadBlockHoistEnqueueBlock` | 186de4f98 → 186e2f1e4 | V |
| SkyLight `_SLSTransactionSetWindowProperty(txn, wid, key, value)` / `_SLSSetWindowProperty` | 186dce220 / 187022470 | V |
| SkyLight `PKGTransactionSetWindowProperty` → `WSWindowSetUntrustedProperty` → `CGXWindow::set_property` | 1870ca710 → 187071d6c → 18705b90c | V |
| SkyLight `WSWindowGetProperty` → `CGXWindow::get_property` | 187071b5c → 18705a140 | V |
| SkyLight `_SLSDisableUpdate` / `_SLSReenableUpdate` / `disable_update_for_connection` / таймаут 1.0 с | 186edb7bc / 186edb92c / 186e0a4e0 / 1ea5f6084 | V |
| Код движка: держание старта / маска / трансформ | `anim4.c:1335–1368` / `:317–363` / `:1052` | V |
| Код AX: `ax_frame` (позиция → размер → позиция), флаг Enhanced UI не трогается | `axlib.c:73–91` | V |
| Hyprland: configure сразу со стартом / ack-учёт / UV-обрезка | `WindowTarget.cpp:252–256, 461–467`; `WaylandBackend.cpp:142–147, 304–324, 441–447`; `ElementRenderer.cpp:42–57, 61, 111–123` | V |
