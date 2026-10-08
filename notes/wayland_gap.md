# Чего не хватает до ощущения Wayland/Hyprland — разбор по первопричинам (2026-10-08)

Режим: только чтение. lldb/dtrace/sudo не запускались, WindowServer и демон не трогались, файлы
проекта не менялись (этот файл — новый). Источники: `GOAL.md`, `HANDOFF.md` (сессии 5–6),
`notes/{fable_plan,anim_feel,gap_review_2,hyprland_spec_full}.md`, `evidence/video_audit.md`,
код `hook/{hyprwm.py,engine.py,deco.py}`, `hook/src/{anim4.c,chan.h,axlib.c,winsnap.m}`,
`hook/deco/hyprdeco.m`, `hook/keys/binds.py`; дизассемблер SkyLight `/tmp/sl_dis.txt` (otool),
карта `/tmp/sl_map.tsv`, строки SkyLight; AppKit из `extracted/appkit/AppKit` (nm + otool, полный
дамп `/tmp/ak_dis.txt`); дотфайлы `~/arch-nebula/dotfiles`, проект `~/Developer/OpenRunner`.
Адреса — статические (без slide), как в `/tmp/sl_map.tsv`. Метки: **[V]** — видно в коде/листинге;
**[H]** — гипотеза, нужна живая проверка (как проверить — указано).

---

## 0. Главный вывод

1. **Кривые и математика верны** (anim_feel §1–3). «Резко, тяжело, подвисание» складывается из
   шести вещей, которые не имеют отношения к пружине: (а) задержка от нажатия до первого сдвига
   30–130 мс и старт сразу с пиковой скорости; (б) несколько волн на одно событие (configure →
   ретаргет → `settle`); (в) главный поток WindowServer нагружен нашим же демоном 60 раз в секунду
   (`CGWindowListCopyWindowInfo` ×2 + `SLSCopySpacesForWindows` на каждое окно + stdin-транзакции
   hyprdeco) — это прямой кандидат на пропуски кадров во время композита; (г) видимые промежуточные
   состояния (прямоугольный клип без скругления, серые подложки, окно не в своей плитке);
   (д) на 60 Гц та же пружина даёт шаг 10 % пути за кадр против 3.3 % на 180 Гц — смаз на
   sample-and-hold в 1.7 раза больше физически; (е) неактивные окна macOS «серые» — каждое
   переключение фокуса перерисовывает два окна, и это режет глаз сильнее любой анимации.
2. **Серый неактивный вид решается на уровне сервера без инъекции** [H, путь найден в листинге]:
   AppKit рисует «активный» вид по флагу окна `hasKeyAppearance`, а не по `NSApp.isActive`; этот
   флаг выставляется в `becomeKeyWindow`, который требует активности приложения. Но у SkyLight есть
   обратный канал: сервер умеет *сам* послать окну событие «resign key/main appearance»
   (`window_send_resign_key_main_appearance_event` → `CPXPostEvent`), а приложение становится
   «активным» по событию `kCGSEventResume` (CGSEventType 0x13), которое сервер шлёт в
   `SetFrontProcessInternal` через `PostCGSEventToProcess`. Значит: либо прислать приложению
   Resume без смены переднего процесса (из демона, через `SLPSPostEventRecordTo`, если сервер
   пропустит тип 0x13), либо глушить `kCGSEventSuspend` (0x14) для тайловых приложений изнутри WS.
   Подробно — §2.
3. **На 60 Гц нельзя получить 180 Гц.** Растяжение времени ×1.2 — правильная по форме, но
   частичная мера (смаз −17 %). Настоящая «лёгкость» на 60 Гц — это: ноль задержки старта,
   одна волна, ни одного пропущенного кадра, округление к пикселю устройства в хвосте, и — если
   хочется честных 180 Гц — подключить его же монитор к маку по USB-C/DP (движок уже читает
   период развёртки). Подробно — §3.

---

## 1. Чего не хватает — по пунктам, с первопричиной и решением

### 1.1 Задержка старта и «срыв с пиковой скорости» (жалоба «резко», «на каждую анимацию подвисание»)

