# beyond_bounds: выход за прямоугольник окна + незаметная смена буфера при resize

Статус: статика, 2026-10-09. Источники: `cache/sl_dis.txt`, `cache/sl_syms.tsv`, `extracted/{SkyLight,appkit/AppKit,wmapp/WindowManager}`,
`/tmp/hyprland-src` (v0.56.2), дотфайлы `~/arch-nebula/.../hypr/nebula/look.lua`, `notes/anim_feel.md`, `notes/research/compositor.md`,
`notes/research/windowctl.md`, `notes/research/close_clone.md`, `hook/src/anim4.c`.
Живой WS / lldb / сокет демона НЕ трогались.
Метки: [V] — проверено по листингу (адрес указан); [H] — гипотеза/не проверено живьём. Адреса статические (SkyLight 26.7.1 25G241), в живом WS +slide.

---

## ГЛАВНЫЙ ВЫВОД И РЕКОМЕНДАЦИЯ (сначала прочти это)

1. **Проблема 1 решена статически и причина НЕ там, где искали.** CA-дерево окна рисуется не прямоугольником окна, а
   формой `frame_bounds` — это bbox окна, **раздутый на радиус тени + сдвиг тени**, НО только пока окно считается
   «теневым» (`_CGXWindowIsShadowed` == true) и включён глобал `gWSCAWindowShadowsEnabled`. Наш же движок сейчас САМ
   ставит тег **DisableShadow (бит 3)** (`anim4.c:603`, `tags(0,&win,8,0)`), из-за чего `_CGXWindowIsShadowed` → false,
   и форма рисования схлопывается ровно до прямоугольника содержимого (`win+0xe8`). Поэтому наши кольцо/тень снаружи
   прямого края пропадают, а системная тень Tahoe (когда тег не стоял) рисовалась снаружи. [V]
   → **Рецепт: НЕ ставить DisableShadow. Оставить окно теневым, задать тени нулевую видимость (density/opacity 0), но
   большой sigma, чтобы `WSWindowShadowRadius ≥ N` (наш выступ ~64 pt). Тогда клип расширяется ровно на N «как под тень»,
   Apple-тень невидима, а наши подслои в полосе выступа больше не режутся.** Это и есть механизм «shadow outset», о
   котором спрашивали. [V живьём 14:20: без тега кольцо снаружи видно.]
   **Устойчивая невидимая тень (§1.7) [V листинг]:** клиентский `SLSSetWindowShadowParameters` не годится (проверка прав
   на окно); `density=0` везде — тоже нельзя (`resolve_shadow_properties` 18705a194 сам выключает бит «тень включена»
   `win+0x3dc` b0, если все плотности <0.001, и клип схлопнется). Рецепт: системный override
   `WSWindowSetWindowManagerShadowProperties(win,&act,&inact)` 18707173c с маской 0xfff и структурой
   {sigma=23, density=0.001, всё остальное 0} для active и inactive → WS сам пишет shadowOpacity 0.001 (невидимо) и
   borderWidth/alpha контура Tahoe = 0, AppKit перебить не может (override побеждает по маске), `frame_bounds` раздут на
   ceil(23·2.8)=65 pt. Инвалидация — `WSWindowInvalidateShadowFrame(conn,win)` 187071894 до и
   `CGXWindow::invalidate_shadow_and_schedule_update` 18706340c после (или один `finalize_shadow_property_change`
   18714de34). Откат — вернуть сохранённые 0x80 байт `win+0x2d8..0x357`. Текущий радиус Tahoe по умолчанию —
   `ceil(trunc(sigma)·2.8)+ceil((rimRadius−1)/scale)` (+offsetY вниз); sigma/rimRadius/offset прочитать живьём из
   `win+0x358/+0x364/+0x370`, статически CoreUI-значения недоступны.

2. **Проблема 2: у Apple есть ровно то, что надо — два готовых примитива, оба работают изнутри WS.**
   - **`window_list_set_locked_bounds` (186e50174)** — сервер сам растягивает текущий буфер в прямоугольник L и
     пересчитывает масштаб в момент коммита приложения, атомарно. Это буквально macOS-аналог `uvBR*=RATIO` Hyprland.
     Для анимации бокса: покадрово менять L; когда приложение закоммитит новый размер, масштаб в той же серверной
     операции станет корректным — кадра «не того масштаба» нет. [V]
   - **`WSWindowFreezeContent` (187073bf0) / `WindowFreeze::UpdateTextureScale` (186ffde04)** — заморозка: WS держит
     последний кадр приложения как текстуру и **растягивает её на текущий размер окна**, пока приложение не
     перерисовалось. Это нативное «держать старый кадр и тянуть в бокс». В конце — `WSWindowThawContent` + один
     кроссфейд. [V]
   - Кроссфейд клоном (`CreateCloneOfWindow` + `GetLastChangeDataForContext`) — запасной путь (compositor.md §2/§4).
   - Fence WM.app (`CAFenceHandle`/`NSSceneFenceAction`/`awaitResponseForResizeRequest`) — существует, но завязан на
     кооперацию приложения и BSService; для произвольных окон изнутри WS не пригоден [V существование, H применимость].

3. **Что делать В ПЕРВУЮ ОЧЕРЕДЬ.** Сначала (1): снять DisableShadow, включить «невидимую широкую тень» ради
   расширенного клипа — это убирает «половинки без скругления/без тени» и даёт полосу под дотяжку края БЕЗ подложек.
   Проверять одним статичным окном (маска Hosting уже есть в движке, HYPRWM10). Потом (2) в порядке риска:
   **locked_bounds** (минимальный риск, тот же путь трансформов, что уже используется) → если «телепорт» при приходе
   буфера остаётся на медленных приложениях (Word 350–500 мс), добавить **freeze** на время ожидания нового кадра и
   один кроссфейд при thaw. Клон — только если freeze не заведётся. Fence — не трогать.

