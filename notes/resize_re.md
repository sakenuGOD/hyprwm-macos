# Resize-RE: как заставить чужое окно перерисоваться в новом размере (macOS 26.7.1 25G241, arm64e)

Только статический анализ (otool/nm/ipsw). Адреса статические (unslid) в dyld shared cache.
Метки: [V] — проверено по листингу, [H] — гипотеза, не проверена.

Артефакты:
- SkyLight disasm: /tmp/sl_dis.txt; AppKit disasm: /tmp/rsz/ak_dis.txt (otool неверно подписывает stubs в AppKit, для них использовался `ipsw dyld disass <cache> --symbol/--vaddr`)
- Извлечено: ~/Developer/re-tools/extracted/appkit/AppKit, ~/Developer/re-tools/extracted/wm/WindowManagement
- Хелперы: /tmp/rsz/fn.sh (функция SkyLight по адресу), /tmp/rsz/afn.sh (AppKit), /tmp/rsz/gotk.py (GOT -> символ через ipsw)

## Итог одной строкой
Split-view/tile-путь существует и работает так, как предполагалось, но AppKit реагирует только для окон
в нативном fullscreen-тайле. Для обычных окон есть более общий путь [V по коду, H по поведению]:
WS меняет серверную форму окна (`CGXWindow::shape_window`), потом шлёт приложению событие WindowMoved.
AppKit сам перечитывает с сервера bounds, включая размер, и делает relayout и redraw с fromServer=YES.
Настоящий аналог xdg configure в macOS 26 (`performResizeWindowRequest`) приходит не из WindowServer,
а из WindowManager.app через BSServiceConnection.

## 1. Tile-пространства (split view): сервер

Структура PKGTileEntry (из block type encoding, размер 0xb0) [V]:
```
+0x00 PKGTileManager*   +0x08 PKGSpace* (тайл)   +0x10 CGXWindow* tileWindow
+0x18 CGRect rect       +0x38..0x3a bool x3      +0x40 int64 pending (init -1)
+0x48 CGXWindow* (divider/companion)   +0x50 CGXConnection* owner   +0x58 float
+0x60 PKGWindowDataConstraints (3x CGSize)   +0x90 bool  +0x98 d  +0xa0 d  +0xa8 u32  +0xac u32
```
PKGSpace: +0x0 u64 spaceID, +0x18 родительский managed space. У managed space +0x8 = тип (4 = tiled), +0x118 -> tiled-данные, их +0x8 = PKGTileManager* [V: PKGSpaceGetRect 0x186e4c2d8, PKGSpaceSetValues 0x186e3f574].

Создание тайла и добавление в него:
- `_XSpaceCreateTile` 0x187199f00 (клиентский вызов `SLSSpaceCreateTile` 0x186fee8e8): (parentSpaceID u64, сериализованный CFDictionary) -> `pkg_tile_manager_create_tile_entry(mgr, dict)` 0x186e3b75c -> `managed_tiled_space_did_attach_subspace` 0x186e4c398. Родитель обязан иметь тип 4. Результат проверки CGXConnectionForPort не используется, явной проверки прав не видно [V].
- Ключи словаря (константы CoreGraphics, получены через GOT): `kCGSWorkspaceTileRectKey`, `kCGSWorkspaceSizeConstraintsKey`, `kCGSWorkspaceTileLimitedClippingKey`, `kCGSWorkspaceOwnerKey`, `kCGSWorkspaceTileWindowKey`, плюс CFString "Age"/"ConfigAge"; у менеджера: `kCGSWorkspaceLayoutObjectMaxTilesKey`, `kCGSWorkspaceInterTileSpacingKey`, `kCGSWorkspaceReservedAreaKey`, `kCGSWorkspaceLiveResizingKey`, `kCGSWorkspacePrincipalFullScreenWindowID` [V].
- Владелец ставится через `pkg_tile_entry_set_owner` 0x186e3bfa8: вызывается из create_tile_entry, PKGSpaceSetValues, PKGSpaceSetOwners, `_XTileSpaceTakeOwnership` 0x18718fd04 [V]. Окно тайла ставится через `pkg_tile_entry_set_tile_window` 0x186e3c2ec [V].