Цепочка сейчас [V]: `hyprkeys` → сокет → `select(POLL=16 мс)` (`hyprwm.py:658`) → `snapshot()`
(2–5 мс; `winsnap.m`) → `command()` → `layout` → `deco.place` (stdin в чужой процесс: `setFrame:`
+ `orderWindow:below:` — синхронные транзакции WS, `hyprdeco.m`) → `c.commit()` → ожидание
`cmd_tail` до 50 мс (`hyprwm.py:279`) → тик движка (≤16.7 мс) → `held` ≤1 кадр (`anim4.c:476`)
→ первый видимый кадр. Итого 40–130 мс. У drift пик скорости на 73 мс, т.е. после паузы окно
«срывается» (anim_feel §4). Hyprland: событие → следующий кадр (≤5.5 мс).

Решение (без RE):
- Командный путь не должен делать снимок окон: `command()` работает по уже известному дереву и
  `self.eng.c.wins()` (движок знает A всех окон каждый тик).
- `deco.place` убрать из критического пути (подложки — §1.4).
- `hold`: совсем 0 для перекладок (Hyprland не ждёт кадра приложения, показывает старый буфер
  обрезанным/дотянутым). Оставить ожидание только для popin нового окна (там и Hyprland ждёт
  первый буфер).
- Цель: нажатие → первый сдвиг ≤ 1 кадр + 5 мс. Проверка: лог `time.time()` при приёме команды и
  `h.te` первого тика с `nactive>0`; телефон 120 к/с с keycastr.

### 1.2 Несколько волн на одно событие

[V] `apply()` шлёт пачку, затем `configure()` в потоках, через ≤150 мс `configured()` может дать
`changed=True` → новая `apply()` → ретаргет посреди хода (вторая волна); `hide()`/`unhide()`
вызывают `apply()` + отдельный `commit()` (`hyprwm.py:566-567, 585-590`) — два разных `t0`;
`realign()` после отпускания мыши — третий источник. В `evidence/video_audit.md` B5 — каскад из
5 раскладок за 450 мс.

Решение: одно событие = одна пачка; любое уточнение (минимум окна) — ретаргет в **следующем
тике** (retarget сохраняет скорость, глазом не видно), а не после опроса 150 мс. Минимумы брать до
раскладки: `_SLSPackagesGetWindowConstraints` / `_SLSWindowIteratorGetConstraints`
(`PKGWindowDataConstraints` = 3×CGSize: min/max/preferred; символы 187094340, 187170900) [H:
заполняет ли их AppKit для обычных окон — проверить одним вызовом из демона на Finder].

### 1.3 Главный поток WS занят нашим демоном (кандидат №1 на «подвисание»)

[V] `winsnap.m:35-60`: каждые 16 мс два `CGWindowListCopyWindowInfo` и `SLSCopySpacesForWindows`
на каждое окно (все окна всех столов, в т.ч. скрытые). Каждый такой вызов — RPC в WindowServer,
обслуживаемый его главным потоком (тем же, где `anim_tick` и подготовка кадра). Плюс
`engine.alive()` раз в 2 с с `sleep(0.05)` — демон замирает на 50 мс.

Решение: события вместо опроса. Снаружи: `SLSRegisterNotifyProc`/`SLSRegisterConnectionNotifyProc`
(186f2f520 / 18703f36c) на типы `kCGSWindowDidCreate`, `kCGSWindowIsTerminated`,
`kCGSWindowIsOrderedIn/Out`, `kCGSWindowDidMove/DidResize` (имена есть в строках SkyLight;
номера — классические 811/804/802/803/806/807, подтвердить одной регистрацией с логом типа).
Изнутри WS мы уже видим новые wid (скан в `anim_tick`); туда же добавить `EV_GONE` по
`CGXWindowByID == NULL` и `EV_MOVED` по изменению A. Снимок — раз в 2–5 с для сверки. Фокус за
мышью — отдельный дешёвый опрос курсора (`CGEventCreate`) без списка окон; окно под курсором —
`SLSFindWindowAndOwner`/движок по A.

Проверка: гистограмма `h.last_dt` и `frames` (metalCallbacks) за перекладку — 45 кадров / 45 тиков
без дублей; до/после отключения опроса.

### 1.4 Видимая рамка B = прямоугольный клип + подложки из чужого процесса (углы, тени, серые прямоугольники)

