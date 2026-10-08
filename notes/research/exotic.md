# Экзотические пути: macOS-WM с ощущением Hyprland (2026-10-08)

Автор: исследователь «exotic». Только статика: `/tmp/sl_dis.txt`, `/tmp/sl_map.tsv`, `extracted/{SkyLight,QuartzCore,appkit/AppKit}`,
`nm -u` по Dock/WindowManager на диске. Живой WS не трогал.
Метки: **[V]** — подтверждено адресом/листингом (адреса — статические, slide не учтён); **[H]** — гипотеза; **[ext]** — внешний
источник, сам не проверял. Фокус/серый вид через Resume-событие и клип/декорации подробно разобраны у Fable (`notes/wayland_gap.md`
§1.4, §2). Здесь только то, чего там нет.

---

## 0. Что это даст пользователю (коротко, по убыванию пользы)

1. **Скругление 18, тень и блюр делает сам WindowServer по нашей команде, без своего Metal.** В macOS 26 каждое окно внутри
   WindowServer — это маленькое дерево слоёв CoreAnimation: «корень → тень → подложка → окно → содержимое приложения».
   WS сам переносит в эти слои радиус углов, тень, блюр фона, яркость, прозрачность, трансформ и деформацию сеткой. Для любого
   чужого окна из нашего кода в WS можно вызвать те же серверные функции, что вызывает сама система: `set_corner_radius(18)`,
   радиус фонового блюра, яркость. Это вероятно сразу уберёт «прямоугольные серые углы» и даст гладкое (сглаженное)
   скругление 18. [V — механизм; что выглядит именно так, как надо — проверить глазами]
2. **Анимацию можно отдать рендеру CoreAnimation, а не тикать самим.** Пружина Hyprland (масса–жёсткость–демпфирование)
   математически та же, что у `CASpringAnimation`, а безье — то же, что у `CAMediaTimingFunction`. Если повесить
   *аддитивную* CA-анимацию на корневой слой окна в WS, кадры считает рендер CA на своём потоке точно по развёртке, а не наш
   таймер главного потока: нет дрожи от опозданий таймера, нет нагрузки на главный поток WS, само работает на 120/180 Гц.
   Ретаргет без рывков получается автоматически (сумма аддитивных пружин = пружина с новой целью и сохранённой скоростью).
   Это самая сильная экзотическая идея, но Apple сама так не делает (в SkyLight нет `addAnimation:forKey:`) — [H], нужен
   один живой опыт.
3. **Слайд рабочих столов можно делать одним трансформом на весь стол**, как это делает сам Dock: у Space есть свой трансформ и
   своя альфа (`PKGSpaceSetTransformWithConnection` / `PKGSpaceSetAlphaWithConnection`). Dock именно ими двигает столы
   (импортирует `CGSSpaceSetTransform`, `CGSShowSpaces/HideSpaces`, `CGSManagedDisplaySetCurrentSpace`) — но альфу Dock не
   использует, а нам она даёт «slidefade». [V — функции; согласование с Dock — H]
4. **Системный аниматор SkyLight (PKGAnimation) и «транзакции с длительностью» — тупик.** Там только 6 фиксированных
   безье, линейная интерполяция матриц, тот же таймер главного потока; серверный fade — 30 Гц. Genie/sheet-анимации в
   SkyLight — пустые заглушки. Брать нечего. [V]
5. **«Всегда выглядеть активным» серверным флагом не делается** — ни одного тега/свойства WS на это нет. Есть точный
   внутриприкладной рычаг AppKit: `-[NSWindow _setForceMainAppearance:YES]` + `_setForceActiveControls:YES` — после них
   `_hasActiveAppearance`/`_hasActiveControls` возвращают YES без ключевого окна [V по AppKit]. Но это код в процессе
   приложения (инъекция), т.е. выход за рамки «всё в WS». Полезные теги для оформления есть: без тени (бит 3), сквозь клики
   (бит 9), на всех столах (бит 11), скрыть из Exposé (бит 38) — таблица ниже [V].

---

## 1. Встроенный аниматор SkyLight и «транзакции с длительностью»

### 1.1 PKGAnimation [V]
- Объект (`PKGAnimationCreate` 186d8a910, calloc ≥0x68): +0 refcnt, +4 флаги (бит1 scheduled, бит0 cancelled), +0x10 dealloc,
  +0x18 progress-блок, +0x20 completion-блок, +0x28 t0, +0x30 длительность, +0x38 индекс кривой (>5 → 0), +0x40 UUID дисплея,
  +0x58/+0x60 звенья списка.