4. Эталон пользователя (Hyprland look.lua): рамка снаружи содержимого градиент primary→tertiary 45°, border 2,
   rounding 18 power 2.6, тень range 34 offset (0,10), glow range 18. На resize Hyprland показывает старый буфер
   1:1 обрезанным и дотягивает край (`calculateUVForSurface`: при RATIO<1 `uvBR*=RATIO`). locked_bounds +
   расширенный клип + маска Hosting дают визуально то же (буфер 1:1, скругление, тень, дотяжка в полосе), без скачков.

---

## ЧАСТЬ 1. Где и чем WS режет отрисовку CA-слоёв окна

### 1.1 Форма, в которую рисуется CA-дерево окна [V]
`layergen_ca_backed_window(CGXRedrawState* rs=x19, CGXWindow* win=x20, CGSRegionObject*, uint)` 186e224e8 строит
`WSCompositeSourceLayer` (поля `+0x218`=flags, `+0x1a0`=draw-region, `+0x50..0x5c`=px-прямоугольник, `+0x130..0x170`
трансформ, `+0x2a0`=backing). Форма рисования слоя получается так:

- **Исходная форма** — `ca_backed_window_create_source_shape_direct(win)` 186e2204c [V 186e2204c–186e220c4]:
  ```
  if (_CGXWindowIsShadowed(win) && *(u8*)(0x1ea5f60c0) & 1 /* gWSCAWindowShadowsEnabled */) {
      rect = CGRegionGetBoundingBox(win->0x170);           // bbox окна (реальная форма A)
      fb   = win->frame_bounds();                          // bbox, РАЗДУТЫЙ под тень
      rect = CGRectOffset(fb, -bbox.x, -bbox.y);           // в локальных коорд.
      return CGRegionCreateWithRect(rect);                 // ← форма = frame_bounds
  } else {
      return CGRegionCreateWithRect(bbox(win->0xe8));      // ← форма = СОДЕРЖИМОЕ окна (прямоугольник A)
  }
  ```
- **Экранная форма** — `ca_backed_window_create_destination_shape` 186e237a8: `create_screen_region_with_window_region`
  (source shape × трансформ × mesh), затем смещение на `win+0xa0`. [V 186e237a8–186e23808]
- **Клип видимости**: destination ∩ `rs->0x58` (накопленная грязная/видимая область кадра) @186e227f0; потом ∩
  `win->0x110` (наш global clip) если он есть @186e229b4. [V]

**Итог [V]:** область, в которой QuartzCore рисует дерево окна (Server root→Shadow→Hosting→Window), ограничена
`frame_bounds`, когда окно теневое, и ровно прямоугольником содержимого `win+0xe8`, когда НЕ теневое. Наш global clip
`win+0x110` сужает дополнительно, но НЕ может расширить за пределы source shape.

### 1.2 `frame_bounds` — вот тот самый «shadow outset» [V 18705fe78]
`CGXWindow::frame_bounds() const` 18705fe78:
```
bbox = CGRegionGetBoundingBox(win->0x170);
if (!_CGXWindowIsShadowed(win)) return bbox;              // не теневое → ровно окно
r   = WSWindowShadowRadius(win);                          // 18714ebcc: sigma→radius (× const 0x1871ce000+0x3a4)
off = (int)props->0x18;                                   // WSWindowShadowCurrentPropertiesPtr+0x18 (offset)
extra = max(0, (props->0xc - 1)/scale_for_legacy_shadow_generation(win)); // 908958
box = CGRectInset(bbox, -r, -r);                          // раздуть на радиус тени во все стороны
box = CGRectInset(box, -extra, -extra);
box = CGRectOffset(box, 0, off);                          // сдвиг тени
return CGRectUnion(bbox, box);                            // окно ∪ раздутый бокс
```
То есть **ширина выхода за прямой край = `WSWindowShadowRadius` (производная от sigma) плюс offset тени.** Это именно
то поле/функция, которые задают «выход за край» — и WS использует их как для своей тени, так и как границу рисования
всего CA-дерева. (Та же формула продублирована в `clipped_frame_bounds_common` 18705fc80 и
`invalidate_shadow_frame` 18706327c — последняя пересчитывает теневую форму и зовёт `CGXInvalidateDisplayShape`.) [V]

### 1.3 Что такое `_CGXWindowIsShadowed` и почему наш тег всё ломает [V 186deac7c]
```
_CGXWindowIsShadowed(win):
    if (*(u8*)(0x1e6151000+0xbd8))->[0x1] bit6 → return 0;   // глобальный «теней нет»
    return WSWindowIsShadowEnabled(win)                       // win+0x3dc bit0
        && !WSWindowIsTagBitSet(win, 3);                      // ← тег DisableShadow инвертирует!
```
`anim4.c:603` ставит тег 3 (`tags(0,&win,8,0)` — set), намеренно гася системную тень/контур Tahoe. Побочный эффект
(не замеченный ранее): `IsShadowed`→false → `source_shape` = `win+0xe8` = прямоугольник содержимого → наши кольцо,
тень, glow и дотяжка края ЗА прямым краем срезаются. Это объясняет ВСЁ из PROGRESS 13:58: «снаружи прямого края
пусто, видно только в уголках между скруглением содержимого и прямоугольником» (уголки — там, где скруглённое
содержимое `0xe8` отступает внутрь прямоугольного bbox). [V — совпадает с замером пикселей]

### 1.4 РЕЦЕПТ для движка (проблема 1)
Цель: расширить клип на N pt (≈ `d->radius + d->width + SH_E` = 18+2+64 ≈ выбрать N так, чтобы покрыть кольцо+тень+
дотяжку), «ровно как WS для тени», без видимой системной тени.

