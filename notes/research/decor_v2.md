# decor_v2: почему рамка фокуса «стесняется» и какое решение правильное
Статус: статика, 2026-10-09. Источники: `cache/sl_dis.txt` (SkyLight 26.7.1 25G241), `hook/src/anim4.c`, `hook/src/chan.h`,
исходник Hyprland (master 5e04ae1 от 2026-10-08, `VERSION` = 0.56.0; тега v0.56.2 в клоне нет; `cache/hyprland-src` пустой,
клон сделан в `/tmp/hyprland-src`), конфиг `~/arch-nebula/.../hypr/nebula/look.lua`.
Живой WS, демон, lldb и канал не трогались. Метки: [V] — проверено по листингу или исходнику, [H] — гипотеза.

## 0. ГЛАВНЫЙ ВОПРОС (доп. от координатора): видит ли WS каждый наш CA-коммит без посторонних событий
**Ответ: да. WS сам подписан на изменения локального контекста окна и сам заказывает перерисовку. Добавленный
`CGXScheduleUpdateDisplaysIntersectingWindow(0, win)` дублирует этот путь: вреда нет, но и причину он не лечит.
Рывки объясняются не «WS не рисует», а (1) гонкой фазы между нашим тиком и обновлением WS и (2) кривой smooth,
сжатой до 150 мс. Правильный путь — CABasicAnimation, кадры которой считает сам CA в момент рендера (это уже начато в
`fade_to`), и вернуть 600 мс.**

Цепочка по листингу:
- [V] `initialize_ca_content_for_context` после создания дерева вызывает `WS::CA::TrackContext(*(cwc+0x40) /*локальный
  ctx окна*/, NULL, options=2)` @18705e88c..18705e898 и `TrackContext(*(cwc+0x50) /*ctx приложения*/, conn, 4|6)` @18705e8b4.
  Там же оба id кладутся в карту ctx→wid (@18705e8c4..18705e8e0 для +0x50, @18705e8e4..18705e908 для +0x40).
- [V] `TrackContext` 186de6000.. регистрирует `CARenderNotificationAddObserver`: тип 0 → `context_did_change` 186de7380
  (если options bit1 или bit2), 5 → `context_will_commit` 186de725c (bit1), 8 → `context_payload_did_change` 186de6f40
  (bit0), 2 → `context_will_destroy` 186de67b8 (всегда) (@186de6538..186de65c0). У локального контекста окна options=2,
  значит did-change подписан.
- [V] `context_did_change`: при флаге info bit2 (= options bit1, @186de74ac) на главном потоке вызывает
  `WSScheduleUpdateForCAContextChange(flag, ctx_id, conn)` 186f91de8 (@186de74d4), с другого потока — то же через
  `perform_on_main_thread_for_notification_info`. Дальше по карте ctx→wid (@186f91ee0) → `WSWindowSessionGetWindowByID` →
  `CGXWindow::intersecting_displays` → `CGXScheduleUpdateDisplay(conn, type, 1, displays)` (@186f91f30).
- [V] Наш вызов `_CGXScheduleUpdateDisplaysIntersectingWindow(x0, CGXWindow*)` 186f94ebc делает ровно
  `intersecting_displays(win)` → `CGXScheduleUpdateDisplay(x0, 0, 1, displays)`. Сигнатура `(0, win)` верна: так зовут
  сами WS @18705a7d4 и @1871a5534. Это дубль автоматического пути.
- [H] Статикой не доказать, что CA шлёт уведомление «did change» на коммит **локального** контекста. Но WS явно подписывает
  на него именно локальный контекст окна (options=2) — иначе подписка не имела бы смысла. Проверить можно без записи в WS:
  Instruments → os_signpost SkyLight `Updater_CAContextDidChange` («CA context %08x did-change, seed = %u», литерал
  @186de7448). На каждый наш коммит должен приходить сигнал с id = `*(cwc+0x40)`.
- [H] «Скриншот сам вызывает композит, поэтому замеры были плавными» — правдоподобно, но статикой не проверял. Мерить
  надо потоком ScreenCaptureKit (SCStream 60 к/с), а не `CGDisplayCreateImage`, или камерой.