- `PKGAnimationPush(anim, curve, progressBlock, completionBlock, d0=duration)` 186d8aa4c.
- `_PKGAnimationCallback` 186d8afec: t=(now−t0)/dur → UnitBezier (Ньютон 8 итераций, eps = 1/(200·dur), затем бисекция) →
  progress-блок `(block, anim, value, done)`. Таблица 6 кривых 1871ce4f0 (коэффициенты ax,bx,cx,ay,by,cy; контрольные точки
  восстановил я): 0=(0.25,0.1,0.25,1) ease, 1=linear, 2=(0.42,0,1,1), 3=(0,0,0.58,1), 4=(0.42,0,0.58,1), 5=(0.2,0.23,0.2,0.95).
  **Пружин нет.**
- Такт: `__PKGAnimationScheduleCallback` 186d8ac90 → `reschedule_callback_on_session(gMainThreadQueue 1ea5f9e50, …)`;
  время следующего тика = минимум по дисплеям (виртуальный метод дисплея +0x540) или now+1/60 (1871cbf58). Это ровно тот
  таймер главного потока, который уже использует наш `anim4.c`.
- `PKGAnimationTransactionBegin/Commit` 186d8b3bc/186d8b408 — общий t0 для пачки (у нас уже есть атомарная пачка через chan).
- `PKGWindowTransformAnimationCreate(win, key, ?, CATransform3D* from, CATransform3D* to, curve, progress, completion, dur)`
  18700263c: интерполирует **только аффинную часть покомпонентно** (`CATransform3DGetAffineTransform` + lerp) и зовёт
  `WSSetWindowTransform(0, win, w2, w3, &m)`. Используется системным drag-тайлингом (`animate_drag_transform` 186f11c54,
  `animate_tile_to_index` 186f0fd30), меню-баром, статус-айтемами.
- `PKGSpaceTransformAnimationCreate` — только block_invoke 186e7bef4 (линейный lerp CGAffineTransform →
  `PKGSpaceSetTransformWithConnection(space, &t, opts, 0)`).

**Вывод:** «отдать кривую системе» через PKGAnimation = потерять пружины drift/bounce и ничего не выиграть по такту.
Не брать. Единственная польза — подтверждение, что `PKGSpaceSetTransformWithConnection(..., conn=0)` вызывается изнутри WS
без соединения (см. §2).

### 1.2 Транзакции и серверный fade [V]
- У `SLSTransaction*` (158 функций) нет «длительности»; единственное анимированное — `SLSTransactionSetWindowAlphaAnimated(txn,
  wid, alpha, dur)` 186dcdb24.
- `CGXSetWindowListAlpha(conn, win, float alpha, float dur)` 187069dd0: при dur>0 → `CGXWindow::fade_begin` 18705c514 →
  таймер `window_fade_timer_callback` 18705c960 с периодом **1/30 с** (1871cc2f8 = 0.0333) и кривой 0.5·(1−cos πt).
  30 Гц — непригодно. (Наш вызов с dur=0 — мгновенный путь `set_window_alphas`, верно.)
- Свойства окна `FadeOnOrderOut` (bool) + `FadeDuration` (float) в словаре win+0x88 (CFString 1eecf7398/1eecf73b8,
  читаются в `start_order_window`) — сервер сам гасит окно при order-out. Тот же 30-Гц таймер. Для windowsOut не годится,
  но пригодится знать, что order-out может быть «мягким».

### 1.3 Мёртвые API [V]
`SLSCreateGenieWindowAnimation`, `SLSCreateSheetWindowAnimation*`, `SLSSetWindowAnimationProgress`, `SLSWindowAnimation*`,
`SLSReleaseWindowAnimation` (186d719f8..186d71a4c) — `mov w0,#0x3ee/#0x3e9; ret`. Genie теперь делает Dock через варп
(`CGSSetWindowWarp`, см. §3.4).

### 1.4 Настоящий «системный» путь для кривых — CoreAnimation в WS [H, сильная]
См. §3: окно в WS — слои в **локальном CAContext WindowServer**, а расписание кадров WS спрашивает у CA
(`SLCADisplay::needs_update` 18710760c → `[display needsUpdate]`; `SLCADisplay::next_wakeup_time` 18710cf58 →
`[display nextWakeupTime]`). Значит, явная CA-анимация на этих слоях должна сама будить дисплей и считаться рендером CA.