Шаги (главный поток WS, в обычном тике движка; откат тривиален):
1. **Не ставить DisableShadow.** Убрать/загейтить `anim4.c:603` (ветка `d->sys_off`). Вместо гашения тега — гасить
   саму видимость тени (п.2). `set_window_list_tags(... bit3 ... clear)` при выключении движка. [изменение кода —
   предложение, не правка здесь]
2. **Включить «широкую невидимую тень»** на каждом тайловом окне:
   `SLSSetWindowShadowParameters(cid, wid, sigma, density=0.0, offX=0, offY=0)` 187020888, где sigma подобрать так,
   что `WSWindowShadowRadius(sigma) ≥ N`. По `WSWindowShadowRadius` 18714ebcc: `radius = sigma·k`, `k`=`*(float*)
   (0x1871ce000+0x3a4)` (значение — [H], замерить; обычно ≈0.9..1.0; клэмп sigma≤128). density=0 → Apple-тень не
   видна, но окно остаётся `IsShadowed` (бит 0x3dc не трогается этим вызовом — его трогает только
   `WSWindowSetShadowEnable` 18706e764). ⚠️ проверить, что `density=0` действительно не рисует Apple-тень, но
   `WSWindowHasActiveShadow`/`IsShadowed` остаются true — [H], тест ниже.
   - Изнутри WS предпочтительно звать серверный путь напрямую: `WSWindowSetShadowProperties(win, CFDictionary)`
     18714d398 (ключи `com.apple.WindowShadow*` из §1.6) или собрать активную тень `win+0x358` (active) /`+0x398`
     (inactive) и выставить. Но проще и безопаснее — публичный `SLSSetWindowShadowParameters` с нашим cid.
3. **Наши слои** (кольцо-градиент, тень с shadowPath, glow) и дотяжку края рисовать как раньше — но теперь они не
   режутся: `frame_bounds` расширил source shape на N. Наш `global clip` (`win+0x110`, `set_window_list_global_clip_
   shape`) по видимой рамке B НЕ ставить на теневое окно (он тоже урежет frame_bounds — см. compositor.md); клип по B
   делать маской Hosting (уже есть, `put_mask`), а не экранным клипом.
4. Откат: `SLSSetWindowShadowParameters(cid,wid,старая_sigma,старая_density,…)`; при stop движка — снять нашу маску и
   вернуть тег/тень в исходное.

**Риски:** (а) density=0 может всё же не держать `IsShadowed` (если WS считает «нет тени» по density) → тогда вместо
density=0 ставить крошечную (0.001) и чёрную с alpha≈0, либо включать тень и гасить слой Shadow.shadowOpacity через
пропуск бита 0xf (compositor.md §3). (б) при смене формы окна WS зовёт `invalidate_shadow_frame` → лишние инвалидации
дисплея (TM: дорого) — но это ровно та цена, что платит система за тень, терпимо. (в) большая sigma может включить у
WS собственную генерацию тени (эффективная/неэффективная CA-тень — `wants_efficient/inefficient_ca_shadow`
18706599c/187065a0c) — проверить, что density=0 выключает именно отрисовку.

### 1.5 Проверка (проблема 1), без правки логики движка
1. Статичное окно Finder, снять DisableShadow (если стоит), поставить `SLSSetWindowShadowParameters(cid,wid,80,0,0,0)`.
   Прочитать `_CGXWindowIsShadowed`? косвенно: наш слой-кольцо на расстоянии 40 pt снаружи прямого края — виден?
   Ожидание [V-основание]: виден (frame_bounds раздут на ~72 pt). До правки (с DisableShadow) — не виден.
2. Скрин: Apple-тень при density=0 не видна, наше кольцо снаружи видно, WS жив, `mask_errs`=0.
3. Сжать окно (сосед открылся): в полосе B−A (буфер < B) дотяжка края видна до края B, не обои. Это закрывает
   «половинку без скругления», обои в полосе, «жирнее углы».

### 1.6 Справочные адреса/поля (проблема 1) [V]
| что | адрес/поле | примечание |
|---|---|---|
| `layergen_ca_backed_window` | 186e224e8 | строит слой окна; source∩rs+0x58∩win+0x110 |
| `ca_backed_window_create_source_shape_direct` | 186e2204c | форма = frame_bounds если shadowed, иначе win+0xe8 |
| `ca_backed_window_create_destination_shape` | 186e237a8 | source→экран через трансформ+mesh |
| `CGXWindow::frame_bounds() const` | 18705fe78 | bbox ⊕ (shadowRadius+extra, offset) |
| `CGXWindow::clipped_frame_bounds_common` | 18705fc80 | та же формула + клип |
| `_CGXWindowIsShadowed` | 186deac7c | `ShadowEnabled(0x3dc b0) && !tag3`; глобал 0x1e6151000+0xbd8[1] b6 |
| `gWSCAWindowShadowsEnabled` | 0x1ea5f60c0 (bit0) | гейт расширения; читается в source_shape и `WSWindowShadowSupportsCAInnerRim` 18714e92c |
| `WSWindowShadowRadius` | 18714ebcc | sigma→radius, k=*(float*)(0x1871ce000+0x3a4), sigma≤128 |
| `WSWindowShadowCurrentPropertiesPtr` | 18714e890 | активная/неактивная тень (win+0x358 / +0x398); поля +0xc,+0x14,+0x18 |
| `SLSSetWindowShadowParameters(cid,wid,sigma,density,offX,offY)` | 187020888 | публичный путь |
| `WSWindowSetShadowProperties(win,CFDict)` | 18714d398 | серверный; ключи `com.apple.WindowShadow{RimRadius,InnerRimRadius,…}{,Active,Inactive}` |
| `WSWindowSetShadowEnable(win,b)` | 18706e764 | чистит/ставит win+0x3dc bit0 (это и есть IsShadowEnabled) |
| `invalidate_shadow_frame` | 18706327c | пересчёт теневой формы, `CGXInvalidateDisplayShape` |
| наш тег DisableShadow в движке | `anim4.c:603` | ← СНЯТЬ/не ставить |
| ingestion: Shadow-слой | `ca_window_prep_ingestion_phase` 186e23c1c, setShadow* @186e25edc.. | staged-поля cwc +0x190(radius)/+0x194(opacity)/+0x1a8(-offY)/+0x100(path) |

