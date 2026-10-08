# compositor: доступ к поверхности окна внутри WS, свой рендер, снимок, скругление/тень, баг Telegram
Статус: ГОТОВО (статика, 2026-10-08). Источники: /tmp/sl_dis.txt, /tmp/sl_map.tsv, extracted/{SkyLight,QuartzCore},
dyld cache (только чтение — GOT/vtable/CFString). Живой WS, демон, lldb/dtrace НЕ трогались.
Метки: [V] — проверено по листингу/кэшу (адрес указан), [гипотеза] — не проверено, нужна живая проверка.
Адреса — статические (SkyLight macOS 26.7.1 25G241); в живом WS + slide (как в HANDOFF §5).

## Что видит пользователь и что это даст (коротко)
- Сейчас во время перекладки окно режется ПРЯМОУГОЛЬНИКОМ на уровне экрана: пропадают скругление и
  тень на срезанных краях, а пустоту закрывает серое окно-подложка из другого процесса. Отсюда
  «половинка без скругления», «серые прямоугольники», «серый экран» у Telegram.
- Главная находка: на macOS 26 у КАЖДОГО окна внутри WindowServer есть собственное дерево слоёв
  CoreAnimation (Server root → Shadow → Hosting → Window → контент приложения). Родное скругление
  окна — это просто `cornerRadius + cornerCurve=continuous + masksToBounds` на слое Hosting, родная
  тень — `shadow*` на слое Shadow. Рисует это QuartzCore прямо в кадр WS, в правильной глубине.
- Значит, «рамку B» надо делать не серверным клипом, а СВОИМИ слоями в этом дереве: маска со
  скруглением (суперэллипс) на Hosting, своя тень под окном, рамка-градиент и glow над окном, блюр
  фона — всё внутри дерева окна. Тогда скругление и тень едут вместе с видимой рамкой каждый кадр,
  правильно перекрываются соседями, затухают вместе с окном. Без патча кода WS, без подложек.
- Для закрытия окна (windowsOut) в SkyLight уже есть готовый «клон окна» (`CreateCloneOfWindow`) и
  синхронное внутреннее событие «окно сейчас будет уничтожено» — снимок можно снять, пока окно живо,
  и доиграть 92%+затухание на клоне.
- Предел: свой Metal-шейдер (точный dual-kawase, clamp-to-edge как в Hyprland) в глубину конкретного
  окна вставляется только перехватом кода сборки кадра — описан путь, но это отдельный риск. Через
  слои CA доступны гауссов блюр/насыщенность/яркость (близко к Hyprland, не бит-в-бит).

## Журнал находок (детали)


### 1. Конвейер композита: что такое слой окна и кто его рисует
- [V] `CompositorMetal::composite(layers, dest, bool, bool)` 186f4052c: `Compositor::prepare_layers`
  186e96b40 → `MetalContext::StartComposite` → `_MetalCompositeLayers(ctx, layers, dest)` 186f40a4c →
  (если dest+0x52 бит0 — вывод на дисплей) обход `metalCallbacks` 1ea5fb3b8 → `EndCurrentComposite`.
  Значит, наш колбэк сейчас рисует ПОСЛЕ всех слоёв — поверх всего (z-проблема подтверждена).
- [V] `_MetalCompositeLayers` 186f40a4c: список слоёв — односвязный, `layer+0x8` = next; на каждый
  `_MetalCompositeLayer(ctx, layer, dest, 0)` 186f40ac8, затем `shape_free(layer+0x248)`,
  `shape_free(layer+0x250)` (две «формы рисования» слоя, освобождаются после кадра).