Почему всё-таки рвано:
1. [H, сильная] **Два независимых таймера.** Наш тик (`te + T·phase`) и `update_display_callback` WS (nextWakeup+0.5 мс)
   идут на одном потоке, но с разной фазой. Если коммит кадра N иногда успевает к обновлению N, а иногда только к N+1,
   на экране видны двойные шаги и пропуски. Счётчики `te_skips`/`ticks_late` это частично видят.
2. [V расчёт] **Кривая smooth (0.25,1,0.5,1) на 150 мс** = 9 кадров со значениями 0.38, 0.64, 0.80, 0.90, 0.96, 0.98, 1, 1, 1.
   Видимы 3–4 скачка, и пропуск одного кадра даёт 0→64%. На 600 мс (Hyprland: border speed 6) первые шаги 0.11, 0.21,
   0.30, … за 36 кадров. Сжатие до 150 мс само делает переход «рваным»; для 1:1 вернуть 600 мс.
3. [H] Перескоки цели фокуса (follow_mouse) перезапускают кроссфейд с середины.

Правильный путь — анимация на стороне рендера:
- [V] WS читает у CA «следующее время обновления» для анимаций в дереве окна: `CARenderUpdateGetNextTime` в
  `WSCAWindowBacking::BeginUpdate` (@186ea7a5c) → `WSCALayerBacking::ResolveUpdate` 186d9b800 сохраняет его в
  backing+0x148 и сверяет с расписанием дисплея (`WSDisplayScheduleGetInfo`, `CARenderUpdateGetTime`). Время кадра CA
  ставит `CARenderUpdateSetVBLTime`. Так работают обычные CA-анимации приложений. Значит, `CABasicAnimation` на
  `opacity`/`shadowOpacity` наших слоёв WS будет сам рисовать каждый кадр, со значением на момент показа, без наших
  коммитов и без гонки фазы. [H: что это распространяется и на слои локального контекста — сильная, тот же рендер дерева]
- `CAMediaTimingFunction functionWithControlPoints::::` — та же кубическая безье, что у Hyprland: для bezier-кривых это 1:1.
  Для пружин CASpringAnimation не равна hyprutils (не 1:1).
- Ревью нового `fade_to` (anim4.c): типы вызовов на arm64 верные (`numberWithFloat:` — s0; `functionWithControlPoints::::` —
  s0..s3; `setDuration:` — d0; `opacity`/`shadowOpacity` — возврат float в s0). Ретаргет от `presentationLayer` правильный.
  Модельное значение ставится в `to`, а `removedOnCompletion` по умолчанию YES, поэтому после конца значение верное.
  Замечания: (а) после перехода на анимации `sched_win` и покадровые вызовы `border_win` ради opacity не нужны — достаточно
  одного коммита на смену фокуса; (б) `fadeShadow` у Hyprland — своя кривая и длительность (`d->sbez`/`d->sdur`), не
  border; (в) пока у кроссфейда нижнее кольцо I постоянно (см. §2), лучше анимировать и I.opacity 1→0, иначе итог не
  равен лерпу Hyprland.

## Главный вывод
1. Причина «яркие углы, тусклые стороны, ярче после клика» — **порядок окон по z, а не CA-свойства рамки**. Наше кольцо
   лежит в CA-дереве своего окна и рисуется на z этого окна [V compositor.md §1в]. follow_mouse окно не поднимает, поэтому
   соседи, которые выше по z, рисуют свою тень (наш слой S, offset 10 вниз, плюс вернувшаяся системная) **поверх** кольца
   активного окна вдоль общих сторон. Углы выглядывают, потому что у соседей там скруглённые углы и тень спадает. Клик
   активирует приложение, macOS поднимает окно — кольцо становится полностью ярким. [H, сильная: совпадает с замером 99 против 211]
2. Hyprland делает наоборот: **сфокусированное тайловое окно рисуется последним**, поверх соседей и их теней
   [V `src/render/Renderer.cpp:496-510`]. Для ощущения 1:1 это обязательно.
3. Вторая причина: гашение системной тени у нас одноразовое (`shadow_make`), а WS **перезаписывает** у слоя Shadow
   `shadowOpacity/Radius/Path` (бит 0xf) и `borderWidth/Color` (контур Tahoe, бит 0xe) при каждой смене active↔inactive
   [V 186e24d8c, 186e24bb8, 186e26140, 186e26260]. После переключений вокруг окон возвращаются тень Tahoe и контур и ещё
   сильнее затемняют кольца соседей.