Примечание по `determine_filter_flags_for_surface_layer` 186e22464: при трансформированном окне (наш xform) WS ставит
флаг фильтрации 0x21 (линейная) — наша полоса-дотяжка из 1 px даст clamp-to-edge при линейной фильтрации [H].

### 1.7 Невидимая тень изнутри WS (устойчиво, без тика-«полиции» слоя Shadow)
Контекст живой проверки 14:20–14:25 [V]: без DisableShadow кольцо снаружи видно; промежуточный режим «каждый тик
обнулять `Shadow.shadowOpacity/borderWidth`» работает, но может вспыхивать на 1 кадр при смене активности (ingestion
переприменяет раньше нашего тика). Ниже — как сделать так, чтобы WS САМ рисовал тень невидимой, а `frame_bounds`
оставался раздутым.

#### 1.7.1 Модель данных тени в CGXWindow [V]
`WSShadowProperties` — 0x40 байт, значимые поля (по `WSShadowPropertiesAreEqual` 18714d2e4, `WSWindowSetShadowProperties`
18714d398, ingestion 186e24b04/186e25fd4..186e2616c, `frame_bounds` 18705fe78):

| смещ. | тип | смысл | куда уходит в CA-слой Shadow (`cwc+0x88`) / в геометрию |
|---|---|---|---|
| +0x00 | float | **sigma** («radius»; ключ AppKit `kCGWindowShadowRadius*`) | `setShadowRadius:` (staged `cwc+0x190`); **`frame_bounds` расширение = ceil(trunc(sigma)·2.8)** (`WSWindowShadowRadius` 18714ebcc, k=2.8 @0x1871ce3a4 [V по файлу]); клэмп ≤128 |
| +0x04 | float | **density** (`kCGWindowShadowDensity*`) | `setShadowOpacity:` (staged `+0x194`); клэмп ≤1.3; значение <0.001 → 0 |
| +0x08 | float | rim density | `setRimOpacity:` (staged `+0x198`, ×0.5 если flags b0) |
| +0x0c | float | rim radius (`com.apple.WindowShadowRimRadius*`, по умолчанию 2 или 3 если −1) | `setRimWidth:` = max(0,(r−1)/scale) (staged `+0x19c`); **в `frame_bounds` даёт `extra`** |
| +0x10 | float | inner rim density (`…InnerRimDensity*`) | **alpha контура Tahoe** → `cwc+0x184` → `setBorderColor:` (бит 0xe ingestion @186e24b90/186e26204) |
| +0x14 | float | inner rim radius (`…InnerRimRadius*`) | **`borderWidth` контура Tahoe** = max(0,(r−1)/scale) → `cwc+0xf8` → `setBorderWidth:` @186e24b94; значение <0.001 → 0 |
| +0x18 | float | offset Y | `setShadowOffset:(0,−off)` (staged `+0x1a8`); в `frame_bounds` — сдвиг раздутого бокса |
| +0x1c | u8 | flags: b0 rim white, b1 rim color const, b2 inner rim white (`…StyleWhite*`), b3/b4 content aware | цвета/режимы |
| +0x38 | u32 | **маска override** (только у системных структур): b0 sigma, b1 density, b2 rimDens, b3 innerDens, b4 rimRad, b5 innerRad, b6 offset, b7..b11 флаги | `WSWindowShadowResolveProperties` 18714e744 |

Экземпляры в `CGXWindow` [V `WSWindowSetAppKitShadowProperties` 1870715e4, `WSWindowSetWindowManagerShadowProperties`
18707173c, `resolve_shadow_properties` 18705a194]:
- AppKit: active `win+0x258`, inactive `win+0x298` (то, что шлёт приложение через `SLSTransactionSetWindowShadowProperties`);
- «системные/WindowManager» с маской override: active `win+0x2d8` (маска `win+0x310`), inactive `win+0x318` (маска `win+0x350`);
- **итоговые**: active `win+0x358`, inactive `win+0x398` — их читает `WSWindowShadowCurrentPropertiesPtr` 18714e890
  (по `win+0x3dc` bit1 = активная), их копирует ingestion в staged `cwc+0x190..0x1cf`, из них считается `frame_bounds`.
- `CGXWindow::resolve_shadow_properties()` 18705a194: итог = `ResolveProperties(system, appkit)` — **для каждого поля
  берётся системное значение, если его бит стоит в маске `+0x38`, иначе AppKit-овское** [V 18714e744–18714e838]. Затем
  **пересчитывает `win+0x3dc` bit0 («тень включена» = основа `_CGXWindowIsShadowed`)**:
  `enabled = (density ≥ 0.001 && sigma > 0) || rimDensity ≥ 0.001 || innerRimDensity ≥ 0.001` для active ИЛИ inactive
  [V 18705a2a8–18705a33c, порог 0.001 @0x1871cc118].
  ⚠️ Следствие: **полностью нулевые плотности выключают тень → `IsShadowed`=false → клип схлопывается.** Нужна
  минимальная ненулевая плотность.