Первопричина [V]: `put_clip` (`anim4.c:194`) → `CGXWindow::set_window_list_global_clip_shape`
(18705f624) с прямоугольным CGRegion. Серверное скругление (`resolved_corner_radius`, 187063110)
и тень применяются к реальной рамке A, клип их срезает. Подложки — окна `hyprdeco` (отдельный
процесс, управление по stdin, `deco.py`), поэтому они отстают, остаются сиротами (B3 в
video_audit) и имеют цвет темы, а не края буфера.

Решение по-настоящему (три уровня, нужен один подтверждённый):
- **R-shape**: `CGXWindow::shape_window(CGSRegionObject*, CGSRegionObject*, CGSWindowSaveWeighting)`
  (187060158) / `shape_window_with_rect` (187060580) ставят серверную форму окна — к ней
  применяются и скругление, и тень сервера. Риск: `release_window` и `shape_window` шлют приложению
  `CGXPostWindowNotification` (186f8ee68; тип 0x324/0x32b видны в листинге) → AppKit получит
  WindowMoved/Resized и перечитает рамку. Проверка: вызвать `shape_window_with_rect` на чужом окне
  из нашего кода WS, dtrace-счётчик `-[NSWindow _setFrameCommon:…]` в приложении, хит-тест.
- **Обрезка + свои декорации** (без RE формы): клип делать не прямоугольником, а регионом со
  ступенчатым скруглением (18 полос на угол, CGRegion это допускает), системную тень на время клипа
  выключать (`WSWindowSetShadowEnable` 18706e764 / `SLSSetWindowShadowParameters` 187020888) и
  рисовать свою тень/рамку серверными окнами, созданными **изнутри WS** (`WSWindowCreate`
  187068b1c — образец вызова в `pkg_tile_entry_replace_with_snapshot_for_connection`:
  `WSWindowCreate` → `WSWindowSetROTags` → `WSWindowSetDepth` → `WSWindowSetHasAlpha` →
  `WSWindowSetCapturedContent` → `PKGSpacesAddWindowsWithConnection` → `CGXOrderWindowListSpaceSwitchOptions`),
  и двигать их в том же `anim_tick`, что и окно. Процесс `hyprdeco` и stdin — убрать.
- **Путь Б** (целевой, самый дорогой): править слои в `generate_layers_for_window(CGXRedrawState*, CGXWindow*)`
  (186e19454) / `generate_layers_for_window_surfaces` (186e1f9a8) → `WSCompositeSourceLayer`
  (src-rect = обрезка/дотяжка clamp-to-edge, маска суперэллипса, свои слои тени/рамки/блюра, удержание
  слоя закрытого окна). Композит: `CompositorMetal::composite(WSCompositeSourceLayer*, WSCompositeDestination*, bool, bool)`
  (186f4052c), `metal_composite_shadow` (186f43074), `metal_composite_legacy_background_blur`.
  Только этот путь даёт dual-kawase с vibrancy и АА-суперэллипс 1:1.

Дотяжка края (буфер меньше B): цвет из последнего буфера (`ax_edge_color` уже есть) — временно;
по-настоящему — clamp-to-edge в пути Б.

### 1.5 «Рамка выросла, содержимое узкое, окна долго подстраиваются» (Telegram)

Это две вещи. (1) Предел приложения: Telegram/Electron/Finder перерисовываются за 100–300 мс после
`setFrame`; Hyprland тоже показывает старый буфер, но *дотянутый краем*, и у kitty это 1–2 кадра.
(2) Наша часть: `ax_frame` идёт **после** commit и ждёт `cmd_tail` до 50 мс, а по сжимающейся оси
и по растущей сразу конечный размер — верно; но пока буфер меньше B, в полосе видна серая
подложка, а не край содержимого. Решение — §1.4 (дотяжка) + configure в первом же кадре события.
Честно: скорость перерисовки Telegram не ускорить ничем на нашей стороне.

### 1.6 Скрыть/вернуть: «кикфлип», «все окна пропадают на мгновение», нет анимации

[V] `unhide()` делает `OP_WARP` в старую рамку с `settling=1` и отдельный `commit()`, затем `sync`
на следующем цикле вставляет окно, `apply()` шлёт drift из старой рамки; буфер окна при этом
старого размера → клип + подложка на весь ход («кикфлип» = старый буфер, обрезанный по движущейся
рамке). «Пропадают все окна» [H]: `hide_newbies` ставит `alpha 0` любому новому wid тайлового
приложения (`optimistic`), и при `OP_WARP` окна за экран/обратно снимок может стать
`stable=0` — демон пропускает цикл; ещё кандидат — `below` из hyprdeco переупорядочивает окна.
Проверка: лог `EV_NEW`/alpha-команд в момент M+Shift+W и rec2-захват 60 к/с.