- [V] Диспетчер `_MetalCompositeLayer` 186f40ac8 (поля `WSCompositeSourceLayer`):
  - `+0x220 == 1` → `metal_composite_ripple` 186f42094 (хвост-вызов @186f41f34);
  - `+0x288 != 0` (и не повторный вход) → легаси-блюр фона: `WSCompositeSourceLayerCreateCombinedDrawShape(
    +0x248, +0x250)` 186e98170, `shape_inset` на радиус, `ShaderComposer::HorizontalBackgroundBlur(int,float)`
    186e7b2a0 + `VerticalBackgroundBlurComposite` 186e7b4d8 во временные `WS::SurfacePool::Acquire` текстуры,
    рекурсивный `_MetalCompositeLayer` @186f41b18 — т.е. ГОТОВЫЙ двухпроходный блюр «под слоем» уже есть;
  - `+0x48 != 0` → CA-плагин: блок `___MetalCompositeLayer_block_invoke` 186f42878 через
    `WSSessionConnectionPerformWithPluginOwner` @186f40ecc; внутри блока `CARenderMTLSetDestinationTextures`
    @186f429ac, `CARenderOGLRenderDisplayWithOptions` @186f42ef8 / `CARenderOGLRender` @186f42fd4 —
    рендерер QuartzCore рисует дерево CA прямо в текстуру назначения;
  - `+0x40 == 0` и (`+0x219` бит0 или `+0x180 == 0xe`) → `metal_composite_shadow` 186f43074 (@186f41324);
  - `+0x2a0` = backing (C++ объект, vptr подписан дискриминатором 0x5176): `+0x180 != 0` → хвост-вызов
    vtable+0x20 = `RenderToDestination(ctx, layer, dest)` (@186f40e30, braa x4 с модификатором 0x7861);
  - backing==0: `+0x180 == 0x1e` → `metal_composite_group` 186f43c9c (@186f41cc8; офскрин группы);
    `+0x180 == 0` → `_MetalCompositeSimpleColorLayer` 186ee4b78 (цвет ARGB в `+0x184`, альфа `+0x188`,
    добавка `+0x21c`); защищённый контент → цветная заливка (`WSCompositeSourceLayerGetConstantColor`).
  - Итого `+0x180` — тип слоя; `+0x1a0` — CGRegion границ слоя (`CGRegionGetBoundingBox` @186f40bbc);
    `+0x188` — альфа слоя (float).
- [V] Поверхность окна → пиксели: `MetalBacking::RenderToDestination` 186db8b88:
  `DetermineShaderOptions(layer,dest,bool)` 186db95cc → битовая маска опций →
  `ShaderComposer::UberComposite(MTLPixelFormat, opts)` 186e7adbc (специализированный шейдер),
  `setFragmentSamplerState`, `SetRenderFragmentTexture` (текстура = `backing vtable+0x100/…` →
  `MetalBacking::Texture(MetalContext*, u64)` 186db85b4), затем по типу трансформа
  `_RenderAffineMetal` / `_Render3DMetal` / `_RenderMeshMetal` (@186db92a4/@186db92c8/@186db9300).
  Подклассы: `MetalTiledBacking::RenderToDestination` 186dbf164, `MetalIOAccelHybridBacking::…` 186dbd234;
  vtables: MetalBacking 1eeccd7a8, MetalIOSurfaceBacking 1eeccd8d8, MetalIOAccelSurfaceBacking 1eeccdb68,
  WSCALayerBacking 1eeccca60, WSCAWindowBacking 1eecd2ee0.

### 1б. ГЛАВНОЕ: у каждого окна в WS есть СВОЁ дерево CALayer (macOS 26, «defenestrator3»)
- [V] `CGXWindow::initialize_ca_content_for_context(uint ctx, uint, bool)` 18705e3ac создаёт
  `WS::CAWindowContent` (указатель в `CGXWindow+0x18`; HANDOFF это поле уже знал) и в нём ЛОКАЛЬНЫЙ
  CA-контекст WS: `+[CAContext localContextWithOptions:]` @18705e604 → `cwc+0x38` (CAContext*), `cwc+0x40` —
  его contextId. Дерево (имена — CFString из кэша, классы — по GOT через dyld cache):
  ```
  CAContext(cwc+0x38).layer = "Server root"      cwc+0x80  CALayer  (setLayer: @18705e6e8)
  ├─ "Shadow"                                     cwc+0x88  CALayer  — тень/обводка/скругление/яркость
  │   └─ "Hosting"                                cwc+0x98  CALayer  — cornerRadius + masksToBounds (обрезка)
  │       └─ "Window"                             cwc+0x90  CAWindowLayer (flattenMode=Never)
  │           └─ "Client Content Host"            cwc+0x60  CALayerHost, contextId = cwc+0x50 (CA-контекст приложения)
  │       └─ "Window Manager Host" (по флагу)     cwc+0x68  CALayerHost, contextId = cwc+0xd0
  "Drag Fade"                                      cwc+0xa8  CALayer (маска затухания при перетаскивании)
  ```
  (адреса: new_layer @18705e66c/67c/68c/69c, `[CAWindowLayer layer]` @18705e6ac — класс GOT 1e61664c8 →
  `_OBJC_CLASS_$_CAWindowLayer` 1edca2f60; `kCAWindowLayerFlattenModeNever` 1e67b4d88; new_layer_host @18705e6d8;
  addSublayer: @18705e6fc / @18705e758 / @18705e778 / @18705e7a4; setContextId: @18705e7b0.)