#### 1.7.2 Что именно задать (значения)
Для active и inactive одинаково (чтобы смена активности ничего не меняла):
```
sigma           = S          // S = ceil(N/2.8), N — нужный выступ; N=64 → S=23 (ceil(trunc(23)·2.8)=65 pt); клэмп ≤128
density         = 0.001      // ровно порог: сохраняет «тень включена», shadowOpacity 0.001 → 0.26/255 → невидимо
rimDensity      = 0
rimRadius       = 0          // rimWidth = max(0,(0−1)/scale) = 0; extra в frame_bounds = 0
innerRimDensity = 0          // alpha контура Tahoe = 0
innerRimRadius  = 0          // borderWidth контура = 0  ← устойчивое обнуление бита 0xe
offsetY         = 0          // или наш 10, если хотим, чтобы frame_bounds удлинялся вниз как тень Hyprland
flags           = 0
```
Проверка формулой: `frame_bounds` = bbox ⊕ 65 pt во все стороны (+offsetY вниз) ≥ наше кольцо (2) + тень Hyprland
(range 34 + offset 10 = 44 снизу) + запас. Хочется ещё и дотяжку края на ширину полосы B−A — она ограничена 128·2.8≈358 pt;
дальше нужен путь A части 2 (locked bounds), при котором A≈B и полосы нет.

#### 1.7.3 Чем задать — три пути, рекомендация
(а) **Словарём через `WSWindowSetShadowProperties(conn, win, CFDictionary)` 18714d398** — путь AppKit (`+0x258/+0x298`).
Ключи: sigma/density — CFString-константы CoreGraphics `kCGWindowShadowRadius{,Active,Inactive}`,
`kCGWindowShadowDensity{,Active,Inactive}` (AppKit их импортирует: `nm extracted/appkit/AppKit`; в SkyLight они приходят
через общий GOT кэша 0x1e61525xx — брать `dlsym(RTLD_DEFAULT,"kCGWindowShadowDensityActive")` и т.п. [V имена, H что
GOT-слоты = именно эти]); rim/inner rim — CFString SkyLight `com.apple.WindowShadow{RimRadius,InnerRimDensity,
InnerRimRadius,RimStyleWhite,InnerRimStyleWhite,ContentAware}{,Active,Inactive}` (адреса в `__cfstring`: 0x1eecf6ab8/ad8/af8
RimRadius; bd8/bf8/c18 InnerRimDensity; b78/b98/bb8 InnerRimRadius; a58/a78/a98 RimStyleWhite; b18/b38/b58 InnerRimStyleWhite;
c38/c58 ContentAware — [V декодировано из файла]; из нашего образа без __DATA — создавать `CFStringCreateWithCString`
через dlsym). **Минус:** это AppKit-слой; системная маска override (`+0x310/+0x350`) может перебить поля, и приложение/AppKit
при смене активности (`-[NSWindow _setShadowActiveState]` 184af11e4 → `SLSTransactionSetWindowShadowProperties`) **перезапишет
наши значения** → вспышка вернётся. Не рекомендую как основной.

(б) **Прямая запись итоговых `win+0x358/+0x398`** — бесполезна: `resolve_shadow_properties` пересобирает их из
`+0x258/+0x2d8` при любом изменении (и тогда же пересчитает bit0). Не делать.

(в) **РЕКОМЕНДУЮ: системный override — `WSWindowSetWindowManagerShadowProperties(win, &active, &inactive)` 18707173c**
(это тот самый сеттер, которым WindowManager.app/`SetWindowSystemShadowProperties` задаёт тень «поверх» AppKit):
копирует 0x40 байт в `win+0x2d8` и `+0x318` (вместе с масками `+0x38` внутри структур), `win+0x3d8`++ и зовёт
`resolve_shadow_properties()` [V 187071768–1870717d0]. Маска = 0xFFF (все биты) → **все поля берутся из нашего
override, что бы AppKit ни прислал потом** — устойчиво к смене активности, к `_setShadowActiveState`, к пересылке
параметров приложением. Инвалидация — как в `finalize_shadow_property_change` 18714de34: `WSWindowInvalidateShadowFrame
(conn, win)` до записи и `CGXWindow::invalidate_shadow_and_schedule_update(win, conn)` 18706340c после (→
`CGXWindowPluginLayerInvalidate`, `WSDisplayManagerInvalidateGeometrySeed`, `invalidate_shadow_frame`,
`CGXScheduleUpdateAllDisplays`) [V]. Можно звать сам `finalize_shadow_property_change(win, conn, &act, &inact,
paciza(18707173c))` — он делает ровно это (аргумент-функция подписана IA/0, как `install4.py` уже умеет).
⚠️ Обход `WSWindowSetSystemShadowProperties` 18714e000 намеренный: тот путь регистрирует override за соединением
(`WSConnectionTrackOverrideImpl` @18714e694 + блок сброса 187063474, который чистит `win+0x7b8/+0x7c0` и
инвалидирует) — нам не нужен авто-сброс по смерти соединения, мы снимаем сами.

#### 1.7.4 Псевдокод для anim4.c (главный поток, вне composite; НЕ внутри CA-транзакции — это серверные структуры)
```c
struct ws_shadow { float sigma, density, rim_dens, rim_rad, inner_dens, inner_rad, off_y; u8 flags; u8 pad[0x1b]; u32 mask; u8 pad2[4]; }; // 0x40
// ctx: fn-указатели из install4.py (все sign IA/0): wm_shadow_set=18707173c, inval_frame=_WSWindowInvalidateShadowFrame 187071894,
//      inval_sched=CGXWindow::invalidate_shadow_and_schedule_update 18706340c
static void shadow_invisible(struct ctx *c, struct ch_win *w, void *win, int on) {
    if (on && !(w->rset & 4)) {                            // первый раз — сохранить оригинал системных структур
        memcpy(w->sh_save, (char*)win + 0x2d8, 0x80);      // active+inactive (0x2d8..0x357)
        w->rset |= 4;
    }
    struct ws_shadow s = {0};
    if (on) { s.sigma = c->ch->deco.ext_sigma /*23*/; s.density = 0.001f; s.mask = 0xfff; }
    c->inval_frame(0 /*conn*/, win);
    if (on) c->wm_shadow_set(win, &s, &s);                 // → +0x2d8/+0x318, resolve → +0x358/+0x398, bit0 остаётся 1
    else    c->wm_shadow_set(win, w->sh_save, w->sh_save + 0x40); // откат: вернуть сохранённые системные структуры (их маски тоже)
    c->inval_sched(win, 0);
}
```
Вызов: один раз при первой встрече окна (там же, где сейчас `tags(...,8,0)` — вместо него), повторно — только если
`*(float*)((char*)win+0x35c)` (density итоговой active) ≠ 0.001 или `*(float*)(win+0x358)` ≠ S (кто-то перезаписал —
практически невозможно при маске 0xfff, но дёшево проверять раз в тик без транзакции). Промежуточную «полицию» слоя
Shadow можно оставить как страховку — она станет холостой.
Откат при stop: `shadow_invisible(…, on=0)` для всех окон (восстанавливает исходные `+0x2d8/+0x318` с их масками; если
исходная маска была 0 — AppKit-значения снова побеждают, тень Tahoe возвращается).