Решение: hide = alpha→0 (fadeOut 240) на месте + соседи в той же пачке (уже так), парковка за
экран **после** финиша и без warp видимых окон; unhide = окно сразу в целевую плитку (configure)
с `F_FROM` = старая рамка, альфа 0→1, popin не нужен; один `commit()` на всё событие.

### 1.7 Закрытие приложением без анимации (Cmd+W, кнопка)

Нужен снимок последнего буфера на сервере. Образец внутри SkyLight [V]:
`pkg_tile_entry_replace_with_snapshot_for_connection(PKGTileEntry*, CGXConnection*)` (186e3cd4c):
`WSWindowCreate` → теги/глубина/альфа → `WSWindowSetCapturedContent` (18707325c) → добавить на
Space → упорядочить → `CGXWindow::release_window` старого. Снимок буфера:
`WSCaptureCreateIOSurfaceMachPortForWindowList` (1870b6c8c) →
`WS::Capture::create_iosurface_for_window_list`. Хук уничтожения: `CGXWindow::release_window`
(18705aa44) шлёт `WSPostLocalNotification` + `CGXPostWindowNotification` → у нас в тике это
`EV_GONE` на следующем кадре — для призрака поздно (буфер уже освобождён `CGXBackingStoreRelease`
в `~CGXWindow`). Реально: держать «тёплый» снимок каждого тайлового окна (обновлять по
`kCGSWindowDidResize`/раз в N кадров через `WSCaptureCreateIOSurface…`) и при `EV_GONE` поднимать
призрак из последнего снимка. Это RE средней тяжести, но путь подтверждён символами.

### 1.8 Новое окно: «спавнится долго», встаёт не туда

[V] `wm_info` переспрашивает AX с экспоненциальной паузой `min(0.02·2^n, 2.0)` — для приложения,
которое отдаёт AX-окно через 300 мс, обнаружение сдвигается до 640 мс. Это самостоятельный источник
«долго». Решение: пока окно «новое» (≤1 с) — опрос AX каждые 16 мс или `AXObserver` на
`kAXWindowCreatedNotification`; раскладка вставляется по `EV_NEW` из движка (окно уже спрятано
альфой — это сделано). Configure до первого кадра приложения невозможен без кода в приложении —
честный предел; Hyprland тут выигрывает за счёт `predictSizeForNewTiledTarget` в xdg configure.

### 1.9 Рабочие столы

Системные Spaces: своя анимация Dock, наш слот трансформа `0x30000000` конфликтует с системными
(`CGXSetWindowTransform3DList` сбрасывает `0x1ffffffe/d`). Решение — виртуальные столы в одном
Space (fable_plan §2.5): уходящие `offset ∓0.12·W`, α 1→0; входящие заранее order-in с α 0,
`offset ±0.12·W→0`; один `t0`. Обои и меню не двигаются — как в Hyprland. На время системного
перехода (если остаётся) движок снимает свои трансформы.

### 1.10 Фаза тика (см. также §3.4)

[V] `anim_tick` считает значения на `te` (ближайшая развёртка после now+margin) и планирует себя на
`te + 0.1·T`. Это корректно, если тик успевает до «дедлайна» сборки кадра WS. Хук «перед сборкой
кадра» — вход `WS::Updater::UpdateDisplays(CGXConnection*, bool, vector<shared_ptr<Display>>)`
(186e0f1f4) / обёртка `_CGXUpdateDisplay` (186e0f158); патчить __TEXT нельзя, но
`UpdateDisplays` запускается по уведомлению (`update_displays_handler(CGSNotificationType…)`
186f30280) и через `_CGXScheduleUpdateDisplay` — можно зарегистрировать свой notify-proc на тот
же тип **раньше** системного и тикать из него [H]. Проверка: `cgdebug::log_frame_submission`
не трогать; достаточно сравнить `frames` и `ticks` и rec2-траекторию.

---

## 2. Фокус и «серые неактивные окна» — главный раздел

### 2.1 Как macOS решает, рисовать ли окно «активным» [V, AppKit]