Изменение rect тайла: `pkg_tile_entry_set_rect_with_connection(entry, CGRect, reason u64, fencePort u32)` 0x186e38a40. Функция static, после dead-arg elimination реальные аргументы такие: x0 entry, d0-d3 rect, x1 reason, w2 fence [V].
- Вызывающие: `PKGSpaceSetValues` 0x186e3f574 (ключ TileRect, reason=0, fence=0, вызов на 0x186e3f630), `pkg_tile_manager_relayout_with_spacer` 0x186e37d88. Его в свою очередь вызывают `_XTileSpaceMoveSpacersForSize`, `_XSpaceMoveSpacersToPoint`, `_XSpaceSetInterTileSpacing`, `PKGTileSpaceMoveToSpaceAtIndex` и другие [V].
- Логика: rect записывается в entry+0x18. Если (reason & 2) == 0 и есть space, owner и manager, функция ищет «driving» entry. Если у driving тот же owner, уведомление не шлётся (приложение само ведёт ресайз). Иначе вызывается `CGXConnectionPostCoordinatedDistributedNotification(type=4, timeout=0.25, fence, list{owner}, list{owner}, dict, &id, NULL, NULL)` [V, 0x186e38c84..0x186e38d58].
- После этого `pkg_tile_entry_set_shape_with_connection`. Если reason<=3, fence==0 и сдвинулся origin, вызывается `WSTransformWindowsForSpaceRelayout(windows, old, new)` 0x186fb19ac. Он только сдвигает окна через interim positioning / transforms, размер не трогает [V].
- `PKGSpaceGetRect` 0x186e4c2d8 для тайла возвращает entry->rect [V].
- `PKGSpaceFinishedResizeForRectWithConnection` 0x186e4d204 (это ack от приложения): декремент entry+0x40, перерасчёт shape, сдвиг divider-окна (+0x48) через `WSMoveWindowWithGroupByOffset`. Окно приложения эта функция не ресайзит [V].

## 2. Формат уведомления [V]
- `post_coordinated_distributed_notification` 0x186f510cc собирает буфер: `u32 coordType | u64 notifId | bytes(CGSPropertyListCreateSerializedData(dict))`, и для каждого соединения из списка блок 0x186f51348 вызывает `WSPostNotificationToConnection(conn, 0x528 /*1320*/, buf, len)`. Таймаут ожидания ack = 0.25 с, затем завершается само.
- Для tile resize coordType = 4. dict = { "space": tileSpaceID (u64), "parentSpace": managedSpaceID, "liveResizing": CFBoolean (manager+0xa8 != 0) }.
- Клиент: `post_coordinated_distributed_notification(CGSNotificationType,...)` 0x187038f94 разбирает буфер. Через switch по coordType (jump table 0x186d0c86c, case 4 -> 0x1870390bc) он постит в `SLSCoordinatedLocalNotificationCenter` имя `kSLSCoordinatedTileResizeNotificationName` с userInfo=dict. Затем вызывает completion-блок (copy_coordinated_distnote_completion_block).
- Проверен только case 4 (CFString 0x1eecf7bf8 = "kSLSCoordinatedTileResizeNotificationName"). Остальные case (0..10) не разбирались.
- `SLSTileSpaceResizeRecordGet*` (0x186ff0c08...) — это тривиальные геттеры структуры {u64 space; u64 parent; bool live}. AppKit их не использует.

## 3. AppKit: обработчик [V]
- `+[NSCGSSpace addTileResizeNotificationHandler:]` 0x1854015e8: `[SLSCoordinatedLocalNotificationCenter() addObserverForName:kSLSCoordinatedTileResizeNotificationName ...]`.
- Блок 0x185401674: читает space/parentSpace/liveResizing, делает `[CATransaction begin]`, вызывает handler, потом `SLSCopyCoordinatedDistributedNotificationFencePort()`, `entangleUpdateOnFenceRight:`, flush, commit. Ответный кадр приложения синхронизирован fence-ом с сервером.
- Регистрируется в `+[_NSFullScreenSpace initialize]`, handler 0x185a016a0: `fullScreenSpaceWithTileID:` (если nil, ничего не происходит), `startLiveResize` при live, затем проверка `contentController.window._inFullScreen`, затем `updateTileShapeAndReshapeContents`, затем `endLiveResize`.
- `-[_NSFullScreenSpace updateTileShape]` берёт rect через `SLSSpaceGetRect(cid, tileSpaceID)`. Дальше `reshapeContentForTileFrame:contentFrame:fromFrame:` (0x18591c270) делает `_startLiveResize`, `setFrame:display:`, `layoutIfNeeded`, `_endLiveResize`. Если окно не влезает (min size): `performTileResizeToFit:acceptIncorrectSize:` -> `moveSpacersForSize:fenceRight:` (`SLSTileSpaceMoveSpacersForSize`). В конце `finishedResizeForRect:ackImmediately:` -> `SLSSpaceFinishedResizeForRect` 0x1854019bc.
- Вывод: гипотеза про split view подтверждена. Но путь срабатывает только у приложения в нативном fullscreen-тайле. Ещё одна деталь: AX `accessibilitySetSizeAttribute:` у fullscreen-окна ведёт в `performTileResizeToFit`.
- В macOS 26 клиентские `SLSSpaceFinishedResizeForRect` и подобные при `SLSWindowManagementClientOperationsEnabled()` (0x186edda6c, флаг 0x1ea5faf70 + наличие bridge delegate) идут не в WS, а мостом в WindowManager.app (`SLSPerformAsynchronousBridgedWindowManagementOperation`) [V].