Риски: (1) структура 0x40 байт — размер подтверждён копированием `ldp q0..q3` в сеттере [V]; смещение маски +0x38 — по
`WSWindowSetSystemShadowProperties` (sp+0x38/+0x78) [V]; (2) если WindowManager.app (Stage Manager) сам держит override
на окне — мы его затираем и при откате возвращаем сохранённое (оно же его); (3) `resolve` пересчитает `0x3dc` bit0 —
при density=0.001 и sigma>0 он остаётся 1 [V формула]; если на практике CA округлит 0.001 в видимый пиксель — снизить
нельзя (порог), тогда взять `rimDensity=0.001` + `density=0` (rim с `rimRadius=0` → ширина 0 → ничего не рисуется, а
бит0 держится по `rimDensity ≥ 0.001`) — это запасной вариант [H]; (4) `frame_bounds` → больше площадь инвалидации на
каждое движение окна (цена как у системной тени радиуса 65).

#### 1.7.5 Какой радиус расширения у окна Tahoe сейчас (по умолчанию)
Формула [V]: `ext_side = ceil(trunc(sigma)·2.8) + ceil(max(0,(rimRadius−1)/scale))`, `ext_bottom = ext_side + offsetY`
(union с bbox, сдвиг только по Y). Значения sigma/rimRadius/offset по умолчанию задаёт AppKit из CoreUI
(`__NSWindowConstructShadowParameters` 184af0a2c → `_NSWindowFetchCoreUIShadowMeasurements`) — статически из бинарников
не извлекаются (данные CoreUI). **Снять живьём (чтение, безопасно):** в движке залогировать для окна
`sigma=*(float*)(win+0x358)`, `rimRadius=*(float*)(win+0x364)`, `offY=*(float*)(win+0x370)`, и те же для inactive
(+0x398/+0x3a4/+0x3b0); расширение по формуле выше. Ориентир [H]: для стандартного активного окна macOS sigma порядка
15–25 → 42–70 pt по бокам, снизу + offset; наша тень Hyprland (34+10=44 снизу, 34 по бокам) при sigma<13 (≤36 pt) будет
подрезана по бокам/сверху, при sigma<16 — снизу. С §1.7.2 (S=23 → 65 pt) подрезки нет.

---

## ЧАСТЬ 2. Незаметная смена буфера при изменении размера (анти-«телепорт»)

Эталон Hyprland [V /tmp/hyprland-src]: окно во время resize рисуется из СТАРОГО буфера, обрезанного/растянутого UV, и
край дотягивается (`calculateUVForSurface` `src/render/ElementRenderer.cpp:61`: `RATIO = projSize/EXPECTED`, при
RATIO<1 `uvBR *= RATIO` — буфер 1:1 от левого-верхнего, лишнее отрезано; при RATIO>1 и `expand_undersized_textures` —
`uvBR *= FIX` растягивает край). Новый буфер приходит — просто меняется текстура, формы те же → без скачка.
anim_feel §2 L1/L6 подтверждают: контент 1:1 обрезан, не сжат. Цель на macOS — повторить это тремя путями ниже.

### 2.1 Путь A — locked bounds: сервер сам тянет буфер в рамку (РЕКОМЕНДУЮ первым) [V]
`window_list_set_locked_bounds(CGXConnection* conn=x0, const u32* wids=x1, u32 n=x2, const CGRect* rects=x3,
u32 nrects=x4(==n), u32 place=x5)` 186e50174 → блок `_block_invoke` 186e502b8 [V 186e50174–186e50450]:
- На каждое окно: `WSWindowGetTransformStack(win)` 18707077c (= `win+0x798`); слот по смещению **+0x10** (обычный) или
  **+0x18** (если `conn->0x2f0` bit4) @186e50308. Запись `malloc(0x30)` {`u32 connID`@0, `CGRect L`@+8, `u32 place`@
  +0x28} @186e5034c. `CGRectIsNull(L)` → `free` слот (снять). [V]
- `place==0` → сброс системных слотов `window_set_transform(conn, win, 0x1ffffffe, 0, I)` и `0x1ffffffd`
  @186e503c4–186e503f4, затем `window_update_transform`. [V]
- В `window_update_transform` 186e4e574 (стек `win+0x798`): если есть locked bounds @186e4e640:
  `scale = bbox(win+0x170).size / L.size`, `translate = -L.origin·scale` → `CATransform3DMakeAffineTransform`, и этот
  трансформ вставляется в стек на позиции `place` через `concatenate_all_transforms` 186e4ec20. [V]
- Пересчитывается в `set_shape_internal`→`window_update_transform` при каждой смене формы (windowctl.md §п.2). Значит
  когда приложение закоммитит новый размер (`PKGTransactionSetWindowShape`→`shape_window`), масштаб L/новый_размер
  пересчитается в ТОЙ ЖЕ серверной операции → кадра «буфер не того масштаба» нет. [V]