Как это ложится на Hyprland:
- drift/любая пружина Hyprland: x'' = −k·x − d·x' (масса 1) ⇔ `CASpringAnimation` (mass=1, stiffness=k, damping=d).
  Отличие только в критерии конца (у CA `settlingDuration`, у Hyprland |Δ|≤0.001 и |v|≤0.001) — визуально хвост тот же.
- безье Hyprland ⇔ `+[CAMediaTimingFunction functionWithControlPoints::::]` (селектор есть в SkyLight 1 раз — [V]).
  Перелёт y>1 (overshot/bounce) — [H], CA обычно принимает y вне [0,1]; иначе — `CAKeyframeAnimation` по 255 точкам, которые
  мы уже запекаем.
- Схема «аддитивной анимации»: модель (реальная геометрия/наш итоговый трансформ) сразу ставится в конечное значение, а на
  корневой слой окна (content+0x80 «Server root») вешается `CASpringAnimation` по `transform` (или `position`/`bounds.size`)
  с `additive=YES`, from = (старое − новое), to = 0. Ретаргет — ещё одна аддитивная пружина сверху: сумма решений линейного
  уравнения = продолжение пружины с новой целью и той же скоростью — это и есть retarget hyprutils.

За: шаг ровно по развёртке на любой частоте (180 Гц на его мониторе бесплатно), главный поток WS свободен, нет 30–130 мс
старта (анимация стартует в коммите). Против/риски: (1) WS свои слои коммитит с `setDisableActions:YES` и сам анимаций не
вешает — путь не обкатан, возможна ситуация, когда рендер CA не продвигает анимацию без «грязи» от WS [H];
(2) ingestion WS перезаписывает `transform` слоя +0x80 при изменении трансформа окна (бит 0x100000 в content+0xc8) —
аддитивная анимация от этого не страдает, но наш `CGXSetWindowTransform3DList` на время CA-анимации трогать нельзя;
(3) снимки (CGWindowList) видят модель, а не анимацию — как и сейчас; (4) клип `set_window_list_global_clip_shape` CA не
анимирует — обрезку тоже надо делать слоем (§3.3). Проверка — шаг Ш3 в конце.

---

## 2. Spaces / Mission Control / Stage Manager как источник готовых анимаций

### 2.1 Что реально есть [V]
- У Space есть **трансформ и альфа, применяемые ко всему столу при композите**:
  `PKGSpaceSetTransformWithConnection(PKGSpace*, CGAffineTransform* (6 double), int opts, CGXConnection* conn)` 186e40d24 и
  `PKGSpaceSetAlphaWithConnection(PKGSpace*, float a /*клэмп 0..1*/, CGXConnection*)` 186e40f8c (идут через
  `packages_space_foreach_workspace` → `WSWorkspaceSet{Transform,Alpha}WithConnection`). `PKGSpaceForID` 186e34428,
  `PKGSpaceGetTransform` 186e39640, `PKGSpacesShow` 186e3b1b0, `PKGSpacesHide` 186e418f4, `PKGSpaceCreate` 186e34f6c,
  `PKGSpaceAddWindow` 186e406e8, `PKGSpacesAddWindowsWithConnection` 186e3a814, `PKGSpaceSetAbsoluteLevel` 186e4142c.
- Клиентский путь проверяет право: `__CGXSpaceSetTransform` 186d96390 и `__XSpaceSetAlpha` 18719821c зовут
  `PKGSpaceManagedByConnection` 186e34468 (для управляемых столов — только «универсальный владелец», т.е. Dock/WM; для
  неуправляемых — тот же pid). Изнутри WS проверку можно обойти, вызывая PKG-функции напрямую; блок анимации самой системы
  зовёт `PKGSpaceSetTransformWithConnection(..., conn=0)` (186e7bf84) — значит conn=0 допустим.
- Dock импортирует [V, `nm -u`]: `CGSSpaceSetTransform`, `CGSShowSpaces`, `CGSHideSpaces`, `CGSManagedDisplaySetCurrentSpace`,
  `CGSManagedDisplaySetIsAnimating`, `CGSSpaceCreate`, `CGSSetWindowWarp`, `SLSTransactionSetWindowWarp`,
  `CGSSetWindowTransformAtPlacement`. WindowManager.app — `CGSShowSpaces/HideSpaces`, `CGSManagedDisplaySetCurrentSpace`,
  `CGSSpaceGetTransform`. Т.е. системный слайд столов = Dock: показать оба стола → SetIsAnimating → покадровый
  `SpaceSetTransform` → SetCurrentSpace → Hide [последовательность H, набор функций V]. `CGSSpaceSetAlpha` Dock не импортирует.