- `-[NSWindow(NSWindow_Theme) _hasActiveAppearance]` (0x184a1392c):
  `hasKeyAppearance || hasMainAppearance || attachedSheet._hasActiveAppearance` (для дочерних окон —
  спрашивает родителя). **`[NSApp isActive]` здесь не проверяется.**
- `hasKeyAppearance` — бит во флагах окна (`__auxWFlags`: `hasKeyAppearance`, `hasMainAppearance`,
  `shouldHaveKeyAppearance`, `hasKeyFocus`, `hasMainFocus`, `forceMainAppearance`,
  `forceActiveControls`, `preventedOtherWindowResignKeyAppearance`, `ignoreResignMainEvent`).
  AppKit **разделяет** key-фокус (клавиатура) и key-внешний вид — ровно то, что нам нужно.
- Бит ставится в `acquireKeyAppearance` (0x184b3f8bc) → `__NSWindowSetHasKeyAppearance`
  → `_setFrameNeedsDisplay:`; и уходит на сервер: `-[NSCGSWindow setHasKeyAppearance:]`
  → `_SLSTransactionSetWindowHasKeyAppearance` → серверный `_XSetWindowHasKeyAppearance`
  (1871ab784) → `_WSSetWindowHasActiveAppearance(CGXWindow*, bool active, bool key)` (186fb02b4).
  Сервер по этому флагу переключает тень active/inactive (`WSWindowSetHasActiveShadow` 1870710e8,
  `WSWindowGetActiveShadow/GetInactiveShadow`).
- `acquireKeyAppearance` вызывается из `-[NSWindow becomeKeyWindow]` (0x184b3eef0), а тот
  проверяет `isActive` / `_isNonactivatingPanel` / `_canBecomeSecondaryKeyWindow` и делает
  `_stealKeyFocusWithOptions:`. Снятие: `resignKeyWindow` → `resignKeyAppearance`
  (сбрасывает биты 58 и 60 в `_auxiliaryStorage+0xf8`) → `_didResignKeyAppearance`.
- Деактивация приложения: сервер шлёт `kCGSEventSuspend` (CGSEventType **0x14**) →
  `-[NSApplication _handleDeactivateEvent:]` → `_deactivateWindows` → `__NXEndKeyAndMain` →
  `_sendResignKeyWindow` (серые светофоры/фон). Активация: `kCGSEventResume` (**0x13**) →
  `_handleActivatedEvent:` (читает `subtype` 1/2, `data1` — счётчик отложенной активации,
  `data2` — номер окна) → `_calcKeyAndMain` → `_activateWindows` → `__NXOrderKeyAndMain` →
  `makeKeyWindow` → `becomeKeyWindow` → `acquireKeyAppearance`.

Почему живой тест «два event record (тип 1/2 с wid) без SetFront» ничего не изменил: это
синтетические mouseDown/mouseUp; AppKit в `becomeKeyWindow` упирается в `isActive`=NO и ключевой
бит не ставит. Вывод координатора верен: нужен флаг активности приложения *или* прямая установка
key-appearance.

### 2.2 Как сервер сообщает приложению активность [V, SkyLight]

- `SetFrontProcessInternal(CGXSession*, CPSProcessRec*, SLSEventRecord const*, uint, ulong)`
  (186d51734; строка 93492 в `/tmp/sl_dis.txt`): `setFrontmostProcess:` у `focusController`,
  `ReleaseAllKeyFocus`, затем `PostCGSEventToProcess(CPSProcessRec*, CGSEventType=0x13, u16, u16,
  u32, int, CPSProcessSerNum, u64)` новому переднему (лог «Posting kCGSEventResume … allWindows=%d
  noWindows=%d userGenerated=%d»), и `0x14` (Suspend) — уходящему, та же функция
  (`mov w1,#0x14` на 186d51bf8). Далее `SendNotificationToEveryConnectionOfPSN`,
  `WSPostLocalNotification`.
- Клиентский вход: `_SLPSSetFrontProcessWithOptions` (186f17e10) → `__XSetFrontProcess` → выше.
  `_SLSSetFrontProcessWithInfo` (186f1764c), `_SLSSetFrontWindow` (18715fedc, пишет wid в
  состояние сессии), `_CPXSetFrontProcess` (186d5344c).