**Смысл аргументов:** `place` — это id слота в стеке трансформов (позиция наложения), НЕ флаг; `0x1ffffffe`/`0x1ffffffd`
— системные слоты WM.app. Для нас — выбрать свой `place` (например, как наш ключ трансформа, но отдельный слот, чтобы
не конфликтовать с `CGXSetWindowTransform3DList`). `conn` можно 0 (как у нашего xform-пути): проверка `window_by_id`
при conn==0 использует x24 (global owner) @186e5020c. [H — что conn=0 проходит проверку доступа; серверный враппер
`PKGTransactionSetWindowLockedBounds` 1870c915c делает `_PKGTransactionCheckWindowAccess(conn,wid,4,0x19,0)`, но
прямой вызов `window_list_set_locked_bounds` эту проверку минует].

**Рецепт (anim4.c/hyprwm.py):**
1. Добавить указатель `locked_bounds_fn` в install4.py (символ 186e50174, подпись `(conn, u32* wids, u32 n,
   CGRect* rects, u32 nrects, u32 place)`), sign(IA,0).
2. На КАЖДОМ кадре анимации бокса вместо (или вместе с) нашего `CGXSetWindowTransform3DList` звать
   `locked_bounds_fn(0, &wid, 1, &L, 1, PLACE)` где `L` = текущий анимированный видимый бокс B, `PLACE` = наш слот.
   Сервер растянет текущий буфер в L.
3. Приложению параллельно слать целевой размер (AX), один раз, сразу (как Hyprland). Когда придёт новый буфер —
   масштаб сам станет 1 в кадре коммита.
4. По окончании: `L = CGRectNull` → `locked_bounds_fn(0,&wid,1,&null,1,PLACE)` снимает слот.
5. Сочетание с нашим трансформом: locked bounds — отдельный слот стека; позиционирование (сдвиг плитки) можно оставить
   на `CGXSetWindowTransform3DList`, а масштаб-растяжение буфера — на locked bounds. Проверить, что они не дерутся за
   один слот (разные `place`/`key`). [H]

**Что видит пользователь:** старый буфер гладко тянется в анимируемый бокс (как Hyprland uvBR*=RATIO), новый буфер
встаёт без скачка масштаба. Это прямое решение «сжимающейся стороны» без «сосед прыгает» и без «телепорта в конце».

**Риски:** конфликт со Stage Manager/системным тайлингом (они держат свои locked-bounds-слоты 0x1ffffffe/d —
тестировать при выключенном Stage Manager); при неверном `place` можно перезатереть системный слот → дёрганье. Снимать
обязательно (CGRectNull), иначе окно останется растянутым. Падения WS не ожидаю (путь тот же, что у WM.app). Проверка:
rec 120 к/с, resize Ghostty/Word — 0 кадров неверного масштаба; `CGWindowListCopyWindowInfo` отдаёт L во время хода.

### 2.2 Путь B — freeze: держать старый кадр и тянуть его в бокс, потом thaw+кроссфейд [V]
Нативный механизм «заморозки контента» (Mission Control/Exposé используют его):
- **Вход:** `WSWindowFreezeContent(win)` 187073bf0 [V]:
  - `WSWindowFreezeSizeIsValid` 187064918 (размер ≤ `WSCompositorMaxWidth/Height`);
  - `deschedule_callback(frozen_backing_cleanup_callback 187064980, win)`;
  - `win->0x928 &= ~0x80000000` затем (ниже) ставит бит 31; создаёт `WindowFreeze` (0x40 байт) → `win+0x488`,
    `new`@187073d1c, init {win@0, flags, scale@+0x34=1.0}, `WindowFreeze::Update(CGSize)` 186ffd6d4. [V 187073d08–d44]
  - перед вызовом (образец debug-пути 186f97a88): `win->0x928 &= ~0x100000000` (бит 32), `win->0x490 = 1.0f`,
    если `win->0x488==0` → `WSWindowFreezeContent`. [V]
- **`WindowFreeze::Update(CGSize)` 186ffd6d4:** захватывает `CGXCopyScreenContentShapeForWindow(win,1)`, берёт у
  `WS::Displays::CAManager` текстуру дисплея/контента, сохраняет как frozen backing. [V]
- **`WindowFreeze::UpdateTextureScale()` 186ffde04:** `scale = frozen_content_size / current_screen_content_size`
  (точнее `v1[frozen]/v0[current]`, @186ffdeb8 `fdiv`), пишет `this+0x34` (2×float scale). То есть замороженная
  текстура РАСТЯГИВАЕТСЯ на текущий размер окна. [V] ← вот «дотяжка/растяжение старого кадра» бесплатно.
- **Отрисовка:** `generate_layers_for_window` 186e19454 @186e19d28 зовёт `layergen_frozen_window` 186e1ee0c, когда
  `win->0x928` бит31 (frozen) и `win->0x488` (есть backing) и окно непустое `win->0x93 b0` [V 186e19c4c–186e19d28].
- **Выход:** `WSWindowThawContent(win)` 187073d98: если бит31 стоит и условие `(0x928 & 0x200100000000)==0x100000000`
  либо backing есть → удаляет `WindowFreeze`, чистит бит31. [V]

**Рецепт:** в начале анимации resize `WSWindowFreezeContent(win)` (поставить `win+0x490=1.0`, снять `0x928` бит32,
если `win+0x488==0` — заморозить). Пока заморожено — анимировать бокс нашим трансформом; WS сам растянет замороженную
текстуру (`UpdateTextureScale` вызовется при смене геометрии). Когда по `GetLastChangeDataForContext(ctx,&t,&seed)`
186de75e4 (ctx = `ca_client_context_id` 187060758) приложение сделало ≥1 новый коммит после смены рамки и «затихло» —
`WSWindowThawContent(win)` в один кадр, можно с коротким кроссфейдом (наш слой-копия → thaw, 80–120 мс smooth).