- Exposé/Mission Control: в WS только флаги (`WSWindowSessionSetExposeAnimating` 187010918, тег `kCGSIgnoreForExposeTagBit`);
  саму анимацию считает Dock своими трансформами окон. Stage Manager — WindowManager.app. Готовой серверной «анимации
  слайда/затухания», которую можно было бы «дёрнуть», нет.

### 2.2 Что из этого брать
- **Не** «дёргать» Dock/Mission Control: кривые там Apple, и любая системная анимация конфликтует с нашим слотом трансформа
  (Fable §1.9).
- **Брать примитивы**: slidefade 12 % одним вызовом на стол — трансформ Space (сдвиг ±0.12·W) + альфа Space. Это атомарно
  для всех окон стола (не N вызовов на окно, нет рассинхрона окон и подложек-декораций, если они в том же Space).
- Варианты (по риску):
  - (а) Свои столы остаются виртуальными внутри одного системного Space (план Fable §2.5), анимация — нашими трансформами
    окон. Безопасно, уже почти есть.
  - (б) **Свои неуправляемые Space’ы в WS** (`PKGSpaceCreate` + `PKGSpacesAddWindowsWithConnection` + Show/Hide), переход =
    `PKGSpaceSetTransform`+`PKGSpaceSetAlpha` на двух столах из `anim_tick`. Окно видно, если показан любой его Space.
    Риск [H]: Dock/WindowManager/Mission Control не знают про эти столы; окна, убранные из пользовательского Space Dock’а,
    могут пропасть из Exposé/Cmd-Tab или быть «возвращены» системой. Внешний прецедент [ext]: библиотека SkyLightWindow
    (Lakr233) создаёт свой Space (`SLSSpaceCreate(cid,1,0)` + `SLSSpaceSetAbsoluteLevel` + `SLSShowSpaces` +
    `SLSSpaceAddWindowsAndRemoveFromSpaces`) для показа окон поверх экрана блокировки — механизм рабочий.
  - (в) Системные Spaces + своя анимация вместо Dock’овской: из WS мгновенно переключить стол и анимировать трансформ/альфу
    обоих. Риск высокий [H]: Dock не узнает о смене текущего стола (yabai делает это через инъекцию в Dock именно чтобы
    Dock остался согласован).
- `PKGSpaceSetAbsoluteLevel` / `SLSSpaceSetAbsoluteLevel` — собственный стол на абсолютном уровне поверх всего: место для
  наших декораций/оверлеев (аналог layer-shell), чтобы они не путались с окнами приложений [V функции, H польза].

---

## 3. Окно как CALayer в WS: трансформ/маска/скругление/фильтры без своего Metal

### 3.1 Дерево слоёв окна [V]
`CGXWindow::initialize_ca_content_for_context(uint,uint,bool)` (вход ~18705e4xx; ключевые инструкции 18705e604..18705e7c8):
```
CAWindowContent (указатель в CGXWindow+0x18), +0x38 = свой локальный CAContext (localContextWithOptions:)
content+0x80 "Server root"          ← context.layer; WS кладёт сюда transform и meshTransform окна
  └ +0x88 "Shadow"                  ← cornerRadius, cornerCurve, тень CA, rim (Liquid Glass), border, фильтр window_brightness
      └ +0x98 "Hosting"
          └ +0x90 "Window"           ← flattenMode, rasterizationScale, minificationFilter
              └ +0x60 "Client Content Host"  (CALayerHost, contextId = CAContext приложения)
content+0xa8 "Drag Fade";  content+0xb0 — CABackdropLayer фонового блюра
```
(имена — CFString 1eecfa898 / 8b8 / 8d8 / 8f8 / 918 / 938.) Коммит — `WSCAContextScopeTransaction`: ctor 186f2e2e8 =
`[CATransaction begin]` + `setDisableActions:YES`; dtor 186f2e358 — commit контекстов. Перенос состояния окна в слои —
`WS::Updater::defenestrator3::ca_window_prep_ingestion_phase(CGXWindow*, UpdateState&, WSCAContextScopeTransaction&)`
186e23c1c, по флагам «грязи» content+0xc8.