- **Сервер умеет сам просить окно снять активный вид**: `_PKGWindowResignActiveAppearanceOnManagedSpace`
  (186fb0034) → `window_send_resign_key_main_appearance_event(CGXWindow const*, bool key)`
  (186fb00e4): `CPXGetConnectionPSN`, запись 0xf8 байт с `[0x8a]=0x16`, `CPXPostEvent`.
  Принимается в AppKit `-[NSWindow _handleResignKeyAppearanceEvent]` /
  `_handleResignMainAppearanceEvent` (сбрасывают бит и вызывают `resignKeyAppearance`). Это
  используется Stage Manager/managed spaces. **Обратного события «acquire» на сервере нет** —
  приобретение идёт только через `becomeKeyWindow`.
- Теги окна, влияющие на активацию (строки SkyLight): `kCGSPreventsActivationTagBit`,
  `kCGSAvoidsActivationTagBit`, `kCGSDefersActivationTagBit`, `kCGSIgnoreAsFrontWindowTagBit`,
  `kCGSActivationWindowLevelTagBit`; установка `_SLSSetWindowTags` (187021f70) /
  `CGXWindow::set_window_list_tags` (187063af0). Они управляют тем, *активирует ли клик*
  приложение, но не внешним видом — для панелей AppKit сам ставит key-appearance по
  `_isNonactivatingPanel`. Для чужих окон тегами «вид» не включить.

### 2.3 Что реально сделать без инъекции — по возрастанию чистоты

**Вариант A (демон, проверяется за час) [H].** После `_SLPSSetFrontProcessWithOptions` на новое
окно немедленно послать *прежнему* приложению запись `kCGSEventResume` (тип 0x13, `[0x08]=0x13`,
subtype/data как у сервера: allWindows=0, noWindows=0, userGenerated=1, data2=wid нужного окна)
через `SLPSPostEventRecordTo` (так же, как сейчас шлются типы 1/2). Серверный приёмник
`__XPostEventRecordTo` (1871af798) проверяет только `CGXSenderCanSynthesizeEvents` и диапазон
типов (`cmp w21, #0x4, lsl #12`), т.е. тип 0x13 не фильтруется по списку — **пропустит ли его
CPS дальше, надо проверить вживую** (лог `_handleActivatedEvent` в приложении/видно по
светофорам). Если работает: приложение считает себя активным (`isActive`=YES), его key-окно снова
`acquireKeyAppearance`, клавиатура остаётся у настоящего переднего (сервер роутит ввод по
`frontmostProcess`, не по мнению приложения). Побочки: оба приложения думают, что активны
(мигают курсоры ввода в обоих — в Wayland курсор тоже «живёт» только у фокусного, это
расхождение; Telegram может помечать прочитанным — поведение приложения); возможен один «серый»
кадр между Suspend и Resume — AppKit обрабатывает оба события в одном проходе runloop, если они
уже в очереди; снять 120 к/с.

**Вариант B (внутри WS, без гонки) [H].** Глушить `Suspend` (0x14) для тайловых приложений:
`PostCGSEventToProcess` — статическая функция, патчить __TEXT нельзя; но `SetFrontProcessInternal`
вызывается из RPC-обработчика `__XSetFrontProcess`, а демон инициирует почти все смены фокуса
сам — значит, вариант A покрывает 95 % случаев, а оставшиеся (клик мышью по другому приложению,
Cmd+Tab) ловятся уведомлением о смене переднего процесса (`SLSRegisterNotifyProc` на
`kCGSNotificationAppActivated`/`foregroundSwitchNotifyProc` 186f4d5b8) с той же досылкой Resume.

**Вариант C (красиво, но дальше).** Своё серверное событие «acquire key appearance» не
существует; добавить его = хук в `CPXPostEvent`-пути — только через путь патчей.

**Чего не сделать**: заставить AppKit *чужого* процесса нарисовать активный вид, не меняя его
`isActive`/key-бит — нет серверного флага «always appear active»; `WSSetWindowHasActiveAppearance`
меняет только серверную тень.

### 2.4 Фокус как в Hyprland (follow_mouse без подъёма, окно среди окон одного приложения)

- Сейчас [V]: `ax_focus` = `_SLPSSetFrontProcessWithOptions(psn, wid, 0x200)` + два event record
  + `AXRaise`. Подъём (`AXRaise`) меняет z — в Hyprland фокус тайлового окна z не меняет.
  Убрать `raise`; окно внутри приложения делается key двумя записями (это работает — yabai).