- [V] Применение свойств — `WS::Updater::defenestrator3::ca_window_prep_ingestion_phase(CGXWindow*, UpdateState&,
  WSCAContextScopeTransaction&)` 186e23c1c (`x20 = *(win+0x18)`, @186e23c5c). Двойной буфер состояний
  `CAWindowContentUpdateState` по 0x190 байт с `cwc+0x260` (индекс `cwc+0x588`). Сначала значения окна
  кладутся в «staged» поля cwc и выставляются грязные биты `cwc+0xc8`, затем (с @186e25bb4) — в слои:
  | бит `+0xc8` | staged поле cwc | откуда (CGXWindow) | что ставится |
  |---|---|---|---|
  | 3 | `+0x108` pos, `+0x118..0x137` bounds | рамка окна | setPosition (root), setBounds у ВСЕХ слоёв (+0x80,+0x88,+0x98,+0x90,+0xb0,+0x60,+0x70,+0x78,+0xa0,+0x68) @186e25c84.. |
  | 6 | `+0x170` радиус (float) | `resolved_corner_radius()` @186e24920 | Shadow/Hosting: setCornerRadius + `setCornerCurve: kCACornerCurveContinuous` (GOT 1e6166668 → 1e67be550) + Hosting `setMasksToBounds:(r>0)` @186e26058..186e260ac |
  | 0xf | `+0x190` shadowRadius, `+0x194` opacity, `+0x1a8` (−offsetY), `+0x100` shadowPath, `+0x17c` радиус, `+0xd8` маска окна | WSWindowShadow* | Shadow: punchoutShadow, rim*, shadow*, `setCornerContents:(WSWindowMaskGetCGImage)` @186e25eac.. |
  | 0xe | `+0x184` альфа, `+0xf8` ширина | | Shadow: setBorderColor/Width @186e261f4 |
  | 0xb | `+0x174` | альфа окна `win+0x1d8..` | root: setOpacity @186e26044 |
  | 0x14 | `+0x1d0..+0x24f` CATransform3D | трансформ окна | root: setTransform @186e26294 |
  | 4 | `+0x16c` | `win+0x844` | Shadow: filters=[CAFilter kCAFilterColorBrightness «window_brightness», inputAmount] @186e25d40 |
  | 0x18 | `+0x158` | `win+0x864` | setMaskedCorners (Shadow, Hosting) @186e25bdc |
  | 0xa | `+0x148` CAMeshTransform | frame_mesh | root: setMeshTransform |
  | 8 | | drag fade | root: setMask / +0xa8 setSublayers |
- ВЫВОД: «родное» скругление окна macOS 26 — это `Hosting.masksToBounds + cornerRadius + continuous`
  (суперэллипс Apple) внутри CA, а тень — `Shadow.shadow*`/`punchoutShadow` того же дерева. Рендерит это
  рендерер QuartzCore внутри WS. Наша серверная обрезка `set_window_list_global_clip_shape` 18705f624 —
  ДРУГОЙ уровень: CGRegion в `win+0x160` → `update_global_clip_shape()` → обрезает всё экранное
  представление окна (`copy_clipped_screen_visible_frame_shape`) прямоугольником, поэтому режет и
  CA-скругление, и CA-тень. [V по вызовам @18705f770/@18705f784]