### 3.2 Какие поля окна во что превращаются [V]
| Слой | Свойство CA | Откуда | Серверный сеттер |
|---|---|---|---|
| +0x80 | `transform` | content+0x1d0..0x24f (`layer_to_window_transform`) | `CGXSetWindowTransform3DList` (наш) |
| +0x80 | `meshTransform` | content+0x148 (`frame_mesh`) | `CGXWindow::set_mesh_warp(conn, w, h, const float*)` 1870649c4 (клиент `SLSSetWindowWarp` 187021774) |
| +0x88 | `cornerRadius`/`cornerCurve` | content+0x17c ← `resolved_corner_radius` 187063110 | `CGXWindow::set_corner_radius(conn, double)` 1870657b4: клэмп 0..300, округление, win+0x850, флаг 0x8 в win+0x928, инвалидирует тень |
| +0x88 | `shadowRadius/Opacity/Offset/Path`, `punchoutShadow`, rim | `WSWindowShadowCurrentPropertiesPtr` | серверные параметры тени окна (`SLSSetWindowShadowParameters`, Fable) |
| +0x88 | filter "window_brightness" (`inputAmount`) | win+0x844 | `CGXSetWindowListBrightness(conn, uint* wids, float* v, int n)` 18706a7fc, v ∈ [−1,1] |
| +0xb0 | CABackdropLayer + CAFilter "legacy_WS_blur": `inputRadius`=r/2.8, `inputNormalizeEdges`; `scale` 1/0.5/0.25/0.125 при r/2.8 >3.5/7/14 | win+0x7a0 (uint радиус), win+0x7a4 (opacity hint) | `__XSetWindowBackgroundBlurRadius` 1871a53f4 (клиент `SLSSetWindowBackgroundBlurRadius` 18702cb30 — тот, что зовут iTerm2/Alacritty для своих окон [ext]) |
| все | opacity (content+0x174) | win+0x1d8 · win+0x1dc · win+0x1e0 | `CGXSetWindowListAlpha` (3 независимых множителя альфы) |
| +0x88 | `borderColor/Width` | content+0xf8, +0x184, цвет — системная константа по флагу | системная обводка; градиент сюда не задать |

Тип фильтра блюра: SkyLight импортирует `kCAFilterGaussianBlur`, `kCAFilterColorSaturate`, `kCAFilterColorBrightness`,
`kCAFilterVibrantColorMatrix`… (nm), и ключи `inputRadius`/`inputNormalizeEdges` — значит, блюр гауссов [V импорт, H точный слот GOT].
В QuartzCore есть фильтры `gaussianBlur`, `variableBlur`, `colorSaturate`, `colorBrightness`, `vibrantColorMatrix`,
кривая углов `continuousCorners` (строки QuartzCore) [V].

### 3.3 Что это даёт против текущей схемы
- **Скругление 18 всем окнам** — один вызов `CGXWindow::set_corner_radius(win, conn, 18.0)` из нашего кода в WS. WS сам
  скруглит и содержимое, и тень, со сглаживанием CA. [V механизм, H вид]. Hyprland `rounding_power 2.6` — это суперэллипс;
  CA даёт `continuous` (сквиркл, близко) — 1:1 не будет, но ближе, чем ступенчатый регион.
- **Блюр фона** под прозрачными окнами (терминалы) — радиус в win+0x7a0 через тот же путь, что `__XSetWindowBackgroundBlurRadius`
  (без проверки прав, если звать внутреннюю часть / писать поле + `WSDisplayManagerInvalidateGeometrySeed`). Это гаусс,
  не dual-kawase; vibrancy/brightness Hyprland можно добрать своими `colorSaturate`/`colorBrightness` в массив `filters`
  backdrop-слоя [H — WS перезапишет `filters` при смене радиуса].
- **Своя тень**: параметры тени окна сервера → CA-тень слоя «Shadow». Range 34 / offset (0,10) / α 0.467 задаются
  серверными параметрами тени (функции у Fable) — WS сам переводит их в CA. [H соответствие единиц]
- **Обрезка B без прямоугольного клипа** (главная боль Fable §1.4): вместо `set_window_list_global_clip_shape` —
  `bounds`+`masksToBounds`+`cornerRadius` на слое «Hosting» (+0x98). Маску на «Server root» НЕ использовать: ingestion
  на одном из путей делает `[root setMask:nil]` (186e262f8) [V]. Тогда обрезка скруглённая,
  тень по скруглённой форме, всё анимируется CA. Риск [H]: WS переустанавливает bounds слоёв при изменении рамки окна
  (`setBounds:`/`setFrame:` в ingestion для +0x60/+0x70/+0x78/+0xa0/+0x68/+0xb0) — значения надо ставить после ingestion
  (наш тик уже после) и повторять после каждого configure.