- Клавиатурный фокус сервером: `_SLPSStealKeyFocus(OnConnection/ReturningID)` (186f19508…),
  `_SLPSReleaseKeyFocusWithID`, `_SLPSGetKeyFocusProcess`, `managed_space_set_key_window`
  (186e41990), `_PKGManagedSpaceGetKeyWindow` — серверное понятие «key window стола».
- Рамка-градиент с кроссфейдом 600 мс — единственный честный индикатор фокуса; без неё фокус
  «не виден» (gap_review п.6). Делается серверными окнами из §1.4.

---

## 3. 60 Гц против 180 Гц

### 3.1 Физика ощущения

Монитор пользователя: DP-1 2560×1440@180, VRR. Air M4: 60 Гц, нет ProMotion. Sample-and-hold:
воспринимаемый смаз при слежении глазом ≈ скорость × время удержания кадра. drift (k=210, d=24):
пиковая скорость 10 % пути за кадр на 60 Гц. Половина экрана (735 pt = 1470 px): 147 px за 16.7 мс
≈ 16.6 мм смаза; на Linux 42 px за 5.5 мс ≈ 9.8 мм. Разница ×1.7 — это и есть «резко», при
идентичной кривой. Ни одна кривая с тем же временем успокоения не даст заметно меньшую пиковую
скорость: для любой разумной ease `v_peak·T95 ≈ 1.5–2`.

### 3.2 Оценка растяжения ×1.2 (TIME_SCALE в engine.py)

Формула `k'=k/s², d'=d/s` сохраняет ζ=0.828 и перелёт 0.97 % — форма верна. Эффект: пик 10 % →
8.3 % за кадр, смаз 147 → 123 px, 95 % хода 250 → 300 мс. Это компромисс, не 1:1, и он не
закрывает разрыв (нужно s≈1.7, чтобы сравнять смаз, — уже «медленно»). Рекомендации:
- применять только к пространственным переменным (windowsMove/In/Out, workspaces); альфу, border,
  fade не трогать — у них нет смаза, растяжение лишь делает интерфейс «вязким»;
- s = 1.15–1.2, не больше; обязательно A/B с пользователем на одной перекладке (1.0 / 1.2 / 1.35);
- вынести в конфиг как явную опцию «компенсация 60 Гц», по умолчанию 1.0.

### 3.3 Что действительно даёт лёгкость на 60 Гц (по убыванию эффекта)

1. **Ноль задержки и одна волна** (§1.1–1.2). Сейчас окно после паузы стартует с пика — это
   воспринимается как удар. Числа-цель: нажатие → первый сдвиг ≤ 22 мс; на одно событие ровно одна
   пачка; `t0 = te − T` (уже так).
2. **Ни одного пропущенного/удвоенного кадра**. Снять нагрузку с главного потока WS (§1.3).
   Проверка: 45 из 45 кадров с разными значениями на rec2 (захват 60 к/с через
   `CGWindowListCreateImage` видит трансформ) и `frames == ticks`.
3. **Округление к пикселю устройства, без субпикселей**. Hyprland рендерит боксы в целых px
   (Linux scale 1). У нас B — double; WS при дробном translate включает линейную фильтрацию
   (`MetalBacking::WantsLinearFiltering` 186db6fd4, `determine_filter_flags_for_surface_layer`
   186e22464) → текст «плывёт» в хвосте (450 мс сабпиксельного дохода после 99 %). Округлять B к
   0.5 pt (1 device px на Retina) в `frame_win` — хвост станет «сесть и замереть», как в Hyprland.
   Проверка: скриншот середины хвоста — текст резкий.
4. **Фаза тика относительно vblank** (§1.10): текущая схема корректна при джиттере таймера
   < ~6 мс; измерить `last_dt`; при пропусках — тик из notify-proc `UpdateDisplays`.
5. **Motion blur / кроссфейд кадров** — единственный способ сделать 60 Гц *похожим* на 180 по
   смазу (это то, что делают игры при 30/60 fps). Hyprland его не имеет; в WS нет примитива —
   только путь Б (свой фрагментный шейдер слоя окна с 4–8 выборками вдоль вектора скорости на
   длину `v·T`). Даёт мягкость, но мылит текст на 0.25 с. Рекомендую как опцию после пути Б, не
   раньше.