## 4. Другие пути server->client «измени размер»

### 4a. WindowManager.app -> приложение: `performResizeWindowRequest` [V]
- AppKit: `-[NSWMWindowCoordinator clientWindowManager:performResizeWindowRequest:]` 0x18590b688. На main runloop: `_windowWithWindowIdentifier:(req.windowID)`, затем `-[NSWindow _resizeFromWindowManagerWithTargetGeometry:springSettings:completion:]` 0x1857476c4. Там spring-анимация, `_startLiveResize`, `_setFrameCommon:display:fromServer:` и ответ `WMClientResizeWindowResponseActionInfo(requestID)` с CAFence.
- Класс запроса `_WMClientResizeWindowRequest {requestID, windowID, targetGeometry(_WMResizeTargetGeometry{geometryType, frame, size, contentsGravity}), springSettings, requiresResponse}` (WindowManagement.framework).
- Транспорт: `WMClientWindowManager` -> BSServiceConnection на mach-сервис `com.apple.windowmanager.server`, service `com.apple.windowmanager.app-service`. Отправляет WindowManager.app (Swift, `ApplicationClientResizeWindowRequestRegistry`, `targetGeometryWithFrame:contentsGravity:` / `targetGeometryWithSize:`).
- Это и есть родной xdg-configure в macOS 26, но через WindowServer он не проходит. Использовать его можно, только встроившись в WindowManager.app (Swift-внутренности, отдельная задача).

### 4b. Общий путь через сам WindowServer: shape + WindowMoved [V по коду, H по поведению]
- `window_post_move_event(CGXWindow*)` 0x186fb9400 строит событие: type 13 (AppKitDefined), subtype 4 (WindowMoved) по +0x8a, wid по +0x3c, location = bbox.origin формы окна, по +0x8c float w,h. Отправляет через `CGXPostEventByConnection(owner=win+0x30, ev)`. Требует бит pending (win+0x92d bit1) и чтобы move events не были deferred.
- Планировщик `WSPackagesScheduleCoalescedWindowMoveEventIfNeeded(CGXWindow*, u64 ts)` 0x186fb959c (exported): ставит pending и через `reschedule_callback_on_session` вызывает `window_id_post_coalesced_move_event_callback` 0x186fb96a8, а тот `window_post_move_event`. Его вызывает и `CGXMoveWindowList` (0x18706bd50).
- AppKit: `-[NSWindow _internalHandleAppKitDefinedEvent:]`, затем `-[NSWindow _windowMoved:]` 0x184b19604. Метод берёт фактический frame окна с сервера (`NSCGSWindow windowWithWindowID: .frame`, лог-строка "_NSWindowGetCurrentBoundsFromServer yields actualFrame"), то есть с размером, и вызывает `_windowMovedToRect:dueToMoveEvent:YES` с этим rect.
- `_windowMovedToRect:dueToMoveEvent:` 0x185737e2c: **если Cocoa-origin (нижний левый угол) совпадает с текущим `_frame.origin`, выход без изменений.** Иначе вызывается `_setFrameCommon:display:NO fromServer:YES` с серверным rect (или `_setFrameAfterMove:`, если окно тащат).
- `_oldPlaceWindow:fromServer:` 0x184a3813c: при fromServer `_cgsMoveWindow/_cgsSizeWindow/_cgsPlaceWindow` пропускаются. При смене размера: `_reallySetFrame:`, `updateConstraintsIfNeeded`, `_setWindowResizeConstraintSize:`, `borderView setFrameSize:`, `_layoutViewTree`, `setNeedsDisplay:YES`. Это настоящий relayout и redraw.
- Серверная смена размера: `CGXWindow::shape_window(CGXWindow*, CGSRegionObject* shapeGlobal, CGSRegionObject* opaque/NULL, weighting)` 0x187060158. Обёртки: `CGXWindow::shape_window_with_rect(CGRect global, weighting)` 0x187060580 и экспортируемая `WSShapeWindow` 0x18706fd98. Регион в ГЛОБАЛЬНЫХ координатах: `PKGTransactionSetWindowShape` 0x1870ca3f4 сдвигает клиентский регион на bbox.origin (win+0x170 = текущая форма). Внутри: `CGXBackingStoreResize`, set_shape_internal, invalidate, `CGXPostWindowNotification(win, 0x327)`.