4. WS не накладывает на Server root и наши подслои фильтров, затемнения или десатурации неактивного окна. Root получает
   только position/bounds/opacity/transform/meshTransform/rasterizationScale/createsCompositingGroup/mask (drag fade) [V].
5. Рекомендация: оставить слои в дереве окна (это правильная глубина) и добавить: **(г) серверный подъём активного окна без
   активации** через `_CGXOrderWindow` 18705d11c из движка; **тег DisableShadow (бит 3)** вместо одноразового обнуления;
   пересборку слоёв при пересоздании `CAWindowContent`; одну CA-транзакцию на тик. Оверлей-окно (б) и путь Б (в) для
   этой жалобы не нужны.

## 1. Что WS делает со слоями окна при активации
- `_WSWindowSetHasActiveShadow(win, bool)` 1870710e8 [V]: меняет бит1 `win+0x3dc`. Если активная (`win+0x358`) и
  неактивная (`win+0x398`) тени различаются (`WSShadowPropertiesAreEqual`), вызывает `invalidate_shadow_frame` и
  `invalidate_shadow_and_schedule_update`.
- `_WSWindowShadowCurrentPropertiesPtr` 18714e890 [V]: `WSWindowHasActiveShadow ? WSWindowGetActiveShadow : …GetInactiveShadow`.
- `ca_window_prep_ingestion_phase` 186e23c1c: стадия сравнения staged-полей cwc с текущими [V]:
  - тень: сравнивает свойства (`WSShadowPropertiesAreEqual` @186e24c98), путь `win+0x868` (`CGPathEqualToPath` @186e24cb8),
    радиус из маски окна и масштаб. При отличии пишет `cwc+0x190..` и ставит **бит 0xf** (`orr #0x8000` @186e24d8c);
  - контур: альфа `props+0x10` и ширина берутся из тех же свойств тени (@186e24b04..186e24b94). При отличии ставит
    **бит 0xe** (`orr #0x4000` @186e24bb8).
  Значит, смена active↔inactive, смена маски или радиуса и смена масштаба заново включают на Shadow системную тень и
  контур. Сравниваются staged-поля, а не значения слоя, поэтому наши записи в слой WS не видит и молча затирает.
- Применение (@186e25bb4 и дальше) [V]: бит 0xf → у Shadow (+0x88) `setPunchoutShadow/Rim*/ShadowOffset/ShadowOpacity/
  ShadowPath/ShadowRadius/SoftRim/CornerRadius/CornerContents*` (@186e260e8..186e261ec); бит 0xe → у Shadow
  `setBorderColor` (`CGColorGetConstantColor` + альфа), `setBorderWidth`, `setBorderPathIsBounds` (@186e26254..186e26270).
- Полный список селекторов, которые ingestion шлёт слоям (выборка по `ldr x0,[x20,#off]` перед `objc_msgSend$…`) [V]:
  - root +0x80: `setBounds/Position/Opacity/Transform/MeshTransform/RasterizationScale/CreatesCompositingGroup`, `setMask`
    (только drag fade, бит 8 @186e262f8);
  - Shadow +0x88: тень, rim, border, corner*, `setMaskedCorners`, `setFilters` (бит 4: `CAFilter colorBrightness
    "window_brightness"` из `win+0x844` @186e25d40);
  - Hosting +0x98: bounds, cornerRadius/Curve, masksToBounds, maskedCorners, add/insertSublayer (служебные хосты и блюр).
  `setSublayers:` вызывается только у Drag Fade (+0xa8). Наши подслои root WS не трогает, маску Hosting тоже. [V]
- Затемнение неактивных окон. `win+0x844` пишет только `_CGXSetWindowListBrightness` (str @18706a934). Вызывают его
  только клиентские пути `__XSetWindowListBrightness` и `PKGTransactionSetWindowBrightness` [V], автоматического
  затемнения при деактивации в WS нет. Фильтр стоит на Shadow, то есть действует на Shadow→Hosting→контент, а не на наши
  слои-соседи в root. Неактивный вид рисует AppKit внутри контента приложения. «Ярче после клика» фильтрами не объясняется. [V/H]