### 1в. Как CA-окно попадает в кадр (оба пути — в одном списке слоёв)
- [V] CA-окно в списке `WSCompositeSourceLayer` имеет `+0x48` ≠ 0 и рисуется блоком
  `___MetalCompositeLayer_block_invoke` 186f42878: `CARenderMTLSetDestinationTextures` (текстура
  назначения WS) → `MetalContext::GetCARenderMTLState` → `CARenderMTLSetState` (общий command buffer WS) →
  `CARenderOGLSetUpdateRegion`(форма рисования слоя, `WSCompositeSourceLayerCreateCombinedDrawShape`) →
  `CARenderOGLRenderDisplayWithOptions`/`CARenderOGLRender` → `CARenderMTLGetState`/`MetalContext::SetCARenderMTLState`.
  Т.е. рендерер QuartzCore рисует дерево окна (п.1б) прямо в кадр WS, в z-позиции окна, в том же
  command buffer. Наш metalCallbacks идёт после ВСЕХ слоёв (п.1).
- [V] Генерация слоёв: `generate_layers_for_window(CGXRedrawState*, CGXWindow*)` 186e19454 →
  `layergen_ca_backed_window(CGXRedrawState*, CGXWindow*, CGSRegionObject*, uint)` 186e224e8 (CA-окна) /
  `generate_layers_for_window_surfaces` 186e1f9a8 (поверхности) / `generate_layers_for_legacy_shadow` 186e1c2b0 /
  `layergen_frozen_window` 186e1ee0c; клип окна — `_CGXCreateCombinedWindowClipShape` 186f2cb88.
- [V] «Отсоединённый» рендер: `gWSDetachedDefenestratorEnabled` 1ea5fac9c, `gWSDetachedLayersAllowDirectPresent`
  1ea5fac9a, `evaluate_for_detached_only_render` 187168688, `_WSCompositorSetLayerDetachment` 186e98068 —
  объясняет, почему `composite()` зовётся ~6 раз/с в покое: обновления только контента CA-окна
  рендерятся без полного прохода WS [гипотеза о точной механике; факт флагов — V].
- Вывод для «своего шейдера в z окна»: без патча кода есть два входа: (а) свойства/подслои CA-дерева
  окна (п.1б) — рисует QuartzCore, наши только фильтры CA (gaussianBlur, colorSaturate, brightness,
  маски, градиенты), своего Metal нет; (б) свой `WSCompositeSourceLayer` в списке — тип с backing,
  у которого vtable+0x20 = наш `RenderToDestination(MetalContext*, layer, dest)` (диспетчер зовёт
  `braa` с модификатором `(vtable+0x20)|0x7861<<48`, vptr подписан DA с `(obj)|0x5176<<48`, @186f40db4..186f40e30).
  Вставить слой в список можно только в момент сборки (`Compositor::prepare_layers` 186e96b40 / после
  `generate_layers_for_window`) — это требует перехвата кода [гипотеза: патч __TEXT через
  mach_vm_protect(VM_PROT_COPY) при amfi_get_out_of_my_way=1 — не проверено].

### 2. Снимок для windowsOut и удержание последнего кадра
- [V] Готовый примитив Apple «клон окна»: `CreateCloneOfWindow(CGXWindow* src, CGRect frame, const PKGDisplay*,
  bool server_owned)` 18709e984 (static): `PKGDisplayGetBounds` → `WS::Displays::Manager::display_with_options`
  → display vtable+0x530 = Compositor* → `WSWindowCreate(owner = server_owned ? NULL : *(src+0x30), 3,
  CGRegion(frame), 0x3800)` 187068b1c → уровень 0x19, `WSWindowSetTitle`, теги, `WSWindowSetDepth(4)`,
  `WSWindowSetHasAlpha(1)`, `WSWindowSetResolution` → `Compositor vtable+0xa0 =
  CreateCaptureSurface(CGRect, 0, 0, WSPixelFormat 4, float res, true, CGColorSpace*, 1, 0)`
  (`CompositorMetal::CreateCaptureSurface` 186f4020c) → `CaptureSurface vtable+0x38 =
  CaptureSurfaceMetal::Populate(CGXWindowSubArray{src}, WSWindowGetShape(new), &out, opts 0x1201, …)` 187086c78
  (vtable CaptureSurfaceMetal 1eecda6d8 проверен по кэшу: +0x28 Populate(layer*), +0x30 Populate(CGXWindow*,
  CGSRegionObject*) 187086e5c, +0x38 Populate(список)) → `WSWindowSetCapturedContent(new, capsurf)`
  18707325c (пишет `win+0x8b0`). Возвращает новое CGXWindow*. Используется статус-баром
  (`CreateClonedContentForItem` 18709f6d4). Тот же рецепт — `pkg_tile_entry_replace_with_snapshot_for_connection`
  186e3cd4c (там Populate по всем окнам Space).
  => Снимок закрываемого окна = обычное серверное окно со статичным содержимым (IOSurface в
  CaptureSurface); его двигает/масштабирует/гасит наш движок теми же `CGXSetWindowTransform3DList` /
  `CGXSetWindowListAlpha`; масштаб снимка идёт через `MetalBacking::RenderToDestination` (Affine/Render3D).