**Что видит пользователь:** вместо «обоев/серого» в полосе и «телепорта» — старый кадр плавно тянется в новый бокс,
в конце один мягкий переход на свежий буфер. Это и есть устранение «превращения».

**Риски:** freeze — системный примитив (им пользуется Mission Control); одновременная системная заморозка (Exposé)
может конфликтовать. Растянутая текстура на сильном изменении размера будет мыльной (как и ожидается от «старого
кадра»). Нельзя оставить замороженным (thaw обязателен, иначе окно «застынет»). `frozen_backing_cleanup_callback` сам
чистит по таймеру — подстраховка. Падения: freeze/thaw — штатный путь, низкий риск при парности. Проверка: заморозить
TextEdit, менять размер окна трансформом — видно растяжение старого кадра; thaw — свежий кадр; WS жив; счётчик окон не
растёт.

### 2.3 Путь C — кроссфейд клоном (запасной) [V, см. compositor.md §2/§4]
`CreateCloneOfWindow(win, A, PKGDisplay*, server_owned=true)` 18709e984 — готовый клон со статичным содержимым;
снять в момент отправки нового размера, держать в B (маска/растяжение), по `GetLastChangeDataForContext` дождаться
нового буфера приложения, затем за 80–120 мс растворить клон (`CGXSetWindowListAlpha`) и убрать
(`release_window(NULL, clone)`). Применять, только если freeze не подходит (клон — отдельное серверное окно, тяжелее).

### 2.4 Путь D — fence WindowManager.app: НЕ пригоден для нас [V существование, H применимость]
WM.app делает бесшовный resize так: шлёт приложению запрос размера (`performClientResizeWindowRequest`,
`awaitResponseForResizeRequest`, строки в `extracted/wmapp/WindowManager`), получает `CAFenceHandle`
(`ClientFenceGroup`/`LayoutDeferredFenceTracker`), и «entangle»-ит его в свою транзакцию
(AppKit: `NSSceneFenceAction` 185822388, `_NSCGSTransactionEntangleFenceHandle` 185910b18,
`NSCGSTransactionWaitOnCAFence`, `+[NSCGSWindow entanglingFenceHandle]`), так что коммит раскладки ЖДЁТ коммита нового
размера приложением — атомарно, без промежуточного кадра. [V по символам]
Почему не нам: (а) нужен ответ приложения через BSService (`_WMClientResizeWindowRequest`), которого у нас нет для
произвольных окон (resize_re.md: только AX); (б) fence-ручка создаётся в процессе приложения (`NSSceneFenceAction
applyToWindow:`), мы в WS её не породим для чужого окна без кооперации. Записать как «так делает Apple», но наш путь —
locked_bounds (сервер сам пересчитывает в кадре коммита — функционально тот же бесшовный результат без fence). [H]

### 2.5 Справочные адреса (проблема 2) [V]
| что | адрес | назначение |
|---|---|---|
| `window_list_set_locked_bounds` | 186e50174 | растянуть буфер в L, пересчёт масштаба при коммите |
| `_block_invoke` | 186e502b8 | запись слота стека {connID,L,place} +0x10/+0x18 |
| `window_update_transform` | 186e4e574 | @186e4e640 scale=bbox/L.size, translate=-L.origin·scale |
| `WSWindowGetTransformStack` | 18707077c | `win+0x798` |
| `PKGTransactionSetWindowLockedBounds` | 1870c915c | серверный враппер (access-check 4,0x19) |
| `WSWindowFreezeContent` | 187073bf0 | заморозить контент → win+0x488, бит31 win+0x928 |
| `WindowFreeze::Update(CGSize)` | 186ffd6d4 | захват текущего кадра в frozen backing |
| `WindowFreeze::UpdateTextureScale` | 186ffde04 | scale = frozen/current → растяжение старого кадра |
| `WSWindowThawContent` | 187073d98 | снять заморозку |
| `WSWindowIsFrozen` | 18706e088 | win+0x928 bit31 |
| `WSWindowFreezeSizeIsValid` | 187064918 | ≤ WSCompositorMaxWidth/Height |
| `layergen_frozen_window` | 186e1ee0c | рисует замороженную текстуру (вызов @186e19d28) |
| `frozen_backing_cleanup_callback` | 187064980 | авто-очистка по таймеру |
| `GetLastChangeDataForContext(ctx,&t,&seed)` | 186de75e4 | «приложение закоммитило новый кадр» (tracking_map) |
| `CGXWindow::ca_client_context_id` | 187060758 | ctx приложения (cwc+0x50) |
| `CreateCloneOfWindow` | 18709e984 | клон окна (запасной путь) |
| fence (WM.app/AppKit) | `NSSceneFenceAction` 185822388, `NSCGSTransactionEntangleFenceHandle` 185910b18 | не для нас |

---

## Что осталось [H] — проверить живьём (пользователь)
1. `SLSSetWindowShadowParameters(…,density=0,sigma большой)` держит ли `_CGXWindowIsShadowed`==true (клип расширен),
   при этом Apple-тень невидима. Если нет — крошечная density + прозрачный цвет, либо гасить `Shadow.shadowOpacity`
   через ingestion-бит 0xf.
2. Константа `k` в `WSWindowShadowRadius` (0x1871ce000+0x3a4) — чтобы подобрать sigma под нужный N.
3. `window_list_set_locked_bounds(conn=0,…)` проходит ли доступ; смысл/безопасный выбор `place`; совместимость с нашим
   `CGXSetWindowTransform3DList` (разные слоты).
4. `WSWindowFreezeContent` изнутри WS на чужое окно: парность freeze/thaw, нет ли конфликта с системной заморозкой;
   мыльность на больших изменениях размера приемлема ли пользователю.
5. Порог «буфер нового размера пришёл» по `GetLastChangeDataForContext` (кол-во коммитов/таймаут) для Ghostty ~150 мс,
   Word 350–500 мс.