- Пересоздание дерева. `CGXWindow::initialize_ca_content_for_context` 18705e3ac выделяет новый `CAWindowContent`, ставит
  грязные биты `0x1fffffff` (@18705e450) и **уничтожает старый** (`~CAWindowContent` + free @18705e90c..18705e91c) [V].
  Наши слои остаются в мёртвом дереве (см. §5, п.1).

## 2. «Ярко только в углах» — разбор border_make/border_win
- Геометрия градиента верна [V по расчёту]: start (0,1), end (0.5,−0.207) при оси Y вверх дают progress = 0.293x + 0.707y,
  как `gradient.glsl` при 45° (`progress = y·sin a + x·(1−sin a)`).
- Радиусы: внешний 20, внутренний край кольца = 18 continuous, Hosting = 18 continuous. В Hyprland outerRound =
  18 + 2 − 2(√2−1)·max(2−2.6, 0) = 20 [V `CHyprBorderDecoration.cpp:69-70`]. По геометрии кольцо не может давать
  «толстые углы». [H, слабо: суперэллипс p=2.6 у Hyprland и continuous у CA немного различаются — на полпикселя, не на яркость]
- Сам градиент: у peach→blue (ffb4a4→7fd0f5) персиковый только около левого верхнего угла. Верх (progress ≤ 0.29)
  смешан примерно (236,184,176), левый бок уходит в голубой. Отчасти «персиковый угол» — это сам эталон. Замер
  (211,183,174) близок к ожидаемому верху с поправкой на α 0.933 и фон. [H]
- Реальная потеря яркости — от теней соседей сверху по z (§ главный вывод). Замер 99 против 211 у нижнего окна и пропажа
  эффекта после клика это подтверждают. Без смены z любые правки CA-слоёв рамки не помогут.
- Отличие от Hyprland по кроссфейду. У нас неактивное кольцо I (α 0.333) всегда лежит под градиентом G, а G меняет
  opacity. Hyprland рисует одну рамку и лерпит цвета `grad1→grad2` (`data.lerp = GRADIENT.progress`)
  [V `CHyprBorderDecoration.cpp:83-88`, `border.glsl`]. Итог у нас: активный цвет слегка подмешан неактивным, итоговая
  α 0.955 вместо 0.933, а в середине кроссфейда кривая альфы другая. Для 1:1 при op→1 гасить I (opacity 1−op) или
  лерпить цвета в одном слое.

## 3. Как рисует Hyprland [V, /tmp/hyprland-src]
- Порядок: `renderWorkspaceWindows` (`src/render/Renderer.cpp:466-560`). Тайловые окна рисуются по порядку
  `windowState()->windows()`, сфокусированное пропускается (`:497-500`) и рисуется **последним среди тайловых** (`:509-510`).
  Затем fadeout'ы, попапы, плавающие окна (поверх тайловых).
- Внутри окна (`renderWindow`, `:689-750`): сначала декорации `DECORATION_LAYER_BOTTOM` (тень,
  `CHyprDropShadowDecoration.cpp:261`), затем UNDER, поверхность, OVER (рамка `CHyprBorderDecoration.cpp:144`, glow
  `CHyprInnerGlowDecoration.cpp:170`).
- Следствие. Тень окна, нарисованного позже, ложится на рамки окон, нарисованных раньше, — у неактивных это нормально и
  есть в эталоне. Но **активное окно рисуется последним**: его рамку тени соседей не перекрывают никогда, а его тень
  (0x77) ложится на соседей. При gaps_in 5 (зазор 10 pt) и offset 10 это видно на каждом шве.
- Обязательно для «как в Hyprland»: (1) активное тайловое окно выше всех тайловых, но ниже плавающих; (2) рамка — лерп
  цветов; (3) тень — своя, системной тени и контура Tahoe нет вообще.