## 5. Минимальная последовательность из WS (вариант 4b) — окно W приложения A, rect R (CG-координаты, top-left)
1. `CGXWindow* w` (как уже получаем для CGXMoveWindowList).
2. `CGXWindow::shape_window_with_rect(w, R, 0)`, где R — глобальный rect нового размера в новой позиции.
3. Убедиться, что Cocoa-origin меняется: newCocoaY = H_screen - (R.y + R.h) должен отличаться от старого, иначе AppKit проигнорирует. Если меняется только ширина при фиксированном верхнем левом углу, origin тот же. Тогда сделать двухфазно: сдвинуть на 1 px, потом вернуть, или временно поменять y.
4. `WSPackagesScheduleCoalescedWindowMoveEventIfNeeded(w, 0)`. Либо, если origin меняется, `CGXMoveWindowList`: он сам запланирует событие (но ему нужен origin, а форма уже стоит в R; [H] нужно проверить, что MoveWindowList с тем же origin не дёргает shape).
5. Приложение получает событие, читает bounds, вызывает `_setFrameCommon:fromServer:YES`, делает layout и draw в новом размере, CA commit.

Вариант 1 (tile), если окно уже в fullscreen-тайле: `PKGSpaceSetValues(conn?, tilePKGSpace, @{kCGSWorkspaceTileRectKey: CGRectDict(R)})` (x0 не разобран, похоже на CGXConnection*; в пути TileRect не используется до set_rect). Дальше всё делает AppKit, ack приходит через SLSSpaceFinishedResizeForRect.

## 6. Риски и неизвестное
- [H] `_setFrameCommon:display:fromServer:` в начале может прогнать `_adjustFrame`/constrain (min/max size, экран). Тогда AppKit примет другой размер, чем у серверной формы, и не отправит его обратно на сервер (fromServer). Получится рассинхрон формы и контента. Нужна проверка, лечится повторным shape под фактический размер.
- [H] Нет fence/синхронизации. Пока приложение не перерисовалось, сервер покажет старый контент в новой форме (мусор или прозрачность, растяжение зависит от contentsGravity). Возможны мерцания.
- [H] Swift/SwiftUI-окна, Catalyst/UIKit-сцены и окна с собственным resize-циклом (Chromium) могут вести себя иначе. Не-AppKit клиенты (без NSWindow) этот путь не поддерживают.
- [H] `window_move_events_are_deferred` и `_isHandlingDisplayReconfigThatWillRepositionWindows` подавляют событие; `_windowIsBeingMoved` переключает на `_setFrameAfterMove:`.
- Tile-путь требует fullscreen-тайла (`_inFullScreen`, `fullScreenSpaceWithTileID:`). В macOS 26 политику тайлов, вероятно, ведёт WindowManager.app через мост. Если менять entry напрямую в в рамках ожиданий системы него, возможен конфликт состояний.
- Вызов C++-методов CGXWindow извне: this=x0 (видно по местам вызова), методы невиртуальные, вызываются прямым `bl`. Структура CGXWindow (смещения 0x30 owner, 0x170 shape, 0x928 flags) взята из листинга этой сборки и может поменяться в других сборках.

## 7. Предложение первого live-эксперимента (НЕ выполнялся)
Цель: TextEdit, обычное окно, не fullscreen. Изменить только высоту, верхний левый угол оставить, тогда Cocoa-origin.y изменится и проверка AppKit пройдёт.
1. Из WS-кода: найти CGXWindow* по wid TextEdit (тот же путь, что для CGXMoveWindowList), прочитать текущий bbox `CGRegionGetBoundingBox(*(win+0x170))` = (x,y,w,h).
2. `shape_window_with_rect(win, {x, y, w, h+200}, 0)` — static 0x187060580 + slide.
3. `WSPackagesScheduleCoalescedWindowMoveEventIfNeeded(win, 0)` — 0x186fb959c + slide.
4. Наблюдать: `log stream --predicate 'subsystem=="com.apple.AppKit" AND category=="Screen"'` с включённым NSScreenLogging (строки "_windowMoved: ... actualFrame=..."). Проверить, что текст перелился под новую высоту. Контроль: `SLSGetWindowBounds` против `[NSWindow frame]` через AX.
5. Негативный контроль: то же самое, но меняется только ширина. Ожидается, что AppKit проигнорирует (проверка NSEqualPoints).