- **Свои слои рамки/glow** (градиент 45°, кроссфейд 600 мс): `CAGradientLayer` + маска-кольцо, добавленные сабслоем в
  «Server root» (+0x80). Едут с окном в том же коммите, без отдельных окон-подложек и без процесса hyprdeco. [H — единственный `setSublayers:` в ingestion
  бьёт по «Drag Fade» (+0xa8, `[dragFade setSublayers:nil]` 186e26304), не по +0x80 [V]; но при пересоздании контента окна
  (initialize_ca_content_for_context) наши сабслои пропадут — переустанавливать.]
- **Деформация сеткой (варп)**: `set_mesh_warp` → `meshTransform`. Пригодно для «тянущегося» содержимого при resize
  (Hyprland во время resize показывает растянутый старый буфер), для «желе»-эффектов. Это путь Dock-genie. [V механизм]

### 3.4 Риски общего характера
- Писать в слои WS напрямую = менять CA-объекты WS с нашего кода на главном потоке; это тот же поток, что ingestion, поэтому
  гонок нет, но коммит нужен: `[CATransaction begin] … [CATransaction commit]` (+ при необходимости `[CATransaction flush]`) [H].
- Объекты ObjC из freestanding-кода: нужны `objc_msgSend`, селекторы, классы через ctx (как сейчас передаются exp/sin);
  arm64e — указатели функций подписывать как в anim4.
- Поля CAWindowContent и CGXWindow — версии 25G241; при обновлении macOS сверять заново.

---

## 4. Виртуальные столы без системных Spaces (как AeroSpace)

Серверные примитивы [V]:
- Порядок: `CGXOrderWindow` 18705d11c → `CGXOrderWindowListSpaceSwitchOptions` (статик), `CGXOrderWindowListWithOperation`
  187069c50; внутри `start_order_window` — `CGXPostWindowNotification` + `WSPostLocalNotification` (о скрытии узнают Dock/WM).
- Уровень: `SLSSetWindowLevel` 18701e37c, `CGXSetWindowLevelForGroup` 186fb4598.
- Теги: `CGXWindow::set_window_list_tags(conn, CGXWindow* const*, n, WSWindowTagBitMask, bool set)` 187063af0.
- Space-примитивы — §2.

Варианты прятать окна неактивного стола:
| Способ | Плюсы | Минусы |
|---|---|---|
| Увод за экран (AeroSpace) | без особых прав, приложение не замечает, переживает рестарт WS | край окна может «торчать», приложение с min-size мешает, Exposé показывает их |
| Server order-out из WS | окно честно невидимо, нет хит-теста, приложение получает occlusion (экономия) | приложение при активации (клик в Dock, Cmd-Tab) может само `orderFront` → окно всплывёт на чужом столе; нужен перехват по уведомлению [H] |
| α=0 + тег IgnoreForEvents (бит 9) | мгновенно, без событий приложению | окно «видимо» для системы: рисуется, тратит GPU, участвует в окклюзии |
| Свой неуправляемый Space (§2.2б) | slidefade одним трансформом/альфой стола | несогласованность с Dock/Mission Control [H] |

Рекомендация: (1) столы — виртуальные; переход анимировать трансформами окон (уже в движке) либо CA-аддитивом (§1.4);
(2) по окончании ухода окна — server order-out; (3) при появлении окна неактивного стола (`kCGSWindowIsOrderedIn`-подобное
уведомление) — снова order-out и пометить «вернуть на свой стол». Свой Space — только если (а) окажется недостаточно плавным.

---

## 5. Недокументированные теги/флаги окна

### 5.1 Таблица тегов [V]
Массив имён по номеру бита — SkyLight файл 0x5bf428 (16 байт/бит, пустые слоты = неиспользуемые биты). Бит 3 подтверждён
кодом: `CGXWindowIsShadowed` 186deac7c = `WSWindowIsShadowEnabled && !WSWindowIsTagBitSet(win, 3)`. Бит 11 совпадает с
известным значением yabai (0x800 = «на всех столах») [ext].