## 4. Правильное «тяжёлое» решение — варианты
### (г) Серверный порядок: поднять активное окно без активации — РЕКОМЕНДУЮ (основа)
- `_CGXOrderWindow(CGXConnection* conn, uint wid, CGSOrderOp op, uint relativeTo)` 18705d11c [V по регистрам] — обёртка
  над `CGXOrderWindowListSpaceSwitchOptions(conn, &wid, &op, &rel, 1, false)` 18705ae54. Клиентский `__XOrderWindow`
  1871b5f60 делает то же, но сначала `connection_holds_rights_on_window(conn, 4, win, 1, 1)`. Поэтому демон напрямую через
  `SLSOrderWindow` чужие окна поднять не может, а движок внутри WS — может, если передаст соединение-владельца
  (`win+0x30`, чтобы не заводить override, как у `put_clip`).
- Внутри `CGXOrderWindowListSpaceSwitchOptions` нет вызовов SetFrontProcess или активации [V по списку вызовов
  900560..901188]. Есть `pkg_space_switch_for_window_order_top` (переход Space, если окно на другом столе — подавать только
  окна текущего стола) и уведомления `finish_order_windows`.
- Как 1:1. Команда канала `OP_RAISE wid` (или поле `deco.focus`). Движок делает `CGXOrderWindow(owner, wid, 1 /*above*/,
  rel)`. `rel` = самое верхнее тайловое окно стола (тогда плавающие и диалоги остаются выше, как во втором проходе
  Hyprland). Точнее эталона — одним вызовом `CGXOrderWindowListSpaceSwitchOptions` с n окнами упорядочить все тайловые
  окна стола по порядку демона, фокус последним: тогда бывшее активное окно возвращается на своё место, как в Hyprland.
- Риски [H]: AppKit узнаёт о смене порядка через уведомления и при следующей активации может переупорядочить свои окна
  (это нормальное поведение); стоимость `finish_order_windows` при n окнах на каждую смену фокуса — замерить
  (`tick_us_max`); значение `CGSOrderOp` above = 1 взято из общедоступных CGS — сверить живьём на одном окне.
  Оценка: 0.5–1 день.

### (а) Свои слои в дереве окна — оставить, но довести [V-основание]
- Глубина правильная, едут с трансформом и альфой окна, WS их не трогает (§1). Не хватает:
  1. системную тень и контур гасить **тегом DisableShadow, бит 3**: `CGXWindow::set_window_list_tags(owner_conn, &win, 1,
     mask(bit3), true)` 187063af0. Тогда `_CGXWindowIsShadowed` 186deac7c вернёт 0 (`WSWindowIsTagBitSet(win,3)`
     @186deacb0), ingestion сам будет держать Shadow без тени и без контура: ветка без свойств обнуляет shadowOpacity и rim
     (@186e25ed4..186e25f9c), альфу и ширину контура (@186e24b44..186e24b94). `set_window_list_tags` сам зовёт
     `invalidate_shadow_frame` [V по списку вызовов]. Снимать при освобождении слота. Альтернатива
     `_WSWindowSetShadowEnable(win)` 18706e764 только сбрасывает бит0 `win+0x3dc` и не ставит «грязь»; обратного
     сеттера я не нашёл — не брать.
  2. пересобирать слои, если `*(win+0x18)` (cwc) сменился (§5, п.1);
  3. одна транзакция на тик для всех окон (сейчас `put_mask` и `border_win` коммитят каждое окно отдельно).
- Перехват после ingestion (повторять наши свойства после каждого прохода WS) не нужен: на Shadow мы больше ничего не
  пишем, а свои слои WS не трогает.

### (б) Своё серверное окно-оверлей рамки — не рекомендую как основу
- Рецепт есть [V `WS::create_shield_window_common` @186d4fb1c..186d4fce4]: `WSWindowCreate` → `+[CAContext
  localContextWithOptions:]` → `CGXWindow::bind_local_ca_client_context(CAContext*, bool, bool)` → транзакция → `setLayer:`.
  Похожие: `create_corner_window` (callsite 187149874), `SarlaccDebugWindow::initialize`.
- Минусы: оверлей должен быть выше соседей, но ниже плавающих окон — та же задача порядка, что в (г); трансформ, альфу и
  Space-переходы приходится синхронизировать отдельно (сейчас всё это даром даёт root окна); тень соседа под активным
  окном всё равно есть, если не поднять само окно. 2–4 дня, выигрыша над (г) нет.