- [V] Момент «окно ещё живо»: `CGXWindow::release_window(CGXConnection*, CGXWindow*)` 18705aa44 СИНХРОННО
  шлёт `WSPostLocalNotification(0x3e9, win, 8)` @18705ab24 (→ `ServerNotifier::invoke_callbacks`, @186e72608)
  ДО `CGXOrderWindowListSpaceSwitchOptions(...out...)` @18705ab78 и до `~CGXWindow` @18705abe8.
  Подписка изнутри WS: `WSAddNotificationCallback(fn /*paciza*/, type, ctx)` 186e743d4; колбэк
  `fn(CGSNotificationType, void *data, uint len, void *ctx)`, для 0x3e9 `data == CGXWindow*`
  (так делает `pkg_tile_window_will_terminate` 186e3c630: `cmp x1, [ctx+0x10]`). Это поправка к
  wayland_gap §1.7 («EV_GONE на следующем кадре — поздно»): в колбэке 0x3e9 окно и его контент ещё целы.
- [V] Другие локальные события окна (тип → кто шлёт): 0x3e8 `WSWindowCreate` (новое окно — мгновенно,
  закрывает «окно видно 0.3 с до popin»), 0x3ee `start_order_window` (без данных, до упорядочивания),
  0x3ea / 0x538 `finish_order_windows` (0x538: данные 12 байт = 3×u32 из состояния упорядочивания, @18705c1b8; какое поле wid, какое op — уточнить живьём),
  0x3eb `~CGXWindow`, 0x3ec `reevaluate_screen_state`; кадр: 0x12c / 0x130 / 0x131 в `WS::Updater::UpdateDisplays`
  (0x131 — после `~WSCAContextScopeTransaction`, т.е. после коммита CA-деревьев, @186e15db4).
- Порядок закрытия в AppKit обычно: order-out (сообщение OrderWindow) → позже TerminateWindow →
  release_window. Значит, ловить надо 0x538 с op=out для отслеживаемого wid: окно уже снято с экрана,
  но CA-контекст приложения ещё жив → клон рисуется [гипотеза: Populate по ordered-out окну — проверить
  живьём]; запасной путь — 0x3e9.
- [V] CA-«зомби»: `_connectionDied` 18708945c: `CARenderContextCanZombify` → если да, контекст не
  уничтожается при смерти процесса (кейс падения приложения, не обычного закрытия).

### 3. Скругление и тень во время анимации: скруглённая маска вместо прямоугольного клипа
- [V] Радиус окна в сервере: `CGXWindow::set_corner_radius(CGXConnection*, double)` 1870657b4: clamp [0,300],
  округление, пишет `win+0x850`, флаг `win+0x928 |= 8`, при смене `resolved_corner_radius` →
  `invalidate_shadow_frame` + грязные флаги. `CGXWindow::resolved_corner_radius() const` 187063110:
  если `win+0x928` бит6 → `win+0x858` (системный радиус), если бит15 → max(`win+0x7b8`, `corner_radius()`),
  иначе `corner_radius()`. Это значение уходит в `cwc+0x170` → `Shadow/Hosting.cornerRadius` + `kCACornerCurveContinuous`
  (п.1б). Клиентские пути: `SLSTransactionSetWindowCornerRadius` 186dd4614, `…SystemCornerRadius` 186dd47c0,
  `…CornerRadiusMaskedCorners` 186dd496c, серверные `PKGTransactionSetWindowCornerRadius` 1870c167c.