6. **Честные 180 Гц**: подключить его монитор к Air по USB-C→DP 1.4 (2560×1440@180 8-бит ≈ 16.6
   Гбит/с < 25.9 HBR3; macOS предлагает частоты, которые даёт EDID). Движок читает период из
   `WSDisplayScheduleGetPrevNextVBL(display)` — нужно брать id дисплея окна, а не главного
   (`ctx.display`, `anim4.c:47`). Это единственный путь к 1:1 по ощущению.

### 3.4 Объективная проверка

rec2 на 60 к/с: траектория края по кадрам должна совпасть с `0.026 0.089 0.176 0.273 …` (±1 pt,
0 дублей), старт ≤ 1 кадр после события, одна волна (монотонная скорость без второго разгона).
Телефон 120 к/с с keycastr для латентности.

---

## 4. OpenRunner

На Linux `openrunner` — скрипт в дотфайлах (`bin/openrunner`: kitty → tmux → nvim + консоль, «как
OpenRunner на Mac, только в терминале»). На маке это **его собственное приложение**
`/Applications/OpenRunner.app` (`dev.openrunner.app`, исходники `~/Developer/OpenRunner`, Swift,
редактор+консоль для Python/C++). `binds.py` маппил `openrunner → spotlight` — неверно; основной
агент уже привязал Option+R к `open -a OpenRunner` — это и есть правильное решение (`open -b
dev.openrunner.app`, при живом процессе — фокус окна через `ax_focus`, как `open_or_focus` в
`binds.lua`). «Скрипты плодят консоли»: `kitty --class X -e prog` → `open -na Ghostty --args -e`
создаёт новый процесс Ghostty на каждый бинд; правильнее `ghostty +new-window` /
`ax_menu_press "New Window"` в живом процессе и `-e` через его конфиг команды.

---

## 5. Приоритизированный план

| # | Шаг | Что увидит пользователь | Проверка |
|---|---|---|---|
| 1 | Активный вид всех окон (§2.3 A): досылка Resume прежнему приложению после смены фокуса; без AXRaise | Окна не сереют при переходе фокуса, ничего не «мигает» | Видео 120 к/с: 0 серых кадров у Telegram/Finder при follow_mouse |
| 2 | Протокол события: без снимка на командном пути, один commit на событие, hold=0 для перекладок, AX-опрос новых окон 16 мс | Старт сразу, без «удара»; окно появляется в плитке заметно раньше | нажатие→сдвиг ≤22 мс; одна волна на rec2 |
| 3 | Опрос → события (`SLSRegisterNotifyProc` + EV_* из тика); убрать `alive()`-sleep | Исчезают микрозависания | `frames==ticks`, гистограмма `last_dt` |
| 4 | Округление B к device px; TIME_SCALE только для геометрии, A/B 1.0/1.2 | Хвост «садится», не плывёт; мягче старт | Скриншоты хвоста, выбор пользователя |
| 5 | Подложки и рамка — серверные окна из WS в одном тике; ступенчатое скругление клипа; тень своя | Нет серых прямоугольников и прямых углов, виден фокус (рамка-градиент) | Кадр в t0+200 мс: углы скруглены, тень есть |
| 6 | hide/unhide по §1.6, виртуальные столы slidefade | Нет кикфлипа, столы как в Hyprland | rec2: все окна двух столов в одном кадре |
| 7 | R-shape проверка (`shape_window_with_rect` без WindowMoved) | Скругление/тень сервера на каждом кадре | dtrace счётчик setFrame в приложении |
| 8 | Призрак закрытия из тёплого снимка (`WSCaptureCreateIOSurface…` + образец replace_with_snapshot) | Cmd+W с анимацией 92 % + fade | ≥14 кадров призрака |
| 9 | Путь Б (`generate_layers_for_window` / `WSCompositeSourceLayer`): clamp-to-edge, суперэллипс, блюр, опционально motion blur | 1:1 оформление; «лёгкость» 60 Гц | Наложение на linux_ref |
| 10 | Внешний монитор 180 Гц (если готов) | Настоящие 180 Гц | период из VBL = 5.55 мс |

Пределы, которые не наши: скорость перерисовки Telegram/Electron/Finder; configure до первого кадра
нового окна; при любом s на 60 Гц смаз больше, чем на 180; motion blur мылит текст.