| бит | имя | польза для нас |
|---|---|---|
| 0 | DocumentWindow | — |
| 1 | FloatingWindow | признак плавающего окна |
| 3 | **DisableShadow** | убрать системную тень (когда рисуем свою) |
| 9 | **IgnoreForEvents** | сквозь клики (наши оверлеи/рамки; скрытые окна) |
| 10 | OpaqueForEvents | — |
| 11 | **OnAllWorkspaces** | «pin» окна на все столы |
| 13 | KitVisible | — |
| 14 | HideOnDeactivate | — |
| 15/16 | Avoids/PreventsActivation | клик не активирует приложение (follow-mouse без подъёма) |
| 18 | IgnoresCycle | исключить из Cmd-` |
| 21 | IgnoreAsFrontWindow | — |
| 24 | DontHide | — |
| 25 | DontDimWindowDisplay | — |
| 28 | ActivationWindowLevel | — |
| 35 | MeshedWindow | окно с варпом |
| 37 | AvoidsCapture | исключить из снимков/записи (наши декорации) |
| 38 | **IgnoreForExpose** | спрятать наши служебные окна из Mission Control |
| 39 | Hidden | — |
| 42 | FullScreen | — |
| 44 | SuperSticky | — |
| 46/47 | MenuBar / MergesWithMenuBar | — |
| 49 | DesktopPicture | — |
| 55 | NeverFlattenSurfacesDuringSwipes | — |
| 56/57 | FullScreenCapable / FullScreenTileCapable | выключить системный fullscreen-tile у тайловых окон [H] |

(Полный список: 0 Document, 1 Floating, 2 DoNotShowBadgeInDock, 3 DisableShadow, 5 SetsCursorInBackground, 6 WorksWhenModal,
7 Attached, 8 IgnoreAlphaForDragging, 9 IgnoreForEvents, 10 OpaqueForEvents, 11 OnAllWorkspaces, 12 PointerEventsAvoidCPS,
13 KitVisible, 14 HideOnDeactivate, 15 AvoidsActivation, 16 PreventsActivation, 17 IgnoresOption, 18 IgnoresCycle,
19 DefersOrdering, 20 DefersActivation, 21 IgnoreAsFrontWindow, 22 EnableServerSideDrag, 23 MouseDownEventsGrabbed,
24 DontHide, 25 DontDimWindowDisplay, 26 InstantMouserWindow, 27 WindowOwnerFollowsForeground, 28 ActivationWindowLevel,
29 BringOwningApplicationForward, 30 PermittedBeforeLogin, 31 ModalWindow, 33 FollowsUser, 34 DoesNotCastMirrorReflection,
35 MeshedWindow, 36 CoreDragIsDraggingWindow, 37 AvoidsCapture, 38 IgnoreForExpose, 39 Hidden, 40 IncludeInCycle,
41 WantGesturesInBackground, 42 FullScreen, 43 WindowIsMagicZoom, 44 SuperSticky, 46 kSLSMenuBar, 47 MergesWithMenuBar,
48 NeverSticky, 49 DesktopPicture, 50 IgnoresWorkspaceHeuristics, 51 OrdersForwardWhenSurfaceFlushed,
54 DragsMovementGroupParent, 55 NeverFlattenSurfacesDuringSwipes, 56 FullScreenCapable, 57 FullScreenTileCapable,
59 kSLSShareAlongWithParent.)

### 5.2 «Всегда выглядеть активным» [V по AppKit, путь доставки H]
- Серверного тега/свойства «appear active» **нет** (ни в таблице тегов, ни среди ключей свойств; `WSSetWindowHasActiveAppearance`
  меняет только серверную тень — Fable §2.2).
- В AppKit (`extracted/appkit/AppKit`):
  - `-[NSWindow(NSWindow_Theme) hasMainAppearance]` 184a13dc0: если в `_auxiliaryStorage+0xf8` стоит бит 44
    (forceMainAppearance) или бит 59 (hasMainAppearance) → YES (кроме случая, когда окно уже key).
  - `_hasActiveAppearance` 184a1392c = hasKeyAppearance || hasMainAppearance || sheet → значит **force-main ⇒ активный вид**.
  - `_hasActiveControls` 184aa6394: бит forceActiveControls (aux+0xf0 бит1) ⇒ YES (цветные светофоры, акцентные кнопки).
  - Сеттеры: `_setForceMainAppearance:` 185748380 (ставит бит, `_setFrameNeedsDisplay:YES`), `_setForceActiveControls:` 184bae330.
- Доставка — только кодом в процессе приложения: `DYLD_INSERT_LIBRARIES` при запуске (с `amfi_get_out_of_my_way=1` dyld,
  вероятно, разрешит и для hardened-приложений [H]) или инъекция через task_for_pid, как yabai-SA в Dock [H]. Песочница
  (как у WindowManager) блокирует загрузку после старта — только до инициализации песочницы. Побочка: ВСЕ окна приложения
  рисуются активными, включая окна, у которых нет фокуса клавиатуры — именно то, чего хочет пользователь (в Hyprland
  неактивные окна выглядят так же). Поведение текстовых курсоров не меняется (key-фокус настоящий только у одного).
- Без инъекции — вариант Fable (досылка `kCGSEventResume`) остаётся единственным.

### 5.3 Прочие флаги/свойства окна [V]
- Свойства окна (словарь win+0x88), ставятся `SLSSetWindowProperty` → `__CGXSetWindowProperty` 1870884c8 →
  `WSWindowSetUntrustedProperty` (чёрный список ключей: orderingGroup, movementGroup, captureGroup, captureChildGroup, …).
  Найденные читаемые сервером ключи: `FadeOnOrderOut`, `FadeDuration`.
- Своя форма: `shape_window`/`set_window_list_global_clip_shape` — у Fable; плюс `set_corner_radius` (§3.2) и варп-сетка.

---

## 6. Конкретные шаги для основного агента (каждый — с проверкой)

Ш1. **Скругление 18 силами WS** (30 мин, низкий риск). В движке добавить вызов
`CGXWindow::set_corner_radius(CGXWindow*, CGXConnection* = *(win+0x30), double 18.0)` (статик 1870657b4) для тайловых окон.
Проверка: скриншот/глаза — углы окна и тени скруглены, края сглажены; `resolved_corner_radius` (187063110) возвращает 18.
Откат: вызвать с исходным значением (`CGXWindow::corner_radius` 187062fc8 до изменения).

Ш2. **Фоновый блюр и яркость без Metal** (30 мин). Для одного прозрачного окна (Ghostty с прозрачностью) записать радиус
как это делает `__XSetWindowBackgroundBlurRadius` (поля win+0x7a0 = радиус, флаг в win+0x928 как в 1871a54cc,
`WSDisplayManagerInvalidateGeometrySeed`) — либо, проще и надёжнее, вызвать из процесса самого Ghostty `SLSSetWindowBackgroundBlurRadius`
(для своих окон права есть). Яркость: `CGXSetWindowListBrightness(0, &wid, &v, 1)`, v=−0.2. Проверка: глазами — фон
размыт / окно темнее; снять — 0.

Ш3. **Опыт «анимация силами CA»** (1–2 ч, средний риск, главный). На одном окне: взять `content = *(win+0x18)`,
`root = *(content+0x80)`; в `[CATransaction begin]` создать `CABasicAnimation` по `transform.translation.x`, `additive=YES`,
from=−200, to=0, duration 1 с (линейно) → `[root addAnimation:forKey:]` → `[CATransaction commit]`. Проверка: окно плавно
съезжает на 200 pt за 1 с при НЕподвижном нашем движке; замер `scripts/rec.py` — шаг ровно по развёртке, 60 кадров/с.
Если не движется или движется рывками раз в N кадров — CA не будит дисплей сам: путь закрыт (записать вывод).
Если работает: повторить с `CASpringAnimation` (mass 1, stiffness 210, damping 24) и сравнить траекторию с
`anim4.c` (rec.py, совпадение по кадрам ≤1 px).

Ш4. **Обрезка B скруглённой маской** (после Ш3). Вместо глобального клипа — `masksToBounds=YES` + `bounds` + `cornerRadius 18`
на «Hosting» (content+0x98); проверить, что WS не перезаписывает bounds между configure (dtrace-счётчик не нужен — глазами и
скриншотом). Проверка: при resize ±150 — край обрезки скруглён, тень следует.

Ш5. **Slidefade стола одним вызовом** (1 ч). Прототип на неуправляемом Space: из WS `PKGSpaceCreate` + добавить 2 тестовых
окна + `PKGSpacesShow`; в тике менять `PKGSpaceSetTransformWithConnection(space, &t, 0, 0)` и
`PKGSpaceSetAlphaWithConnection(space, a, 0)`. Проверка: оба окна едут и гаснут синхронно; после — Mission Control и
Cmd-Tab: видны ли окна, не «вернул» ли их Dock (это и решает выбор варианта §4).

Ш6. **Теги для служебного** (15 мин). Нашим окнам-декорациям (пока они есть) — биты 9 (сквозь клики), 37 (не в снимках),
38 (не в Exposé) через `CGXWindow::set_window_list_tags` 187063af0; тайловым окнам при своей тени — бит 3.
Проверка: клик проходит сквозь рамку; Mission Control не показывает подложки; тени нет у окна с битом 3.

Ш7. (опционально, решение пользователя) **«Всегда активный вид»** — dylib с `+load`, который на
`NSWindowDidBecomeKey/ResignKey/DidUpdate` ставит всем окнам `_setForceMainAppearance:YES` и `_setForceActiveControls:YES`;
запуск одного приложения с `DYLD_INSERT_LIBRARIES`. Проверка: у приложения без фокуса светофоры цветные, сайдбар не серый.
Это код в чужом процессе — спросить пользователя до внедрения.