- [V] Тень: `SLSSetWindowShadowParameters(cid, wid, double sigma, double density, int offX, int offY)` 187020888 →
  `__CGSSetWindowShadowParametersWithStretch(port, wid, sigma, density, offX, offY, 0, 0, 1)` (хвост @1870208f8);
  сервер `__XSetWindowShadowParametersWithStretch` 1871a65b4 собирает CFDictionary → `WSWindowSetShadowProperties`
  18714d398. CA-тень окна берётся из `WSWindowShadowCurrentPropertiesPtr` 18714e890 (вызовы @186e244f4/@186e24588),
  включение — `CGXWindow::wants_efficient_ca_shadow` 18706599c / `wants_inefficient_ca_shadow` 187065a0c.
  `WSWindowSetShadowEnable` 18706e764 сбрасывает бит0 `win+0x3dc` (видно в первой ветке; второй аргумент не
  разобран). Легаси-тень (не-CA окна) — слой `metal_composite_shadow` 186f43074 + `CompositorMetal::CreateShadowFromLayers`
  186f3e668.
- [V] Что WS НЕ трогает в дереве окна (можно занимать своим): `setMask:` ставится только на Server root (+0x80) и
  только по биту 8 (drag fade, @186e262f8); `setSublayers:` — только у Drag Fade (+0xa8, @186e26304). Маска Hosting,
  произвольные подслои Server root и свойства своих слоёв WS не перезаписывает. Bounds своих слоёв WS не знает.
  (Список всех селекторов WSCAWindowBacking/CAWindowContent собран статикой — других setMask/setSublayers нет.)
- Решение (вместо `set_window_list_global_clip_shape`):
  1. Маска видимой рамки: `Hosting(cwc+0x98).mask = M`, где M — `CAShapeLayer` с путём суперэллипса Hyprland
     (rounding 18, power 2.6, точно по формуле) или `CALayer` с `cornerRadius 18, cornerCurve continuous,
     backgroundColor opaque`; `M.frame = (0, 0, B.w, B.h)` в координатах окна (наш трансформ — чистый сдвиг,
     поэтому левый верх буфера = левый верх B). Результат = uv-обрезка Hyprland «буфер 1:1 от левого верхнего
     угла, лишнее срезано», но со скруглением и сглаживанием CA. [гипотеза: ориентация оси Y слоёв окна
     (geometryFlipped) — проверить одним тестом]
  2. Тень: на время анимации выключить свою тень окна (`SLSSetWindowShadowParameters(cid,wid,0,0,0,0)` или
     `Shadow.shadowOpacity` через пропуск бита 0xf) и держать СВОЙ слой `S` в Server root НИЖЕ Shadow
     (`[root insertSublayer:S below:Shadow]`): `S.shadowPath` = тот же суперэллипс B, `shadowRadius/Opacity/
     Offset(0,10)/Color` из конфига; для 1:1 профиля Hyprland (range 34, render_power 3 — не гаусс) —
     `S.contents` = заранее посчитанная 9-slice картинка тени по формуле Hyprland, `contentsCenter`.
  3. Рамка 2 px градиент 45° и glow: свои слои НАД Shadow в Server root (`CAGradientLayer` с маской-кольцом
     `CAShapeLayer`, glow — такой же слой с размытым кольцом/тенью). Цвет/угол — анимируемые свойства, наш тик.
  4. Всё это внутри CA-дерева окна → глубина правильная (над окнами ниже, под окнами выше), трансформ и альфа
     окна (Server root.transform/opacity, которые ставит наш `CGXSetWindowTransform3DList`/`CGXSetWindowListAlpha`)
     автоматически применяются и к нашим слоям. Подложки hyprdeco и серверный клип больше не нужны.