## ЖИВАЯ ПРОВЕРКА пути «б» (2026-10-08) — НЕ РАБОТАЕТ
- `shape_window_with_rect(win, R, 0)` + `WSPackagesScheduleCoalescedWindowMoveEventIfNeeded(win, 0)`
  вызваны изнутри WS (hook/scripts/resize.py). Сервер форму меняет (CGWindowList: новый размер,
  снимок окна новой высоты), событие WindowMoved реально уходит (pending 0→1, колбэк через 0.1с
  сбрасывает его — hook/scripts/mevtest.py).
- НО приложение НЕ перестраивается: Terminal (на неактивном столе) и v2RayTun (на текущем) —
  контент остаётся старого размера, прижат к низу новой формы, сверху пусто; заголовок Terminal
  остаётся 80×24. Вывод: AppKit из WindowMoved берёт только позицию, размер с сервера не перечитывает.
- Оба окна возвращены исходной формой тем же путём (обратимо, без побочек).
- Следующий кандидат — путь «а»: macOS 26 шлёт resize-запрос приложению из WindowManager.app
  (`NSWMWindowCoordinator performResizeWindowRequest` → `-[NSWindow _resizeFromWindowManager
  WithTargetGeometry:springSettings:completion:]`, BSServiceConnection
  com.apple.windowmanager.app-service). Это родной configure macOS 26 (со spring!), но
  отправитель — WindowManager.app, не WindowServer.

## ★★★ НАТИВНЫЙ RESIZE РАБОТАЕТ (2026-10-08) — путь через WindowManager.app ★★★
Пойман живьём (trace/resize_capture.sh, trace/capture_wm_request.sh), затем воспроизведён своим запросом
(trace/wm_resize.py через trace/run_lldb_wm.sh): Terminal 735x923 → 641x481 @ (99,120), заголовок
102×62 → 88×30 (приложение само пересчитало строки/столбцы), контент чёткий, не растянут.

Цепочка macOS 26:
- app: -[NSWMWindowCoordinator requestTilingForWindow:tilingPosition:] (пункт меню) → WindowManager.app
- WindowManager (Swift, stripped; static 0x1000aa6ec, x20 = объект-клиент приложения):
  req = 0x1000aa77c(...) ; proxy = [*(client + *(0x10045ffe0)) remoteTarget] ; [proxy performResizeWindowRequest:req]
  соединение: BSServiceListenerConnection «BSXPC(com.apple.windowmanager.server)-from(<pid>)-as(com.apple.windowmanager.app-service)»
  прокси: BSXPCServiceConnectionProxy<WMXPCClientInterface>
- app: -[NSWMWindowCoordinator clientWindowManager:performResizeWindowRequest:] → -[NSWindow
  _resizeFromWindowManagerWithTargetGeometry:springSettings:completion:] → _setFrameCommon:display:fromServer:
  → ответ транзакцией с fences (_WMClientResizeWindowResponseActionInfo).

Объекты (WindowManagement.framework, типы из method_getTypeEncoding):
- +[_WMResizeTargetGeometry targetGeometryWithFrame:(CGRect) contentsGravity:(long long)] — frame в глобальных
  точках, origin сверху-слева; gravity 2 = «left» (то, что шлёт сама macOS).
- -[_WMSpringAnimationSettings initWithMass:(d) stiffness:(d) damping:(d) epsilon:(d)] — пружина анимации
  resize в приложении (ставим drift Hyprland: 1/210/24/0.001).
- -[_WMClientResizeWindowRequest initWithRequestID:(NSString UUID) windowID:(NSString UUID окна в WM, НЕ CGS wid)
  targetGeometry: springSettings: requiresResponse:(BOOL)] — шлём requiresResponse=NO.
Грабли lldb (arm64e): длинное многострочное выражение с анонимным typedef → подпись указателей arm64e-сбой 0xd63f0..; короткие отдельные
выражения + struct R_{double a,b,c,d} вместо CGRect работают.
ОТКРЫТО: таблица CGS wid → windowID(UUID) и pid → соединение внутри WindowManager (сейчас взяты из живого захвата).