### (в) Свой `WSCompositeSourceLayer` в `Compositor::prepare_layers` (путь Б) — не для этой задачи
- Даёт свой Metal-шейдер (точный border.glsl или shadow.glsl) в любой позиции списка слоёв. Требует патча __TEXT
  (MASTER §9.3, не проверено) — недели и высокий риск падения WS. Нужен только для dual-kawase блюра.

### Рекомендация
(г) + доведённое (а): подъём активного окна серверным `CGXOrderWindow` (порядок как у Hyprland), тень и контур Tahoe
выключены тегом бит 3, кольцо — один лерп цветов. Это убирает «тусклые стороны» и «ярче после клика» на уровне причины.
Проверка: `mtest.py` по швам — яркость кольца сверху у нижнего окна около 211 сразу после смены фокуса (без клика);
снимок: у неактивных соседей тень активного окна ложится на их рамку, как в эталоне.

## 5. Ошибки в коде оформления (anim4.c)
1. [V] **Слои не пересоздаются при новом `CAWindowContent`.** `border_win` проверяет только `!w->bl_in`, `put_mask` — только
   `w->mask` и размеры. После `initialize_ca_content_for_context` (старое дерево уничтожено @18705e914) наши I/G/S/F и маска
   остаются в мёртвом дереве: рамка и маска пропадают до освобождения слота. Исправление: хранить cwc/root (в ctx движка,
   чтобы не менять ABI `ch_win`) и при несовпадении освобождать старые слои и строить заново.
2. [V] **Одноразовый `sys_off`** (`shadow_make` гасит Shadow один раз) — ingestion возвращает тень и контур при каждом
   active↔inactive (§1). Решение — тег бит 3 (§4а).
3. [V по коду] **Порядок z не управляется** — основная причина жалобы (§ главный вывод).
4. [V по коду] **Несколько коммитов на окно за тик.** `put_mask` (в `frame_win`) и `border_win` открывают и коммитят свои
   `WSCAContextScopeTransaction` для одного и того же контекста. Плюс лишняя цена (`tick_us_max` уже 1.15 мс); риска
   «половинчатого кадра» на одном потоке нет [H]. Свести к одной транзакции на тик (план П4 шаг 4).
5. [V по API] **`arrayWithObjects:count:` с nil** — если `CGColorCreateSRGB` вернул NULL, `+[NSArray
   arrayWithObjects:count:]` бросит исключение внутри WindowServer (падение). Проверять `cols[i]` и пропускать.
6. [V] Autorelease: `[CALayer layer]`, `arrayWithObjects:`, `stringWithUTF8String:` — **не утечка**. Таймеры WS
   выполняются внутри `objc_autoreleasePoolPush/Pop` в `CGXRunOneServicesPass` (push @186de8acc, `run_timer_pass`
   @186de8b00/186de8b74/186de8fac, pop @186de9114).
7. [V] Типы `objc_msgSend` на arm64 проверены, ошибок нет: `setOpacity:`/`setShadowOpacity:` — float (s0); `setBorderWidth:`,
   `setCornerRadius:`, `setShadowRadius:` — double; `setShadowOffset:`/`setStartPoint:` — HFA из 2 double; `bounds` и
   `convertRect:toLayer:` — CGRect HFA d0–d3 (layer в x2); `insertSublayer:atIndex:` — unsigned; `setHidden:` — BOOL в w2;
   `borderWidth`/`cornerRadius` (probe) — d0.
8. [V по коду] `border_make`: если I создан, а G нет (или наоборот) — ранний выход без сохранения, и на каждом тике снова
   `probe_layers` + создание объектов (объекты освободит пул, но это лишняя работа). Мелочь.
9. [V по коду] Тикающее чтение `[Hosting bounds]` и `corner()` для каждого окна в каждом тике, даже в покое. Дёшево, но
   при 64 слотах стоит кэшировать по seed. Мелочь.
10. [H] Popin (stretch): кольцо строится вокруг A и масштабируется трансформом root, толщина рамки меняется вместе с
    масштабом. В Hyprland толщина постоянна. Для 1:1 при stretch задавать кольцу ширину `wd/sx`.
11. [V] Drag fade: WS может поставить `setMask` на root (бит 8) — это обрежет и наши слои. Проявится только при системном
    drag-тайлинге.