- Как писать в дерево из нашего кода в WS (главный поток, вне composite()): ObjC-рантайм уже загружен в WS;
  транзакция как у WS: `WSCAContextScopeTransaction::WSCAContextScopeTransaction(WSCAScopeParameters)` 186f2e2e8
  (бит0 параметров = disableActions; делает `[CATransaction begin]`, `setDisableActions:`, `setDisableSignPosts:`),
  `addContextToCommit(CAContext*)` 186f2e83c, `~WSCAContextScopeTransaction()` 186f2e358 (→ `commit`). Образец
  последовательности — `initialize_ca_content_for_context` @18705e62c..18705e65c и `WSCAWindowBacking::AttachSurfaceContext`
  186ea9b78. Доступ: `cwc = *(CGXWindow*+0x18)`, `ctx = *(cwc+0x38)`, слои `+0x80/+0x88/+0x98/+0x90/+0x60`.
- Блюр фона под окном (для прозрачных окон): родной путь `SLSSetWindowBackgroundBlurRadius(cid, wid, int radius)`
  18702cb30 → `WS::CAWindowContent::ensure_background_blur_layer()` 1871520ac (слой `windowServerAware`,
  вставляется `insertSublayer:below:`). Это гаусс CA, не dual-kawase. Приблизить к Hyprland 5×2 + vibrancy 0.22 +
  brightness 0.92 своими CAFilter (gaussianBlur/colorSaturate/colorBrightness) — [гипотеза: подбор сигмы по снимку
  рядом с linux_ref]. Точный dual-kawase — только свой проход в `_MetalCompositeLayer` (п.1в «б»), там же
  возможен clamp-to-edge.

### 4. Баг Telegram: «половинка без скругления», потом норм; при возврате — «через серый экран»
Механизм (по коду `hook/src/anim4.c` `frame_win` и демону `hook/hyprwm.py:269-270` + находки выше):
- Сжатие плитки (Telegram отдаёт половину): демон по сжимающейся оси оставляет приложению СТАРЫЙ (больший)
  размер до `EV_DONE`; движок показывает буфер 1:1 и режет его `put_clip` → `set_window_list_global_clip_shape`
  прямоугольным CGRegion (anim4.c:404). Клип — уровень экрана (п.1б «ВЫВОД»), он срезает CA-скругление и
  CA-тень справа/снизу → «половинка без скругления». После `EV_DONE` демон шлёт конечный размер; Telegram
  перерисовывается за 100–300 мс (wayland_gap §1.5), всё это время держится обрезка (settling, `stable<2`) →
  затем `put_plain` → «потом норм».
- Рост плитки (возврат): по растущей оси размер шлётся сразу; пачка стартует, как только сервер увидел НОВУЮ
  РАМКУ окна (held ждёт изменения A — `actual()`/`w->ax..ah`). Но новая рамка у AppKit появляется в момент
  setFrame, ДО того как Telegram перерисовал содержимое: первые кадры нового размера у Telegram — фон окна
  (его вид раскладывается асинхронно). Плюс в полосе B−A, пока буфер меньше рамки, видна подложка hyprdeco
  цвета `NSColor.windowBackgroundColor` (wayland_gap §1.4, `hook/deco/hyprdeco.m:101`). Итог — «через серый экран».
- [V] Как сервер знает, что приложение реально прислало новый кадр: `WS::CA::GetLastChangeDataForContext(uint
  ctx_id, double& time, uint& seed)` 186de75e4 (зовётся в ingestion @186e24f70, пишет в `cwc+0x71c/+0x720`),
  id контекста приложения — `CGXWindow::ca_client_context_id() const` 187060758 (он же `cwc+0x50`).
Правильное исправление:
1. Убрать прямоугольный клип и подложку: маска-суперэллипс на Hosting + своя тень по B (п.3). Тогда
   «половинка» выглядит как окно Hyprland при resize: скруглено, с тенью, буфер обрезан 1:1.
2. Конечный размер приложению — сразу по обеим осям (как configure в Hyprland). Старый больший буфер
   обрезается маской; меньший (ещё не перерисованный) — дотягивается краем (см. 3).
