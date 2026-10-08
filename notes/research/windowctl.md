# windowctl: протокол перемещения/ресайза, configure/ack, hit-test (macOS 26.7.1, arm64e)
Статус: ГОТОВО 2026-10-08. Только статика: /tmp/sl_dis.txt, /tmp/sl_map.tsv, extracted/*.
Метки: [V] проверено по листингу (адрес указан), [гипотеза] — не проверено.


## Что видит пользователь / что даст (коротко)
1. **Клики во время анимации уже попадают правильно** для обычных AppKit/SwiftUI-окон: сервер сам проецирует точку клика через
   трансформ окна (+0x498) и через нашу обрезку B (+0x110), а AppKit берёт локальную точку, посчитанную сервером. Промахи возможны в 3 случаях:
   (а) Catalyst-приложения (legacy-путь AppKit игнорирует ЧИСТЫЙ СДВИГ трансформа); (б) клик в момент, когда AX-configure как раз сменил
   frame приложения (AppKit пересчитывает точку по своему frame); (в) запаздывание ≤1 кадра: hit-test видит трансформ кадра te, экран — ещё прошлый.
2. **Родной «configure-ack» найден**: приложение коммитит новый размер транзакцией `SetWindowShape`, вложенной в CA-коммит (method 3),
   сервер применяет форму и контент атомарно и шлёт 807 kCGSWindowDidResize. Демону можно перестать опрашивать и ждать 807 (подписка),
   движку — ловить смену bbox(+0x170) (уже так).
3. **Locked bounds — серверный «растянуть буфер в рамку L»**, им пользуется WindowManager.app. Пересчитывается сервером в момент коммита
   приложения → нет кадра «старый буфер в новой рамке не того масштаба». Кандидат на popin/ресайз-растяжение вместо нашей матрицы.
4. Двигать окна сами — уже умеем (CGXMoveWindowList); WM.app делает это через `WSMoveWindowWithGroupByOffset` (тянет дочерние/sheet).
   Менять РАЗМЕР чужого буфера сервер не может в принципе — только просить приложение (AX или BSService WM.app).

## Журнал находок (по ходу)

### [V] Hit-test (п.3) — цепочка подтверждена по листингу
- `-[WSMouseEventProcessor event_find_window:]` 0x186def50c: берёт глобальную точку события `rec+0x10` (SLSEventRecord),
  зовёт `WSFindWindow(NULL, pt, 1, mode, &local)` 0x18706c788; результат: wid → `rec+0x3c`, локальная точка → `rec+0x20`
  (str q0,[x19,#0x20] @0x186def73c). То есть в событии приложению уходит ЛОКАЛЬНАЯ точка, уже пересчитанная сервером.
- `WSFindWindow(CGXWindow* after, CGPoint scr, int, int mode, CGPoint* outLocal)` 0x18706c788: обходит z-список окон
  (`*(gGlobal+0x20)->+0x90` : +0x38 массив, +0x40 count), пропускает `*(*(gGlobal+0x20)+0x100)` (окно курсора [гипотеза]),
  для каждого `WSWindowHitTest`; код 0xb..0xf = попадание, остальное — идём дальше.
- `WSWindowHitTest(CGXWindow* w, CGPoint scr /*d0,d1*/, int mode /*w1*/, CGPoint* outLocal /*x2*/)` 0x18706c2e4, коды:
  1) `CGXTransformPointToWindow(w, scr, outLocal)` 0x18706c57c;
  2) `w+0x110` (итоговая глобальная обрезка, ЭКРАННЫЕ коорд.) не содержит scr → 3 (мимо);
  3) `w+0x1dc` (float альфа окна) < порога → 9 (мимо);
  4) экранная форма контента `*(w+0x1a8)+0x18` (кэш, пересчёт через `CGXCopyScreenContentShapeForWindow` если `w+0xc4` ≠ `*(w+0x1a8)+0x54`) не содержит scr → 6;
  5) локальная форма `w+0xe8` не содержит outLocal → 7;
  6) иначе по альфе пикселя `CGXWindow::alpha_at_point(outLocal)` → 0xf попадание / 0xa прозрачно (мимо).
- `CGXTransformPointToWindow` 0x18706c57c: если `(w+0x92c bit4)` или `w+0x878 == NULL` (нет warp-меша) →
  `WSWindowTransformProjectScreenPointToWindow(w+0x498, scr)` 0x186ed8428 (4x4 double, проекция по лучу z, перспектива учтена);
  иначе — обход сетки меша `w+0x878` (ячейки по 0x120). ПРЕДЫДУЩАЯ НАХОДКА ПОДТВЕРЖДЕНА.
- `w+0x498` пишет только `window_update_transform` 0x186e4e574 (concat стека трансформов + origin формы, @0x186e4e908..0x186e4e988,
  затем инверсии в +0x518/+0x598/+0x618/+0x698/+0x718). Наш `CGXSetWindowTransform3DList` 0x186e4fcf4 → блок 0x186e4fe9c →
  `window_set_transform` ×3 → ХВОСТОВОЙ `b _window_update_transform` @0x186e4ffc0. Блок возвращает «изменилось» →
  `accumulate_window_display_updates` 0x186e4f620 инкрементит `w+0xc4` (screen geometry seed) @0x186e4f758 → кэш экранной формы
  в hit-test пересчитается. Т.е. трансформ, поставленный нашим путём, hit-test видит СРАЗУ (тот же вызов).
- Экранная форма: `CGXCreateScreenContentShapeForContentShape` 0x186f2d508 = `WSWindowGetTransform` + `WSWindowGetMesh` →
  `create_screen_region_with_window_region(mesh, M, clip=WSWindowGetClipShape(w)=w+0xe8, ...)`.
- `w+0x110` = пересечение `w+0x160` (наша `set_window_list_global_clip_shape` 0x18705f624) и `w+0x148`
  (`CGXWindow::update_global_clip_shape` 0x18705f248). Значит НАША обрезка по видимой рамке B режет и клики: клик вне B
  проваливается в окно ниже (код 3). set_window_list_global_clip_shape тоже инкрементит +0xc4 (@0x18705f800).
- Захваченная мышь (drag после mouse-down, `annotate_internal` 0x186def380..0x186def3b4): для захваченного окна сервер
  каждый раз заново считает `rec+0x20` через `CGXTransformPointToWindow` + `CGXSetEventWindowHeightForWindow`.
  Tracking/cursor-регионы: `WSSessionStructuralRegionData::find_inside_regions` тоже зовёт CGXTransformPointToWindow (0x1870e12e4).
- `CGXSetEventWindowHeightForWindow(rec, w)` 0x186ee8190: `rec+0xd8` = (int) высота bbox реальной формы `w+0x170` (не видимой B).

### [V] Как AppKit превращает событие в locationInWindow (AppKit, стабы разрешены через `ipsw dyld disass --vaddr`)
`-[NSEvent _initWithCGEvent:eventRef:]` 0x184b172b4:
- Окно: поле 0x92 (contextID) → `[NSApp _windowWithContextID:]`, иначе поле 0x33 (windowNumber) → `windowWithWindowNumber:`.
- Флаг `NSEventUseLegacyEventLocationAdjustment` (кэш `_MergedGlobals.21` 0x1ecfa9980; 1 = legacy, 2 = современный путь).
- СОВРЕМЕННЫЙ путь (0x184b17574): обычный случай — `SLEventGetWindowLocation` (= `rec+0x20`, SkyLight 0x186df0930,
  то, что посчитал СЕРВЕР через трансформ). Исключение (0x184b17608..0x184b17664): если `event.timestamp <
  [NSCGSWindow lastFrameChangeTimestamp]` — пересчёт `convertCGScreenLocationToCGWindowRelativePoint:` по СВОЕМУ frame
  приложения (трансформ НЕ учитывается!). Если у события есть contextID (0x92) — `SLSGetCatenatedWindowTransform(cid,wid,&m)`
  и аффинная проекция глобальной точки (трансформ учитывается). Потом y = frame.height − y (высота из AppKit frame).
- LEGACY путь (0x184b173c4): `convert...RelativePoint:` по frame; если разошлось с серверной точкой > 1e-3 —
  `SLSGetCatenatedWindowTransform`, но берётся ТОЛЬКО если в матрице есть масштаб (a≠1 или d≠1); при чистом сдвиге —
  точка по frame (трансформ-сдвиг игнорируется).

### [V] п.1: что шлёт WindowManager.app в WindowServer (импорты `extracted/wmapp/WindowManager`, `nm -u`)
- WM.app НЕ импортирует SLSMoveWindowList / SLSSpaceSetRect / SLSPackagesSetWindowConstraints. Всё геометрическое — через
  `SLSTransaction*` (+ `NSSLSTransaction`), коммит `SLSTransactionCommit/CommitUsingMethod` → сервер `_XTransactionCommitSync`
  0x1871987bc / `_XTransactionCommitAsync` 0x1871988b8 → `PKGTransactionCommit` 0x1870be7b8 → опкоды `PKGTransactionOpcodeInfos` 0x1eecdc2b8.
- Ops для окон из WM.app (обёртки-«switch» Swift 0x100294318..0x1002943f8, jump-table 0x100294b44..): SetWindowLockedBounds(AtPlace),
  ClearWindowLockedBounds(AtPlace), SetWindowTransform3D, MoveWindowWithGroup, MoveWindowForServerSideDrag, SetWindowGlobalClipShape,
  SetWindowWarp, SetWindowTransform, DeferWindowMoveEvents, OrderWindow, Add/RemoveWindowToSpace, SetWindowAlpha/SystemAlpha/SystemCornerRadius/...
- Размер ЧУЖОГО окна WM.app серверу не задаёт: только запрос приложению `_WMClientResizeWindowRequest` по BSService (resize_re.md §4a);
  в строках WM.app: `ApplicationClientResizeWindowRequestRegistry`, `awaitResponseForResizeRequest`, `ClientFenceGroup`,
  `LayoutDeferredFenceTracker`, `_lockedBounds`, `isInAgentLiveResize`. [гипотеза по строкам: на время ресайза WM.app ставит
  locked bounds = целевой rect, ждёт ответ с fence, снимает locked bounds — порядок вызовов в Swift не трассирован].

Серверные обработчики (сигнатуры по листингу):
- `PKGTransactionMoveWindowWithGroup` 0x1870c8d48: декодирует (wid, x, y — АБСОЛЮТНАЯ точка), проверка `_PKGTransactionCheckWindowAccess(conn,wid,5,0x11,0)`,
  dx = x − `WSCurrentUntransformedWindowBounds(win)`.x → `WSMoveWindowWithGroupByOffset(conn, win, NULL, dx, dy)` 0x186fb10f0
  (двигает окно вместе с группой — дочерние/sheet-окна; наш CGXMoveWindowList 0x18706b734 их НЕ тянет [гипотеза — проверить на окне с sheet]).
- `PKGTransactionSetWindowLockedBounds` 0x1870c915c: (wid, CGRect, place u32) → access(…,4,0x19,0) →
  `window_list_set_locked_bounds(CGXConnection* conn, const u32* wids, u32 n, const CGRect* rects, u32 nrects(==n), u32 place)` 0x186e50174
  → блок 0x186e502b8: запись в стек трансформов окна (`WSWindowGetTransformStack`, слот +0x10 обычный / +0x18 если conn+0x2f0 bit4):
  `{u32 connID; CGRect L @+8; u32 place @+0x28}`; CGRectNull — снять. place==0 → сбросить системные слоты 0x1ffffffe/0x1ffffffd. Затем `window_update_transform`.
- В `window_update_transform` 0x186e4e574 (стек `win+0x798`): если есть locked bounds, @0x186e4e640..0x186e4e694:
  scale = bbox(win+0x170).size / L.size, translate = −L.origin·scale → CATransform3DMakeAffineTransform, вставляется в стек на позиции place
  (concatenate_all_transforms 0x186e4ec20). ИТОГ: сервер сам растягивает ТЕКУЩИЙ буфер окна в прямоугольник L и ПЕРЕСЧИТЫВАЕТ это при каждой
  смене формы: `CGXWindow::set_shape_internal` (0x18705f3xx) зовёт `window_update_transform` (@0x18705f50c/570/594). То есть когда приложение
  закоммитит новый размер, масштаб пересчитается в той же серверной операции — без кадра «не того» размера.
- `WSMoveWindowWithGroupByOffset(CGXConnection* conn, CGXWindow* w, void* /*NULL у WM-пути*/, double dx, double dy)` 0x186fb10f0:
  `countMovementGroup_recursive(w)` → двигает всю movement-группу (WM.app явно управляет ей: `CGSAddWindowToWindowMovementGroup`).

### [V] п.2: как приложение коммитит новый размер и где WS это видит (аналог ack/commit)
- AppKit: `-[NSCGSWindow(NSCGSWindowGeometry) setFrame:]` 0x18598f818 только помечает свойство (`_NSCGSWindowMarkProperty_` 0x18598d180).
  Сброс — блок `__NSCGSWindowMarkProperty__block_invoke_2` 0x185991370: `CGRegionCreateWithRect` → `SLSTransactionSetWindowShape(txn, wid, region)`
  @0x1859919f8 (там же SetWindowTransform/Warp/Alpha/CornerRadius/ResizeEventShape... — всё одним SLSTransaction).
- Коммит: `_NSCGSTransactionRunPreCommitActions_` 0x184b0fc18 → `SLSTransactionCommitUsingMethod(txn, async ? 3 : 1)` @0x184b0fd30.
  SkyLight 0x186ddbb24: method 3 → `sls_transaction_commit_ca(txn, true)` (транзакция уезжает ВНУТРИ CA-коммита приложения как payload),
  1/2 → обычный `SLSTransactionCommit`. На сервере CA-payload: `WS::CA::callback::context_payload_did_change` (0x186de709c) /
  `CGXConnectionPayloadOperationQueue::_executePayloadsOnSession` (0x186de52e4) → `PKGTransactionDecodeCAPayload` 0x1870cb188 → `PKGTransactionCommit`.
  ВЫВОД: новая форма окна и слой с контентом нового размера применяются сервером в ОДНОЙ операции (это и есть родной commit/ack;
  [гипотеза: что для live-resize AppKit идёт именно async=method 3 — по коду выбор `x20==0 → 3`; какой x20 при обычном setFrame не трассировал]).
- Сервер: `PKGTransactionSetWindowShape` 0x1870ca3f4 → регион сдвигается на bbox текущей формы (локальные → глобальные) →
  `CGXWindow::shape_window` 0x187060158: `CGXBackingStoreResize`, `set_shape_internal` (→ `window_update_transform`, `w+0xc4`++),
  `set_clip_shape_internal`, инвалидация, `CGXPostWindowNotification(w, 0x327)` @0x1870604c4.
- Номера уведомлений сверены по jump-table `WSLogStringForNotifyType` (таблица 0x186d0b274, база 0x186e73748, индекс = тип−700):
  804 kCGSWindowIsTerminated (release_window), 805 kCGSWindowIsChangingScreens, 806 kCGSWindowDidMove, 807 kCGSWindowDidResize,
  808 kCGSWindowDidChangeOrder, 811 kCGSWindowDidCreate. 805/806 шлёт CGXMoveWindowList, 807 — shape_window.
- `CGXPostWindowNotification(CGXWindow*, u32 type)` 0x186f8ee68: если `w+0x440 != 0`, обходит соединения сессии и тем, у кого wid в
  списке `conn+0x108` (его заполняет `SLSRequestNotificationsForWindows` 0x18702a6f8 → `_XRequestNotificationsForWindows` 0x1871b2478 →
  `CGXRequestNotificationsForWindows` 0x186f8ed74), шлёт `WSPostNotificationToConnection(conn, type, &wid, 4)`.
  → Демон снаружи может получить «окно X закоммитило новый размер» как событие 807 (данные = u32 wid) через
  `SLSRequestNotificationsForWindows(cid, wids, n)` + `SLSRegisterConnectionNotifyProc(cid, cb, 807, ctx)` 0x18703f36c.
- Изнутри WS «счётчик»: (а) bbox `*(w+0x170)` — меняется ровно в момент применения коммита (то, что движок уже читает каждый тик);
  (б) `w+0xc4` screen-geometry seed — растёт на любое изменение формы/трансформа/клипа (неспецифичен, годится как «что-то поменялось»).
  Отдельного «буфер стал нового размера» нет: размер буфера = размер формы, они меняются атомарно в shape_window.

### Чего НЕТ (проверено по импортам/коду)
- Нет серверного сообщения «приложение, стань размера R» через WS для обычного окна: WindowMoved (window_post_move_event) несёт только
  позицию (живой тест resize_re.md: не работает); tile-нотификация (тип 4) работает только для fullscreen-тайлов. Единственные пути
  «configure»: AX (сейчас) и `_WMClientResizeWindowRequest` по BSService из WindowManager.app (resize_re.md §★★★).

## Шаги для основного агента (каждый с проверкой)
1. **Hit-test, базовая проверка (без кода движка).** Поставить TextEdit статичный сдвиг через `hook/scripts/xform.py` (m41=−200, т.е. окно
   видно на 200 pt правее) + global clip по видимой рамке. Кликнуть по кнопке/тексту в ВИДИМОМ месте. Ожидание: курсор ставится куда кликнули.
   Клик в старое место (вне B) должен уйти окну ниже. Если так — п.3 закрыт для AppKit, промахов от сервера нет.
2. **Catalyst.** То же для Catalyst-приложения (например, Новости/Акции/Home — проверить `_CFMZEnabled`: в процессе есть UIKitMacHelper).
   Ожидание по коду (0x184b17404..0x184b174d4): при чистом сдвиге клик ПРОМАХНЁТСЯ на величину сдвига. Лечение [гипотеза]: для таких окон
   ставить m11 = 1+1e-6 (условие в AppKit — точное `a != 1.0`), тогда AppKit возьмёт `SLSGetCatenatedWindowTransform` и попадёт.
   Проверить, что ε-масштаб не мылит картинку (скриншот до/после, сравнение пикселей).
3. **Гонка с configure.** Во время ресайза кликать по окну в момент AX-configure (повторить 20 раз). Если промах — правило в демоне:
   AX-размер слать только когда трансформ окна identity, или на время `mouse down` откладывать configure до `mouse up`
   (AppKit сравнивает `event.timestamp < lastFrameChangeTimestamp`, 0x184b17648).
4. **Ack вместо опроса (демон).** `SLSRequestNotificationsForWindows(cid, wids, n)` 0x18702a6f8 на все тайловые wid +
   `SLSRegisterConnectionNotifyProc(cid, cb, 807, NULL)` 0x18703f36c (и 806, 804, 811). Проверка: лог типа+wid при ручном ресайзе Finder —
   ровно одно 807 на коммит; время 807 совпадает с первым кадром нового размера в rec.py.
5. **Locked bounds (эксперимент, изнутри WS).** `window_list_set_locked_bounds(conn=0, &wid, 1, &R, 1, place=0x30000000)` 0x186e50174
   (по аналогии с нашим ключом трансформа; place — позиция в стеке [гипотеза о смысле], NULL-rect = CGRectNull снимает).
   Проверка: окно визуально встаёт в R (растянуто), `CGWindowListCopyWindowInfo` отдаёт R; потом AX-размер = R.size → в кадре коммита
   масштаб становится 1 без скачка (rec.py: ни одного кадра с неверным масштабом). Снять CGRectNull. Конфликт: если WindowManager.app
   держит свой locked bounds на окне (Stage Manager/тайлинг macOS), слоты пересекутся — делать при выключенном Stage Manager.
6. **Группа движения.** Окно с открытым sheet (Сохранить в TextEdit): CGXMoveWindowList двигает ли sheet? Если нет — перейти на
   `WSMoveWindowWithGroupByOffset(conn=*(w+0x30), w, NULL, dx, dy)` 0x186fb10f0 (то, что делает сервер для WM.app).

## Открыто / не проверено
- Точный смысл `place` в locked bounds и порядок вызовов в WindowManager.app (Swift, stripped) — не трассировался.
- Какой commit-method AppKit выбирает при live-resize (3 vs 1): по коду async → 3; не подтверждено вживую.
- Поведение hit-test для окон с warp-мешем (`w+0x878`) — ветка разобрана, но мы мешей не ставим.