3. Пока у Telegram «кадр нового размера» не готов, показывать СТАРОЕ содержимое, а не фон: снять клон
   (`CreateCloneOfWindow`, п.2) в момент отправки размера и держать его в B (обрезка маской / растяжение краем),
   пока по `GetLastChangeDataForContext` контекст приложения не сделал ≥2 коммитов после смены рамки и не
   «затих» на 1 кадр (или таймаут ~150 мс) — потом в один кадр снять клон. Это ровно Hyprland: старый буфер
   до прихода нового. [гипотеза: порог «2 коммита» для Telegram подобрать замером]
4. Дотяжка края (буфер меньше B) вместо серого: в Hosting под Window — слой-«полоса» = второй `CALayerHost`
   того же контекста приложения (WS сам держит два хоста: +0x60 и +0x68), обрезанный до последнего столбца/строки
   и растянутый трансформом на ширину пустоты (линейная фильтрация 1-px полосы = clamp-to-edge) [гипотеза];
   упрощённо — `Hosting.backgroundColor` = цвет края (уже есть `ax_edge_color` в `hook/src/axlib.c`).
Честный предел: сама скорость перерисовки Telegram — его; наша часть — не показывать промежуточный фон.

## Шаги для основного агента (каждый с проверкой)
1. Чтение дерева окна (без записи). В установщике движка: `cwc=*(win+0x18)`; прочитать `*(cwc+0x38)` (CAContext),
   `*(cwc+0x80/0x88/0x98/0x90/0x60)`, вызвать `-[CALayer name]` у каждого.
   Проверка: имена «Server root», «Shadow», «Hosting», «Window», «Client Content Host»; `-[CALayer cornerRadius]` у
   Hosting = `resolved_corner_radius` окна; `masksToBounds` = YES.
2. Маска вместо клипа (одно окно Finder, без анимации): в `WSCAContextScopeTransaction` создать CALayer M
   (bg чёрный, cornerRadius 18, cornerCurve continuous), `M.frame=(0,0,w−200,h−100)`, `Hosting.mask=M`, добавить
   контекст в коммит. Проверка: скриншот — правый/нижний край срезан, углы B скруглены и сглажены, координаты
   совпали (если срезало сверху — ось Y перевёрнута, взять `h−…`). Затем `Hosting.mask=nil` — окно как было.
   Проверить, что `set_window_list_global_clip_shape` для этого окна снят (NULL).
3. Своя тень: `SLSSetWindowShadowParameters(cid,wid,0,0,0,0)` + слой S под Shadow с shadowPath=суперэллипс B.
   Проверка: скриншот с тенью вокруг B (не A); перекрытие соседним окном — тень под соседом.
4. Движок v6: `put_clip`/`put_under` заменить на `put_mask(B)` + `put_shadow(B)` + `put_border(B, цвет)` в том же
   тике (одна транзакция на кадр на все окна). Проверка: `scripts/rec.py` перекладка Telegram — 0 кадров с
   прямыми углами/без тени; шаг 16.7 мс без пропусков (CA-транзакция укладывается в кадр — сравнить с текущим).
5. Подписка на события WS: `WSAddNotificationCallback(paciza(fn), 0x3e9, ctx)` и `(…, 0x3e8, …)`, `(…, 0x538, …)`.
   Проверка: счётчики в ctx растут при открытии/закрытии окна; для 0x3e9 `data` = CGXWindow* (сравнить
   `*(u32*)data` с wid закрываемого окна).
6. windowsOut: в колбэке 0x538(out)/0x3e9 вызвать `CreateCloneOfWindow(win, A, PKGDisplay*, true)` (или собрать
   вручную по п.2), поставить клон на уровень/порядок исходного, анимировать 92%+fadeOut, затем
   `CGXWindow::release_window(NULL, clone)`. Проверка: Cmd+W в Finder — видно доигрывание 260 мс; утечки:
   число окон WS (wlist) после 10 закрытий не растёт.
7. Telegram: конечный размер сразу; клон старого содержимого до готовности по `GetLastChangeDataForContext`.
   Проверка: rec 120 к/с, перекладка Telegram туда-обратно — 0 кадров серого фона, 0 кадров без скругления.
8. Блюр: `SLSSetWindowBackgroundBlurRadius` на Ghostty + свои фильтры; сравнение снимка с linux_ref.
   Точный dual-kawase/clamp-to-edge — отдельный этап (перехват `_MetalCompositeLayer`), только после 1–7.
