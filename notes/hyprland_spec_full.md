# Hyprland пользователя → наш WM на macOS: полная техническая спецификация

Дата: 2026-10-08. Автор: исследование по исходникам + живой Arch (только чтение).

## 0. Источники, версии, как проверено

- **Живая машина** `fsociety@192.168.1.74` (только чтение: `hyprctl version`, `hyprctl -j animations`,
  `hyprctl getoption …`, `hyprctl -j monitors/layers`, `cat ~/.config/hypr/colors.lua`):
  **Hyprland 0.56.2, commit `efb50993780079460b0cbed1363e2166a2de1d9f`**, hyprutils 0.14.2,
  hyprgraphics 0.5.1, aquamarine 0.15.1.
- **Исходники ровно этих версий** (клон в `/tmp/hsrc`, временно):
  - `https://github.com/hyprwm/Hyprland/tree/v0.56.2` (тот же commit efb5099 — проверено `git log`)
  - `https://github.com/hyprwm/hyprutils/tree/v0.14.2`
  Ниже пути вида `Hyprland:src/...` и `hyprutils:src/...` — относительно корня этих тегов.
- Дотфайлы: `/Users/fsociety/arch-nebula/dotfiles/home/.config/hypr/` (`hyprland.lua`, `nebula/*.lua`),
  kitty/waybar там же. Числа в §1 взяты из **живых `getoption`** (эффективные значения), не только из Lua.
- Численные свойства кривых (перелёт, время успокоения, покадровые значения) посчитаны
  скриптами, которые 1:1 повторяют код hyprutils (`/tmp/hsim.py`, `/tmp/bsim.py`, `/tmp/dk.py`).
- Всё, что помечено **«не подтверждено»**, в исходниках/живьём не проверено — это гипотеза или RE-задача.

---

## 1. Конфиг пользователя: всё, что влияет на вид и движение окон

### 1.1 Палитра (ВАЖНО: на маке сейчас берётся не та)
`hyprland.lua` делает `require("colors")` → `~/.config/hypr/colors.lua` генерирует **matugen из обоев**.
На Arch сейчас (обои `lunar-tears.png`):

| ключ | hex |
|---|---|
| primary | `bfcc9c` |
| tertiary | `e1bbdb` |
| outline_variant | `46483e` |
| surface_dim | `131410` |
| shadow | `000000` |

**В локальной копии дотфайлов `colors.lua` нет** → `hook/config/hypr_shim.lua` работает на запасной палитре
(`ffb4a4`/`7fd0f5`/`534341`, это видно в `hook/config/hypr_cfg.json`). Для 1:1 нужно либо копировать
`colors.lua` с Arch, либо запускать matugen на маковских обоях (шаблоны `.config/matugen`).

### 1.2 general / decoration (эффективные значения `hyprctl getoption`)
| опция | значение | смысл |
|---|---|---|
| general:gaps_in | 5 (все стороны) | отступ внутрь у каждой стороны плитки, не касающейся края рабочей области → между окнами 10 |
| general:gaps_out | top 8, right 12, bottom 12, left 12 | отступ рабочей области от края монитора (после резерва панелей) |
| general:gaps_workspaces | 40 | **не используется** стилем slidefade (только чистым slide) — см. §4 |
| general:border_size | 2 | рамка снаружи контента окна (внутри плитки) |
| general:col.active_border | `eebfcc9c eee1bbdb 45deg` | градиент primary→tertiary, альфа 0xee=0.933, угол 45° |
| general:col.inactive_border | `5546483e 0deg` | outline_variant, альфа 0x55=0.333 |
| general:resize_on_border / extend_border_grab_area / hover_icon_on_border | true / 18 / true | ресайз мышью за край, зона захвата 18 px наружу |
| general:snap | enabled, window_gap 12, monitor_gap 16 | прилипание плавающих окон |
| general:layout | dwindle | |
| decoration:rounding / rounding_power | 18 / 2.6 | суперэллипс, §5.2 |
| decoration:active_opacity / inactive_opacity | 1.0 / 1.0 | → fadeSwitch визуально ничего не делает |
| decoration:dim_inactive | false (по умолчанию) | → fadeDim визуально ничего не делает |
| decoration:dim_special | 0.0 | |
| decoration:dim_around | 0.4 (умолч.) | для правила `dim_around` (polkit) |
| decoration:border_part_of_window | true (умолч.) | |
| decoration:blur | enabled, size 5, passes 2, noise 0.008, contrast 1.0, brightness 0.92, vibrancy 0.22, vibrancy_darkness 0.4, popups true, popups_ignorealpha 0.2, special true, new_optimizations true, xray false, ignore_opacity true (умолч.) | §5.5 |
| decoration:shadow | enabled, range 34, render_power 3, offset (0,10), color `#000000` a=0x77 (0.467), color_inactive a=0x44 (0.267), sharp false, scale 1.0 | §5.3 |
| decoration:glow | enabled, range 18, render_power 3, color primary a=0x33 (0.2), color_inactive primary a=0x00 | §5.4 (это **внутреннее** свечение) |
| decoration:motion_blur:enabled | false | |
| render:expand_undersized_textures | true (умолч.) | важно для содержимого при resize, §3.3 |

### 1.3 dwindle / misc / input / binds
- dwindle: `preserve_split=true`, `force_split=0`, `smart_split=false`, `default_split_ratio=1.0`,
  `precise_mouse_move=true`, `split_width_multiplier=1.0`; умолчания: `use_active_for_splits=true`,
  `smart_resizing=true`, `split_bias=0`, `permanent_direction_override=false`, `special_scale_factor=1`.
- misc: `focus_on_activate=true`, `on_focus_under_fullscreen=2` (новое окно снимает fullscreen/maximize),
  `enable_swallow=true` (`^(kitty)$`, исключения `wev|yazi`), `animate_manual_resizes=true`,
  `animate_mouse_windowdragging=false`, `background_color=rgb(surface_dim)`, `vrr=2`.
- input: `follow_mouse=1` (фокус за мышью), `float_switch_override_focus=0`.
- cursor: `no_warps=true` (курсор никогда не прыгает сам — фокус стрелками не двигает мышь).
- binds: `workspace_back_and_forth=true`, `allow_workspace_cycles=true`.
- animations: `workspace_wraparound=false` (умолч.).
- scrolling-секция есть, но layout = dwindle → не действует.

### 1.4 Кривые (`hyprctl -j animations`, вторая часть)
| имя | тип | параметры | свойства (посчитано по коду hyprutils) |
|---|---|---|---|
| smooth | bezier | (0.25,1.0) (0.5,1.0) | ease-out, y(0.1)=0.347, y(0.3)=0.763, y(0.5)=0.934 |
| snappy | bezier | (0.2,0.9) (0.1,1.0) | быстрее: y(0.1)=0.475, y(0.3)=0.896 |
| overshot | bezier | (0.05,0.9) (0.1,1.06) | перелёт max y=1.0112 около x≈0.7 |
| linear | bezier | (0,0) (1,1) | |
| default | bezier | (0,0.75) (0.15,1.0) | встроенная, у borderangle/shadowangle/glowangle |
| drift | spring | m=1, k=210, d=24 | ω0=14.49, γ=12, ζ=0.828; перелёт **0.97%** (пик 1.0097 в 0.387 с); 99% в 0.291 с; финиш **0.739 с ≈ 45 кадров @60 Гц** |
| bounce | spring | m=1, k=260, d=20 | ω0=16.12, γ=10, ζ=0.620; перелёт **8.34%** (пик 1.0834 в 0.249 с); 99% в 0.174 с; финиш **0.739 с ≈ 45 кадров** |

Покадрово @60 Гц (значение кривой 0→1):
- drift: `0.026 0.089 0.176 0.273 0.373 0.470 0.560 0.642 0.714 0.776 0.828 0.871 0.906 0.934 0.956 0.973 0.986 0.995 1.001 1.005 1.008 1.009 1.010 1.009 …`
- bounce: `0.032 0.114 0.227 0.355 0.487 0.612 0.725 0.823 0.905 0.968 1.016 1.049 1.070 1.081 1.083 1.080 1.073 1.063 1.053 1.042 1.031 1.022 1.014 1.007 1.002 0.998 0.996 …`

### 1.5 Анимации — ЭФФЕКТИВНЫЕ значения по всем листьям
Наследование: не переопределённый лист берёт ВСЕ значения у ближайшего переопределённого предка (§2.1).
Длительность bezier = `speed × 100 мс`. **У spring `speed` игнорируется** (§2.3).

| лист | что анимирует (Hyprland) | кривая | speed | эфф. длит. | стиль | кадров @60 |
|---|---|---|---|---|---|---|
| global | корень | smooth | 8 | 800 мс | | 48 |
| windowsIn | m_realPosition+m_realSize при открытии | spring bounce | 4.5 (игнор.) | ~0.74 с | popin 86% | 45 |
| windowsOut | позиция/размер снимка при закрытии | snappy | 2.6 | 260 мс | popin 92% | 16 |
| windowsMove | позиция/размер при раскладке/переносе | spring drift | 5 (игнор.) | ~0.74 с | | 45 |
| windows | (не задан) → global | | | | | |
| border | кроссфейд цвета рамки | smooth | 6 | 600 мс | | 36 |
| borderangle | вращение градиента | default | 1 | — | **выключен** | |
| shadowangle / glowangle | вращение градиента тени/glow | default | 1 | — | **выключены** | |
| fadeIn | альфа открытия; alpha FULLSCREEN; alpha MOVE_FROM_WORKSPACE | smooth | 3 | 300 мс | | 18 |
| fadeOut | альфа закрытия; alpha MOVE_TO_WORKSPACE | smooth | 2.4 | 240 мс | | 15 |
| fadeSwitch | alpha ACTIVE (active/inactive opacity) и alpha LAYOUT | smooth | 4 | 400 мс | | 24 |
| fadeDim | dim неактивных | smooth | 4 | 400 мс | | 24 |
| fade, fadeShadow, fadeGlow, fadePopups(In/Out), fadeDpms | не заданы → **global: smooth 800 мс** | smooth | 8 | 800 мс | | 48 |
| layersIn | позиция/размер слоя при появлении | overshot | 3.4 | 340 мс | popin 94% | 21 |
| layersOut | слой при исчезновении | snappy | 2.2 | 220 мс | fade | 14 |
| fadeLayersIn / fadeLayersOut | альфа слоёв | smooth | 2.6 / 2.2 | 260 / 220 мс | | 16 / 14 |
| workspaces (+workspacesIn/Out) | m_renderOffset и m_alpha стола | spring drift | 4.2 (игнор.) | ~0.74 с | slidefade 12% | 45 |
| specialWorkspace (+In/Out) | то же для спец-стола + m_specialBlur/Dim | overshot | 4 | 400 мс | slidefadevert 14% | 24 |
| zoomFactor | зум курсора | smooth | 6 | 600 мс | | |
| monitorAdded | → global | | | | | |

Покадрово @60 Гц (bezier, с ms-квантованием как в коде):
- windowsOut snappy 260 мс: `0.292 0.587 0.768 0.856 0.909 0.941 0.960 0.974 0.983 0.989 0.994 0.997 0.998 0.999 1 1`
- fadeIn smooth 300 мс: `0.198 0.376 0.523 0.635 0.731 0.805 0.859 0.902 0.934 0.956 0.973 0.984 0.991 0.996 0.998 1 …`
- fadeOut smooth 240 мс: `0.243 0.451 0.613 0.728 0.819 0.883 0.926 0.956 0.976 0.988 0.995 0.998 1 …`
- specialWorkspace overshot 400 мс: `0.478 0.676 0.779 0.841 0.886 0.919 0.942 0.960 0.975 0.985 0.993 0.999 1.004 1.007 1.009 1.011 1.011 1.011 1.010 1.009 1.007 1.005 1.003 1.000`
- border smooth 600 мс: `0.103 0.204 0.297 0.376 0.453 0.523 0.582 0.638 0.689 0.731 0.770 …` (36 кадров)

### 1.6 Правила окон и слоёв (`nebula/rules.lua`)
- `suppress_event=maximize` для всех: приложения не могут сами себя развернуть.
- polkit: float, center, pin, `dim_around` → под окном чёрный прямоугольник на весь монитор с a=0.4×fullAlpha окна.
- диалоги (Open/Save/…): float, center, size 1100×720. modal: float, center.
- dropterm (`class ^dropterm$`): float, size 1600×800, move (480,60), workspace `special:dropterm`.
- Telegram Media viewer: fullscreen. PiP: float, pin, keep_aspect, 640×360 в правом нижнем углу (отступ 16), no_shadow.
- игры: no_blur, no_shadow, immediate. steam Friends/Settings: float.
- слои: waybar blur ignore_alpha 0.2; rofi blur ignore_alpha 0.3 dim_around **popin 92%**; swaync cc/notif blur **slide right**;
  nebula-radio blur **fade**; swayosd blur **popin 90%**; selection/hyprpicker/mpvpaper/wallpaper no_anim.
- waybar: `layer top, height 44, margin-top 10, exclusive` → живой `reserved` DP-1 = `[0,64,0,0]` (сверху 64).

### 1.7 Бинды, касающиеся окон (`nebula/binds.lua`; M = SUPER = клавиша Option на маке, ALT = Command)
| бинд | действие Hyprland | точная семантика — §7 |
|---|---|---|
| Ctrl+M+стрелки | `focus{direction}` | §7.6 |
| Ctrl+M+Shift+стрелки | `window.move{direction}` (не swap!) | §7.4 |
| Ctrl+M+Alt+стрелки / Ctrl+M+Esc | `layout("preselect l/r/u/d")` / `preselect none` | §7.3 |
| M+Shift+→/←/↑/↓ (repeat) | `window.resize{±60,0 / 0,±60, relative}` | §7.5, анимируется (animate_manual_resizes) |
| Ctrl+M+Return | `togglesplit` | §7.7 |
| M+Shift+B | Lua `balance()`: фокус по очереди на каждое тайловое окно + `splitratio 1 exact`, потом фокус назад | §7.7 |
| M+Shift+Return | `fullscreen{mode=maximized}` | §3.6 |
| M+F | `fullscreen{mode=fullscreen}` | §3.6 |
| Ctrl+M+F | float toggle | |
| M+Q / M+Shift+Q | close / закрыть все окна того же pid | §3.2 |
| M+W, Alt+H, Alt+M / M+Shift+W, Alt+Shift+H | Lua hide → `special:hidden` (silent) / вернуть последнее на текущий стол с follow | §3.5 |
| M+grave | Lua scratch: запустить `kitty --class dropterm` если нет, затем `toggle_special(dropterm)` | §4.2 |
| M+1..0, Ctrl+M+1..0 | стол i / окно на стол i (follow) | §4 |
| M+PgUp/PgDn, M+колесо | Lua `ws_step`: по кругу 1..5 (на DP-2 6..8) | §4.1 |
| M+Tab | `focus{workspace="previous"}` | |
| M+LMB / M+RMB | drag / resize мышью | без анимации (§3.3) |
| Alt+Tab / Alt+Shift+Tab | `window.cycle_next` | |

### 1.8 События `hl.on` и Lua-логика, влияющая на окна
- `window.active`: если активным стало окно на `special:hidden` или `special:vpn` — закрыть этот спец-стол,
  если открыт, и перенести окно на текущий стол с follow (скрытые окна никогда не «всплывают» спец-столом).
- `window.open`/`window.active`/`window.move_to_workspace`: помнит стол окна; если окно уехало на другой
  монитор не через M+Shift+Tab — возвращает на прежний стол (на маке с одним дисплеем — не актуально).
- `monitor.removed/added` — перенос столов 6–8 (на маке не актуально).
- `hyprland.start` — автозапуск; таймер 30 с — перезапуск waybar/osd/hypridle.

### 1.9 Прочее, влияющее на вид
- kitty: `background_opacity 0.80`, `window_padding_width 14 18`, `hide_window_decorations yes` → блюр под терминалом
  виден сквозь 80% фон.
- Обои — `mpvpaper` (видео) на фоновом слое: кэш блюра обновляется при каждом кадре видео.

---

## 2. Ядро анимаций (hyprutils + Hyprland)

### 2.1 Дерево конфигов и наследование
`Hyprland:src/config/shared/animation/AnimationTree.cpp: CAnimationTreeController::reset()` — дерево:
```
global ─ windows ─ windowsIn, windowsOut, windowsMove
       ─ layers ─ layersIn, layersOut
       ─ fade ─ fadeIn, fadeOut, fadeSwitch, fadeShadow, fadeGlow, fadeDim, fadeDpms,
               fadeLayers ─ fadeLayersIn/Out, fadePopups ─ fadePopupsIn/Out
       ─ border, borderangle, shadowangle, glowangle, zoomFactor, monitorAdded
       ─ workspaces ─ workspacesIn, workspacesOut, specialWorkspace ─ specialWorkspaceIn/Out
__internal_fadeCTM (отдельно)
```
Умолчания: `global = (1, 8, "default")`, `borderangle/shadowangle/glowangle = выключены`.
`hyprutils:src/animation/AnimationConfig.cpp: setConfigForNode()` — переопределение **целиком**
(enabled, speed, curve, style), затем `setAnimForChildren()` — всем НЕ переопределённым потомкам
`pValues = pValues родителя` (рекурсивно). Частичного слияния полей нет (в Lua `speed` и кривая обязательны,
`style` по умолчанию пустой). Кривая spring хранится как строка `"spring:<имя>"`
(`Hyprland:src/config/lua/bindings/LuaBindingsConfigRules.cpp: hlAnimation()`).

Несоответствие в нашем коде: `hook/config/hyprcfg.py: PARENT` не знает `fadeGlow`, `fadePopups*`, `fadeDpms`,
`shadowangle`, `glowangle`, `monitorAdded` и не помечает `borderangle` выключенным.

### 2.2 Тик: когда считаются значения
`Hyprland:src/animation/AnimationManager.cpp`:
- `CHyprAnimationManager()` создаёт таймер event-loop; `scheduleTick()` ставит его на **1 мс**.
- `frameTick()`: зовётся (а) таймером и (б) в начале **каждого** `IHyprRenderer::renderMonitor()`
  (`Hyprland:src/render/Renderer.cpp:2055`). Тик выполняется, если с прошлого прошло ≥1 мс; пока есть активные
  переменные — перепланирует себя на +1 мс.
- `tick()`: по каждой активной переменной `handleUpdate()` → `getCurveStep()` → `value = begun + (goal−begun)·step`
  (цвет — §2.6), затем damage и `scheduleFrame(AQ_SCHEDULE_ANIMATION)`.
- Итог: **значение — функция настенного времени** (`steady_clock`), а не номера кадра. Тик ~1 кГц + в начале
  рендера → кадр показывает значение на момент начала своего рендера. vblank здесь ни при чём.
- Все переменные независимы, анимируются параллельно; у каждой свой `animationBegin`/spring-состояние.

### 2.3 speed → время (только bezier)
`hyprutils:src/animation/AnimatedVariable.cpp: getPercent()`:
```
percent = clamp( (ms_since_begin / 100) / speed , 0, 1 )      // ms — целые (duration_cast<milliseconds>)
```
т.е. **длительность = speed × 100 мс**. `internalSpeed` больше нигде не используется
(grep по hyprutils и Hyprland) → **для spring-листьев `speed` не влияет ни на что**.

### 2.4 Bezier
`hyprutils:src/animation/BezierCurve.cpp`:
- `setup()`: точки P0=(0,0), P1, P2, P3=(1,1). Координаты в Lua допускаются в [−1, 2].
- Предзапекание: `BAKEDPOINTS=255`, точка i = `(X(t), Y(t))` при `t=(i+1)/255`, i=0..254 (t=0 не запекается).
  X(t)/Y(t) — стандартный кубический Безье.
- `getYForPoint(x)`: x≥1→1, x≤0→0; иначе бинарный поиск по запечённым X (шаг 128,64,…,1 с флагом `below`),
  затем **линейная интерполяция** между соседними запечёнными точками; если dx≤1e-6 → y нижней.
- `getCurveStep()`: если percent≥1 → finished, value=1. Иначе value = `getYForPoint(percent)`.
- Для повторения 1:1 в нашем C-коде: портировать именно запекание 255 точек + этот поиск
  (не решать кубическое уравнение — значения в начале кривой отличаются).

### 2.5 Spring (точная формула)
`hyprutils:src/animation/Spring.cpp: advanceSpring(value, velocity, spring, dt)` — **аналитическое решение**
затухающего осциллятора x'' = −(k/m)(x−1) − (d/m)x', нормированного к цели 1:
```
DT   = max(dt, 0);  m = max(mass,1e-4); k = max(stiffness,1e-4); d = max(damping,0)
disp = value − 1;  ω0 = sqrt(k/m);  γ = d/(2m)
недодемпф. (γ<ω0):  ωd = sqrt(ω0²−γ²); E=exp(−γ·DT); S=sin(ωd·DT); C=cos(ωd·DT)
   disp' = E·( disp·C + ((v + γ·disp)/ωd)·S )
   v'    = E·( v·C − ((γ·v + ω0²·disp)/ωd)·S )
критич. (|γ−ω0| ≤ max(ω0,1)·1e-4):  B = v + γ·disp
   disp' = E·(disp + B·DT);  v' = E·(v − γ·B·DT)
передемпф.: R=sqrt(γ²−ω0²); r1=−γ+R; r2=−γ−R; A=(v−r2·disp)/(r1−r2); B=disp−A
   disp' = A·e^{r1·DT} + B·e^{r2·DT};  v' = A·r1·e^{r1·DT} + B·r2·e^{r2·DT}
value = 1 + disp'
```
- `getCurveStep()` для spring: `DT = now − springLastStep` (реальное время между тиками), шаг, затем
  **финиш**: `|1−value| ≤ valueEpsilon(0.001) И |velocity| ≤ velocityEpsilon(0.001)` → value=1, v=0, finished.
  Эпсилоны — поля `SSpringCurve` (`hyprutils:include/hyprutils/animation/AnimationManager.hpp`), из Lua не задаются.
- Начало: `onAnimationBegin()` → `resetSpringState()`: value=0, velocity=0 (или сохранённая, §2.5.1).
- Т.к. решение аналитическое, композиция шагов = точное решение при ЛЮБОМ dt → результат не зависит от
  частоты тика; от частоты зависит только момент проверки финиша.
- Наш `hook/src/anim.c` повторяет недодемпф. ветку точно; крит./передемпф. сделаны Эйлером (для drift/bounce
  не нужны, но для 1:1 при других кривых — заменить на аналитику выше).

#### 2.5.1 Перезапуск посреди хода (retarget) — `CGenericAnimatedVariable::operator=`
`hyprutils:include/hyprutils/animation/AnimatedVariable.hpp`:
```
if (v == goal) return;                       // та же цель — ничего
WASANIMATING = isBeingAnimated
scale = 1
if (WASANIMATING && spring && тип арифметический (float)):
    scale = (goal_old − begun_old) / (v − value_now)   (или 0, если знаменатель ~0)
goal = v;  begun = value_now                 // старт от ТЕКУЩЕГО визуального значения
onAnimationBegin(preserve = WASANIMATING && spring, scale):
    spring: value=0; velocity = preserve ? velocity·scale : 0; springLastStep=now
    animationBegin = now                     // bezier: время с нуля, полная длительность
```
Следствия:
- **bezier**: перезапуск с текущего места, полная длительность, скорость теряется (излом).
- **spring float** (alpha, offset стола хранится как Vector2D — см. ниже): физическая скорость сохраняется
  (нормированная масштабируется отношением дельт).
- **spring Vector2D** (позиция/размер окна, renderOffset стола): `is_arithmetic_v<Vector2D>` = false →
  scale=1: сохраняется **нормированная** скорость, которая затем умножается на НОВУЮ дельту
  (физическая скорость меняет величину и направление на направление новой дельты). Это квирк Hyprland —
  для 1:1 повторять именно так.
- `setValueAndWarp(v)`: goal=begun=value=v, без анимации. `warp()`: value=goal, end-callback.

### 2.6 Цвета
`AnimationManager.cpp: updateColorVariable()` — цвет переменной лерпится в **OkLab** (L,a,b), альфа линейно.
Градиенты рамки/тени/glow анимируются иначе: переменная прогресса 0→1 и шейдер смешивает два градиента в
OkLab (`mix(result1,result2,lerp)` в `gradient.glsl`), §5.1.

---

## 3. Окна

Переменные окна (`Hyprland:src/desktop/view/Window.cpp: CWindow::create()`, строки ~148–163):
| переменная | начальный конфиг | назначение |
|---|---|---|
| m_realPosition, m_realSize (Vector2D) | windowsIn | геометрия (визуальная; goal = раскладка) |
| m_borderFadeAnimationProgress | border | кроссфейд градиента рамки |
| m_borderAngleAnimationProgress | borderangle | (выкл.) |
| alpha FADE | fadeIn | открытие/закрытие |
| alpha ACTIVE | fadeSwitch | active/inactive opacity (у нас 1/1) |
| alpha FULLSCREEN | fadeIn | скрытие под fullscreen |
| alpha LAYOUT | fadeSwitch | группы/monocle |
| m_shadowFadeAnimationProgress | fadeShadow (=global 800 мс) | кроссфейд цвета тени |
| m_glowFadeAnimationProgress | fadeGlow (=global 800 мс) | кроссфейд glow |
| m_dimPercent | fadeDim | dim |
| alpha MOVE_TO_WORKSPACE | fadeOut | уход окна на невидимый стол |
| alpha MOVE_FROM_WORKSPACE | fadeIn | приход окна на видимый стол |
| m_notRespondingTint | fade (=global) | серая тонировка зависшего |

Итоговая альфа при отрисовке (`Renderer.cpp: renderWindow()`):
`fadeAlpha = A_FADE · A_FULLSCREEN · A_LAYOUT · ws.m_alpha · (A_MOVE_TO_WS если уходит на невидимый) · A_MOVE_FROM_WS`,
`alpha = A_ACTIVE`; содержимое и ВСЕ декорации рисуются с `fullAlpha = alpha·fadeAlpha`; блюр-подложка — с `fadeAlpha`.
Позиция отрисовки: `REALPOS = m_realPosition.value + ws.m_renderOffset.value` (у pinned без offset).

### 3.1 Открытие окна (windowsIn popin 86% + fadeIn)
Поток (`Window.cpp: commitWindow()` → `mapWindow()`):
1. **До первого кадра** (initial commit): `predictSizeForNewTiledTarget()` → клиенту сразу шлётся configure с
   предсказанным размером плитки (`DwindleAlgorithm::predictSizeForNewTarget`: половина бокса фокусного узла по
   правилу `h·mult > w`). Приложение рисует первый буфер уже нужного размера.
2. `mapWindow()`: окно вставляется в dwindle (§7.2), `layoutTarget()->recalc()` → у соседей `setBox` → их
   `windowsMove`-spring стартует **в тот же момент**.
3. Переключение конфигов: pos/size → `windowsIn`, alpha FADE → `fadeIn`;
   `m_animationController.apply(animateIn())` (`desktop/view/animationControllers/WindowAnimationController.cpp`).
4. `animateIn()`: from/to = GOAL позиция/размер; alpha 0→1; затем стиль. Для `popin X%`
   (`applyPopin`, minPerc = X/100 = 0.86):
   ```
   ENDSIZE = clamp(GOALSIZE·0.86, (5,5), GOALSIZE)
   ENDPOS  = GOALPOS + GOALSIZE/2 − ENDSIZE/2          // масштаб от центра
   pos:  ENDPOS → GOALPOS ;  size: ENDSIZE → GOALSIZE   (spring bounce, обе переменные стартуют вместе)
   alpha FADE: 0 → 1 (smooth, 300 мс)
   ```
   Визуальный масштаб s(t) = 0.86 + 0.14·y(t), y — bounce; пик y=1.0834 в 0.249 с → **s_max = 1.0117**
   (окно на ~1.2% больше плитки), к 0.74 с успокаивается. Альфа к 0.3 с уже 1.
   Для справки: `gnomed` — from (GOALPOS + (0, H/2), (W,0)); `slide [dir]` — from за ближайший край монитора.
5. По окончании pos/size — `setVector2DAnimToMove`: конфиг → `windowsMove`, `m_animatingIn=false`.
6. Содержимое во время popin: `m_animatingIn=true` → в `calculateUVForSurface` обрезка пропускается →
   буфер **растягивается** на анимированный бокс (масштаб текстуры, `SurfacePassElement::getTexBox`:
   бокс = (REALPOS, REALSIZE)). Рамка/тень/glow рисуются вокруг анимированного бокса **с постоянной толщиной**
   (2 px, range 34, 18) — не масштабируются.
7. Блюр под окном: альфа подложки = fadeAlpha; у плавающих (живой блюр) радиус = size·fadeAlpha (§5.5).

### 3.2 Закрытие окна (windowsOut popin 92% + fadeOut, по снимку)
`Window.cpp: unmapWindow()` (стр. ~2586–2701), `desktop/state/WindowFadeout.cpp: CWindowFadeout::create()`:
1. **Снимок** `IHyprRenderer::makeSnapshotFB(window)` (`Renderer.cpp:3087`): FB размером с МОНИТОР, окно
   отрисовано целиком **с декорациями** (тень, рамка, glow), без блюра (`m_bRenderingSnapshot`).
2. Окно удаляется из раскладки → соседи сразу едут `windowsMove` (drift).
3. Fadeout-объект: `m_sourcePos/Size` = текущий визуальный бокс; `animateOut()`: from = текущие pos/size/alpha,
   to по popin 92%: `ENDSIZE = SIZE·0.92`, `ENDPOS = POS + SIZE/2 − ENDSIZE/2`; alpha → 0.
   Кривые: pos/size `windowsOut` (snappy 260 мс), alpha `fadeOut` (smooth 240 мс). Стартовая альфа =
   `A_FADE·A_FULLSCREEN·A_LAYOUT` на момент закрытия.
4. Отрисовка (`WindowFadeout::renderBox()` + `Renderer::renderFadeouts()`):
   ```
   SCALE = realSize/sourceSize (покомпонентно; для popin одинаково)
   box = ((realPos − monPos)·scale_mon − sourcePos·scale_mon·SCALE,  monitorPx·SCALE)
   ```
   т.е. весь снимок (с тенью и рамкой) равномерно масштабируется так, что угол окна попадает в realPos.
   Альфа текстуры = alpha. Если окно блюрилось — отдельно рисуется блюр-прямоугольник по анимированному боксу
   со скруглением окна и альфой **sqrt(alpha)**. Плоскость (tiled/floating) и z-индекс сохраняются.
5. Готово, когда alpha==0 и обе геометрии остановились (260 мс; альфа доходит до 0 уже к 240 мс).

### 3.3 Перемещение/resize (windowsMove) и что с содержимым
- Раскладка ставит цель: `CWindowTarget::updatePos()` (`layout/target/WindowTarget.cpp`) → `m_window->setBox(box)`
  → `*m_realPosition = pos; *m_realSize = size` (`GeometricMovableAnimated.cpp`) → обе Vector2D-переменные
  стартуют `windowsMove` (drift) одновременно (retarget по §2.5.1).
- **Configure клиенту**: `m_realSize->setCallbackOnBegin(...)` (`Window.cpp: onMap()`, ~стр. 800) → на начале
  анимации размера через `doLater` (следующая итерация event loop) `sendWindowSize()` с
  **ЦЕЛЕВЫМ** размером (`realToReportSize()` = `m_realSize->goal()`). Т.е. приложение сразу получает финальный
  размер и перерисовывается, а рамка ещё едет.
- `m_reportedSize` обновляется при ack configure; `getSurfaceExpectedSize()` (`render/ElementRenderer.cpp`) берёт
  размер текущего буфера (если reported ≠ размер поверхности — размер поверхности).
- **Правило отрисовки содержимого** (`ElementRenderer::calculateUVForSurface`, `SurfacePassElement::getTexBox`):
  бокс отрисовки = анимированный (REALPOS, REALSIZE); `RATIO = боксPx / размерБуфераPx`.
  - `m_animatingIn` (открытие) → **растяжение** (UV не трогаются).
  - иначе, если RATIO<1 (бокс меньше буфера): `uvBR *= RATIO` → **обрезка справа/снизу**, контент 1:1
    по пикселям, прижат к левому верхнему углу.
  - если RATIO>1 и `expand_undersized_textures` (у нас true): `uvBR *= RATIO` с `GL_CLAMP_TO_EDGE` →
    контент 1:1 у левого верхнего угла, **последний столбец/строка буфера тянутся** до края бокса.
  - скругление/рамка/тень/блюр всегда по анимированному боксу.
  Значит, визуально в Hyprland при resize: контент почти сразу (через 1–2 кадра у kitty) в финальной раскладке,
  а «рамка окна» плавно едет пружиной, контент внутри обрезан/дотянут краями. Субповерхности при анимации
  размера масштабируются пропорционально.
- `animate_manual_resizes=true`: клавиатурный resize (`resizeTarget` → `recalcSizePosRecursive(force = !animate)`)
  анимируется drift. Мышиный resize/drag текущей цели — `warpPositionSize()` (мгновенно, в конце `resizeTarget`),
  `animate_mouse_windowdragging=false` — перетаскивание без анимации.
- Перемещение направлением/перенос на стол: `setAnimationsToMove()` — позиция с конфигом windowsMove.

### 3.4 Смена фокуса
`Window.cpp: updateDecorationValues()`:
- рамка: если градиент изменился — `prev = cur; cur = new; progress: setValueAndWarp(0); = 1` →
  кроссфейд prev→new (border: smooth 600 мс), шейдер смешивает в OkLab.
- alpha ACTIVE → active/inactive opacity (1.0/1.0 — без эффекта).
- dim → 0 (dim_inactive выкл.).
- тень: цвет 0.467 ↔ 0.267 (color_inactive задан) — кроссфейд fadeShadow = **800 мс smooth**.
- glow: primary@0.2 ↔ @0 — кроссфейд fadeGlow = **800 мс smooth**.
- Порядок отрисовки: тайловые окна в порядке списка, **фокусное — последним** среди тайловых, потом плавающие
  (`Renderer.cpp: renderWorkspaceWindows`). Значит тень фокусного окна ложится поверх краёв соседей.

### 3.5 Скрыть/вернуть, перенос на стол
`Window.cpp: moveToWorkspace()`: если старый стол видим — alpha MOVE_TO_WORKSPACE 1→0 (fadeOut 240 мс),
окно рисуется на месте, пока гаснет; позиция — windowsMove. При приходе на видимый стол
(`GlobalWindowController.cpp`): alpha MOVE_FROM_WORKSPACE 0→1 (fadeIn 300 мс); позиция — drift из прежней
точки в новую плитку. Остальные окна перераскладываются drift одновременно.
- M+W (hide): окно гаснет 240 мс на месте, соседи заполняют место drift.
- M+Shift+W (restore): окно летит drift из своей старой (невидимой) позиции в новую плитку + fade-in 300 мс.

### 3.6 Fullscreen / maximized
- maximized (M+Shift+Return): `setBox(workArea − reserved)` → обычный windowsMove drift; рамка/тень остаются.
- fullscreen (M+F): бокс = монитор; рамка не рисуется, скругление 0; остальные окна стола: alpha FULLSCREEN → 0
  (fadeIn-конфиг, 300 мс smooth); top-слои (waybar) гаснут (`setFullscreenFadeAnimation`).
- `on_focus_under_fullscreen=2`: новое/активированное окно снимает fullscreen/maximize.

---

## 4. Рабочие столы

### 4.1 Обычные столы: slidefade 12% + drift
`Hyprland:src/animation/WorkspaceAnimationController.cpp: startAnimation()`,
`output/Monitor.cpp: changeWorkspace()` (~стр. 1438):
- направление: `ANIMTOLEFT = new_id > old_id` (wraparound выключен). Для Lua `ws_step` при переходе 5→1
  id уменьшается → анимация «назад».
- у стола две переменные: `m_renderOffset` (Vector2D) и `m_alpha` (float), конфиг `workspacesIn/Out` (= drift).
- `slidefade P%` (P=12), горизонтально, W = **логическая ширина монитора** (`m_size.x`):
  ```
  IN  (новый): alpha 0→1;  offset ( left ? +W·0.12 : −W·0.12 , 0 ) → (0,0)
  OUT (старый): alpha 1→0;  offset (0,0) → ( left ? −W·0.12 : +W·0.12 , 0 )
  ```
  **gaps_workspaces не участвует** (он только в чистом `slide`: `(W + gaps_workspaces)·P`).
- Применение: offset прибавляется к позиции **окон** и их декораций (рамка, тень, glow, блюр-бокс берутся
  со сдвигом); обои и слои (waybar) **не двигаются**. Блюр под окнами (tiled, new_optimizations) берётся из
  кэша блюра обоев **в экранных координатах** — т.е. «стекло» показывает обои под текущим экранным местом окна.
- Альфа стола умножает fadeAlpha всех его окон (кроме pinned).
- Оба стола рисуются одновременно, пока их анимации идут (`shouldRenderWindow`: ws.renderOffset/alpha animating).
  Плавающие окна при сдвиге клипаются по своему полному боксу.
- drift на alpha (float): перелёт ~1% → альфа кратко чуть выходит за [0,1].
- Числа: Linux 2560 → сдвиг 307.2 px; MacBook Air при 1470 pt ширины → **176.4 pt**.

### 4.2 Спец-стол (dropterm, hidden): slidefadevert 14% + overshot 400 мс
`Monitor.cpp: setSpecialWorkspace()` → `startAnimation(ws, IN, left=true)` / `(ws, OUT, left=false)`:
```
H = логическая высота монитора
IN : alpha 0→1, offset (0, +H·0.14) → (0,0)        // въезжает СНИЗУ вверх
OUT: alpha 1→0, offset (0,0) → (0, +H·0.14)        // уезжает вниз
```
плюс (специальный блок в конце `startAnimation`) у спец-стола альфа всегда 0→1 / 1→0.
`setSpecialWorkspaceVisualState()`: `m_specialFade`, `m_specialDim` (→ dim_special=0, т.е. 0),
`m_specialBlur` (→ 1, т.к. `blur:special=true`) на кривых `specialWorkspaceIn/Out` (= overshot 400 мс).
`renderAllClientsForWorkspace()` (`Renderer.cpp` ~1187): **после окон обычного стола** рисуется прямоугольник на весь
монитор с блюром и альфой `m_specialBlur` (т.е. весь экран под dropterm плавно мылится), затем окна спец-стола.
Числа: Linux 1440 → 201.6 px; Mac 956 pt → 133.8 pt. overshot даёт перелёт +1.1% к ~0.27 с.

---

## 5. Оформление (рендер)

### 5.1 Рамка (border) — `render/decorations/CHyprBorderDecoration.cpp`, `render/OpenGL.cpp: renderBorder()`, `shaders/glsl/border.glsl`, `gradient.glsl`
- Геометрия: бокс окна (контент) → `renderBorder` расширяет на `borderSize` со всех сторон. Рамка — кольцо
  **снаружи** контента, внутри слота плитки.
- Радиусы: внутренний `ROUNDING = rounding·scale = 18`; внешний
  `OUTERROUND = (rounding + border − CORRECTION)·scale`, `CORRECTION = border·(√2−1)·max(2−power, 0)` →
  при power 2.6 коррекция 0 → **внешний 20**. (В `renderBorder` передаётся `round + borderSize`.)
- Шейдер: в углах — расстояние суперэллипса `dist = (x^p + y^p)^(1/p)` до центра скругления для внутренней и
  внешней кривой, АА `smoothstep` шириной `SMOOTHING_CONSTANT = π/5.34665792551 ≈ 0.5876 px`; на прямых
  участках — пиксели ближе `thick` к краю бокса.
- **Градиент** (`getOkColorForCoordArray1`): `uv` ∈[0,1]² бокса рамки, (0,0) = левый верхний
  (`OpenGL.hpp: fullVerts`). Угол `a` (рад). Для a ≤ 90°:
  ```
  progress = (uv.y·sin(a) + uv.x·(1 − sin(a))) · (N−1)
  цвет = lerp(grad[floor], grad[floor+1], frac)   — в OkLabA, затем → sRGB (gamma 2.2)
  ```
  (для 90–180°, 180–270°, >270° — отражения uv). Это НЕ поворот, а такая аппроксимация — повторять её.
  У нас a=45°: progress = 0.707·y + 0.293·x → primary в левом верхнем углу, tertiary в правом нижнем.
- Кроссфейд при фокусе: `mix(OkLab(grad_prev), OkLab(grad_new), lerp)` → sRGB, lerp = border-прогресс
  (smooth 600 мс). Неактивная — один цвет `46483e`, a=0.333.
- Альфа пикселя: `color.rgb *= color.a` (premult), затем `× fullAlpha × additionalAlpha`.

### 5.2 Скругление (rounding + rounding_power) — `shaders/glsl/rounding.glsl`
```
pix -= topLeft + size/2;  pix = |pix|;  pix -= size/2 − r;   (r = rounding − 1 для поверхностей = 17)
если pix.x + pix.y > r:
    dist = (pix.x^p + pix.y^p)^(1/p)        // p = 2.6 — суперэллипс (Ламе)
    dist > r + 0.5876 → discard
    color *= 1 − smoothstep(0, 1, (dist − r + 0.5876)/(2·0.5876))
```
Для поверхности окна радиус на 1 меньше («to fix a border issue»), у рамки внутренний 18 → стык без щели.
Точка угла на 45° находится на расстоянии r·2^(−1/p) = 0.766·r от центра скругления (у круга 0.707·r) —
угол «квадратнее» круга. Fullscreen — без скругления.

### 5.3 Тень — `render/decorations/CHyprDropShadowDecoration.cpp`, `OpenGL.cpp: renderRoundedShadow()`, `shaders/glsl/shadow.glsl`
- Бокс: `fullBox` = бокс окна **с декорациями** (т.е. с рамкой, +2) расширенный на `range=34` со всех сторон,
  масштаб `scale=1` от центра, сдвиг `offset=(0,10)`.
- Скругление тени: `rounding + border − CORRECTION = 20`; `radius_corner = range + 20 = 54`.
- Альфа (power = clamp(render_power,1,4) = 3):
  - в углах (пиксель левее/выше `topLeft=(range+round)` и т.п.): `dist` = суперэллипс-расстояние до угловой
    точки; `a = 0` если dist > 54; `a = ((54 − dist)/34)^3` если dist > 20; иначе 1.
  - на сторонах: `smallest` = расстояние до ближайшего края fullBox; если < 34: `a = (smallest/34)^3`.
  - итог `color.a · a · alpha`; **внутри контента окна тень вырезана** (`pointInRoundedRect` по боксу поверхности
    окна со скруглением окна) — под полупрозрачным kitty тени нет.
- Эквивалент: профиль `(1 − e/34)^3` (e — расстояние наружу от края бокса с рамкой) почти точно совпадает
  с гауссовой тенью прямоугольника **σ ≈ 11 px** и плотностью ×1.95 (ошибка ≤0.01 по всей длине: e=0:1.0/0.975,
  5:0.62/0.63, 10:0.35/0.35, 20:0.07/0.07). Полезно, если делать тень нативной тенью macOS.
- Цвет: активное 0.467, неактивное 0.267 чёрного; смена — кроссфейд 800 мс.
- Рисуется ПОД окном (DECORATION_LAYER_BOTTOM) в порядке окон.

### 5.4 Glow (внутреннее свечение) — `render/decorations/CHyprInnerGlowDecoration.cpp`, `shaders/glsl/inner_glow.glsl`
- Это свечение **внутрь** окна, поверх контента (DECORATION_LAYER_OVER), бокс = бокс поверхности окна,
  радиус `rounding − 1 = 17`, power 2.6.
- Альфа: обрезка по SDF суперэллипс-прямоугольника; `d` = smooth-min расстояний до 4 краёв
  (`smin(a,b,k) = min(a,b) − h³·k/6`, `h = max(k−|a−b|,0)/k`, k=range=18);
  `a = d ≥ 18 ? 0 : (1 − d/18)^3`; итог `color.a(0.2)·a·fullAlpha`.
- Активное primary@0.2, неактивное @0 → у неактивных glow нет; кроссфейд 800 мс.

### 5.5 Блюр (dual-kawase) — `render/OpenGL.cpp: blurFramebufferWithDamage()`, `shaders/glsl/blur*.glsl`
Конвейер (на полноразмерных рабочих FB, уменьшение через uv):
1. **prepare**: contrast (если ≠1: `gain(x,k)`) — у нас 1.0, пропуск; `rgb *= max(1, brightness)` — у нас ×1.
2. **down ×passes** (`blur1`): выход в регион 1/2^i; `uv = v·2`; `sum = 4·T(uv) + T(uv ± hp·r) + T(uv ± (hp.x,−hp.y)·r)`,
   `/8`; `hp = 0.5/(Wpx/2)`, `r = size·a` (a — альфа-множитель блюра). После каждого down-прохода —
   **vibrancy**: HSL; `perceived = doubleCircleSigmoid(sqrt(0.299r²+0.587g²+0.114b²), 0.8·(1−vd))`;
   `b1 = 0.11·(1−vd)`; `boost = smoothstep(b1−0.33, b1+0.33, 1 − ((1−S·cos .93)² + (1−perceived·sin .93)²))`;
   `S' = clamp(S + boost·vibrancy/passes)` (vibrancy 0.22, vd 0.4).
3. **up ×passes** (`blur2`): `uv = v/2`, 8 отсчётов (крест ×1 на 2hp·r, диагонали ×2 на hp·r), `/12`,
   `hp = 0.5/(Wpx·2)`.
4. **finish**: `rgb += (hash(uv) − 0.5)·noise` (±0.004); `rgb *= min(1, brightness)` = ×0.92.
- Эффективное ядро (численно повторил шейдеры): **size 5 / passes 2 → σ ≈ 10.4 px** (size5/p1: 4.7; p3: 21.3).
  Всё в **физических пикселях монитора** (hp от `m_pixelSize`). На Linux scale=1 → 10.4 логич. px.
- Что сэмплится:
  - **тайловые окна** (new_optimizations=1, xray=0, не special): заранее посчитанный `m_blurFB` = блюр
    **обоев + BACKGROUND/BOTTOM слоёв** (без других окон), считается при `a=1` (полный радиус) один раз и
    обновляется при их изменении (у видео-обоев — каждый кадр).
  - **плавающие и на спец-столе**: живой блюр всего, что уже нарисовано под окном, радиус `size·fadeAlpha`.
  - слои с `blur=true` (waybar, rofi, swaync, osd): с `ignore_alpha` — блюр только там, где альфа пикселя > порога.
- Отрисовка (`OpenGL.cpp` ~2088): сначала блюр-текстура в бокс окна со скруглением и альфой
  `blurA = fadeAlpha` (ignore_opacity=1), uv — **экранные** координаты бокса; затем текстура окна поверх.
  Блюр рисуется только если окно не непрозрачное (`!texture->opaque || alpha<1`).

### 5.6 Порядок слоёв кадра (`Renderer.cpp: renderAllClientsForWorkspace`)
фон(background_color/обои) → BACKGROUND слои → BOTTOM слои → [pre-blur кэша] → окна стола:
тайловые (каждое: тень → блюр-подложка → поверхности → рамка → glow; фокусное последним) → fadeout тайловых →
попапы тайловых → плавающие → fadeout плавающих → [dim/blur спец-стола] → окна спец-стола → pinned →
TOP слои (waybar) → OVERLAY → попапы слоёв.

### 5.7 Слои (для полноты; на маке это наши лаунчер/уведомления, не окна приложений)
`desktop/view/animationControllers/LayerSurfaceAnimationController.cpp`: `popin P%` — размер от P·size по центру
+ альфа 0→1 (rofi 92%, osd 90% на layersIn overshot 340 мс); `slide [edge]` — от ближайшего края монитора
(swaync — справа); `fade` — только альфа.

---

## 6. Dwindle (layout/algorithm/tiled/dwindle/DwindleAlgorithm.cpp)

### 6.1 Геометрия
- Рабочая область (`layout/space/Space.cpp`): монитор − reserved (waybar: сверху 64) − gaps_out (8/12/12/12).
- Узел: `box`, `splitTop` (true = верх/низ), `splitRatio` (0.1..1.9), `children[2]`.
  `recalcSizePosRecursive`: если `preserve_split=0 && smart_split=0 && precise_mouse_move=0` — `splitTop = h·mult > w`
  (у нас preserve_split=1 → ориентация фиксирована при создании). Первый ребёнок: `FIRST = w/2·ratio`
  (или `h/2·ratio`), второй — остаток.
- Окно в слоте (`WindowTarget::updatePos`): слот (округлённый) → внутрь на `gaps_in` с каждой стороны, НЕ
  совпадающей (|Δ|<2) с краем рабочей области → внутрь на reserved декораций (рамка 2) → `round()` → `setBox`.
- Пример для Mac 1470×956 pt, меню-бар M pt (замерить; ниже M=37): рабочая область x 12..1458, y 45..944.
  Одно окно: контент (14, 47, 1442, 895). Два рядом: слоты по 723; контент левого (14,47,714,895), правого
  (742,47,714,895); между внешними краями рамок 10, между контентами 14.

### 6.2 Вставка нового окна (`addTarget`)
1. `OPENINGON` (кого делим): при `use_active_for_splits=1` (у нас) — **активное тайловое окно** этого стола;
   иначе ближайший к курсору узел (`getClosestNode` = минимум квадрата расстояния точки до прямоугольника).
   Если стол пуст — окно получает всю рабочую область.
2. Если `maxSize` окна меньше бокса OPENINGON — окно становится плавающим.
3. Новый родитель забирает бокс OPENINGON; `ratio = default_split_ratio (1.0)`;
   `SIDEBYSIDE = w > h·split_width_multiplier` → `splitTop = !SIDEBYSIDE`.
4. Сторона (кто first):
   - есть preselect (`m_overrideDirection`): up/left → новое окно first; right/down → second; ориентация
     принудительно (up/down → верх/низ, left/right → рядом); после одного окна сбрасывается
     (`permanent_direction_override=0`).
   - иначе `smart_split=1` или (`precise_mouse_move=1` и окно только что тащили мышью): сторона по
     наклону вектора курсор−центр относительно пропорций бокса (4 сектора).
   - иначе `force_split=0` (у нас): **по курсору**: если SIDEBYSIDE и `mouse.x < центр.x` (или верх/низ и
     `mouse.y < центр.y`) → новое first (слева/сверху), иначе second.
5. `recalcSizePosRecursive` нового родителя → все задетые окна получают setBox (drift).

### 6.3 Удаление
Сосед (sibling) занимает место родителя целиком (с его боксом), родитель удаляется, `recalculate()` от корня →
drift у всех задетых.

### 6.4 Перенос направлением (`window.move{direction}` → `moveTargetInDirection`)
1. `focal` = точка на 1 px за серединой соответствующей стороны «идеального» бокса окна
   (`ModeAlgorithm.cpp: focalPointForDir`).
2. Если двигаемся прямо в ближайший разделитель и партнёр по сплиту — одиночное окно, ставится
   `m_overrideDirection = dir` (гарантирует, что окно окажется по ту сторону партнёра).
3. Окно удаляется (`removeTarget` + пересчёт), затем `movedTarget(t, focal)` = вставка с фокусной точкой:
   OPENINGON = ближайший к focal узел; сторона — по focal (ветка force_split=0) или по override.
4. Позиция окна: `setAnimationsToMove` → drift из текущего места. Если focal на другом мониторе — перенос туда.
   Это **не swap** (в нашем `tile.py` сейчас swap — расхождение, см. HANDOFF).

### 6.5 resizeactive (`window.resize{x,y,relative}` → `resizeTarget`, smart_resizing=1, corner NONE)
- Если окно касается и левого, и правого края — x не двигается; аналогично y.
- Идём вверх по дереву: первый предок с горизонтальным сплитом → PHOUTER, первый с вертикальным → PVOUTER
  (и «inner» для вложенных того же направления).
- `parent.splitRatio += Δx·2/parent.w` (clamp 0.1..1.9) → **вертикальный разделитель сдвигается на Δx px**
  (вправо при +60) независимо от того, с какой стороны окно. Если есть PHINNER — его ratio
  пересчитывается так, чтобы внутренняя ширина компенсировалась. Аналогично по y.
- `recalcSizePosRecursive(force = !animate_manual_resizes)` → с drift-анимацией.
  Мышью (corner задан) — какие края двигать, решают corner и касание краёв монитора; в конце warp без анимации.

### 6.6 togglesplit / splitratio / preselect / swapsplit
- `togglesplit`: `parent.splitTop = !splitTop`, пересчёт (drift).
- `splitratio X [exact]`: `ratio = exact ? X : ratio + X` (clamp), пересчёт от родителя.
- `preselect u|d|l|r` → `m_overrideDirection`; любой другой символ (`none`) → сброс.

### 6.7 Фокус направлением (`desktop/state/WindowQuery.cpp: inDirection`)
- Кандидаты: замапленные, видимые, на том же мониторе — только этого стола; плавающие отдельно от тайловых.
- Смежность по оси: края совпадают (<2 px) ИЛИ перекрытие ≤50% меньшего размера и не вложены; тогда
  `intersectLength` = длина перекрытия по поперечной оси; нужно >1.
- Выбор (`binds:focus_preferred_method=0`, умолч.): **самое недавнее в истории фокуса** среди смежных.
- Нет кандидата → другой монитор (`window_direction_monitor_fallback`). Курсор не прыгает (`no_warps`).

### 6.8 Прочее
- `predictSizeForNewTarget`: половина бокса фокусного окна по `h·mult > w`.
- Свёртывание (swallow): окно, запущенное из kitty, занимает узел kitty, kitty скрывается.
- Плавающее по умолчанию: desired size или 640×400 по центру рабочей области (`DefaultFloatingAlgorithm.cpp`);
  детали float-toggle не разбирал.

---

## 7. Спецификация переноса на macOS (наша архитектура)

### 7.0 Общая схема «кто что считает»
- **Демон (hyprwm.py)** — логика Hyprland «на событие»: дерево dwindle (§6) → целевые боксы; события
  (открытие, закрытие, фокус, стол, бинд) → **задания анимации** в общий буфер ctx WS-кода:
  `{wid, вид(move/open/close/ws/special/fade), from_box, to_box, curve_id, alpha_from, alpha_to, alpha_curve_id,
  t0}`. Все задания одного события получают **один t0** (как в Hyprland: все переменные стартуют в одном тике).
- **Покадровый код в WS (anim.c)** — только математика §2 по времени: на каждом кадре `t = момент композита`
  (лучше предсказанное время следующего композита: `now + период`, т.к. наш тик после кадра N влияет на N+1),
  вычисляет визуальный бокс `B(t)` и альфу, ставит трансформ/альфу, рисует декорации. Кривые: таблица
  bezier (запечённые 255 точек, поиск как в §2.4) и spring (аналитика §2.5), retarget по §2.5.1.
- Время: `SLSCurrentRealTime()`; длительность bezier `speed·100 мс` по реальному времени; spring — реальный dt.
  При 60 Гц: drift/bounce 45 кадров, windowsOut 16, fadeIn 18, fadeOut 15, border 36, special 24.

### 7.1 Трансформ для визуального бокса (основа всех эффектов)
Реальная серверная рамка окна `F=(fx,fy,fw,fh)` (CGXMoveWindowList / resize), нужный визуальный бокс `B`:
```
sx = bw/fw, sy = bh/fh, D = (bx−fx, by−fy)
матрица ЭКРАН→ОКНО (row-vector, как CATransform3D): m11=1/sx, m22=1/sy, m33=1, m44=1,
   m41 = −D.x/sx, m42 = −D.y/sy
```
Проверено для чистого сдвига (m41=−O) и масштаба (s→1/s, HANDOFF §5); **точка привязки масштаба (левый
верхний угол окна?) не подтверждена** — один эксперимент `xform.py` со scale 0.5 закрывает вопрос.
Неравномерный масштаб = растяжение содержимого (так Hyprland делает ТОЛЬКО при открытии и для снимка закрытия).

### 7.2 Перемещения без изменения размера (windowsMove, сдвиг) — 1:1 УЖЕ возможно
Сразу `CGXMoveWindowList` в цель (реальная геометрия и хит-тест верные), компенсирующий трансформ
`D(t) = (from − to)·(1 − y(t))`, y — drift. Retarget: begun = текущий визуальный сдвиг, нормированная
скорость сохраняется и применяется к новой дельте (квирк §2.5.1). Это уже есть в anim.c — привести retarget
к правилу §2.5.1 и момент t к времени композита.

### 7.3 Перемещение с изменением размера (раскладка, resize-бинды, togglesplit) — главная разница
Hyprland: контент сразу в финальном размере (configure мгновенно, 1–2 кадра), рамка/тень/скругление едут drift,
контент внутри **обрезан** (бокс меньше буфера) или **дотянут краевыми пикселями** (бокс больше), прижат к
левому верхнему углу (§3.3).
macOS: настоящий resize только через WindowManager.app (`_WMClientResizeWindowRequest`), задержка 0.1–0.3 с,
приложение само анимирует кадр своей пружиной (`_WMSpringAnimationSettings(mass, stiffness, damping, epsilon)`).
Варианты по возрастанию точности:
- **R3 (сейчас, без новой RE)**: слать запрос с пружиной drift (1/210/24/0.001) **для всех окон события, включая
  чистые сдвиги**, чтобы все края двигались синхронно с одной задержкой (иначе соседние края разъезжаются
  на 0.1–0.3 с и зазор «дышит»). Если пружина приложения = тот же осциллятор с нулевой стартовой скоростью
  (не подтверждено — замерить траекторию кадра окна), кривая совпадёт с drift, но стартует позже и
  контент перерисовывается «вживую» (в Hyprland — сразу финальный). Не 1:1.
- **R1 (целевой, 1:1)**: запрос resize с практически мгновенной пружиной (большая stiffness, критическое
  демпфирование — не подтверждено, что приложение примет и отрисует сразу) → буфер становится финальным как
  можно быстрее; визуальный бокс `B(t)` (drift) рисуем сами: на время анимации (≈0.74 с) реальное окно
  невидимо (alpha 0 или исключено из композита), а в композит подаётся его текущая поверхность с правилом
  Hyprland: `uv = (0,0)..(Bpx/буферPx)`, sampler clamp-to-edge, маска суперэллипса, + блюр, рамка, тень, glow
  по `B(t)`. По финишу (spring done И буфер = финальному) — вернуть реальное окно в тот же кадр.
  Нужно (RE): (а) доступ к текстуре/IOSurface слоя окна внутри `composite()`; (б) свой textured-pipeline в
  MetalContext (сейчас есть только `metal_clear_rect`); (в) правильный z (см. 7.10). Пока буфер старый
  (задержка доставки), правило то же — Hyprland ведёт себя так же со старым буфером.
- **R1′ (проверить)**: обрезку можно попробовать делать серверной формой окна (`shape_window_with_rect` из
  resize_re.md менял форму, и контент рисовался в ней обрезанным). Но смена формы шлёт приложению
  WindowMoved — риск побочек. Не подтверждено.
- Растягивать содержимое трансформом при resize **нельзя** — это не Hyprland (текст плывёт); допустимо только
  как временная заглушка для окон, которые не принимают resize.

### 7.4 Открытие окна (windowsIn popin 86% + bounce, fadeIn 300 мс)
1. Нужен **мгновенный** сигнал о появлении окна на сервере (опрос 150 мс слишком поздно — окно успеет мелькнуть
   в размере приложения). RE: функция заказа окна на экран (order-in) в SkyLight → наш хук в том же кадре
   ставит alpha 0. Не подтверждено, где.
2. Демон вставляет в dwindle (§6.2: делим **активное** окно, сторона по курсору), шлёт resize в плитку
   (R3/R1) и задания `windowsMove` соседям с общим t0.
3. Когда буфер нового окна = размеру плитки (или таймаут ~300 мс) — старт popin (свой t0 для этого окна):
   ```
   y = bounce(t),  s = 0.86 + 0.14·y,  B = (G.pos + G.size·(1−s)/2,  G.size·s)
   трансформ по 7.1 (равномерный масштаб — растяжение, как в Hyprland)
   alpha = smooth(t / 300 мс)  (окно и все декорации)
   ```
   Рамка 2 px / тень 34 / glow 18 рисуются вокруг `B` постоянной толщины (НЕ масштабировать вместе с окном).
4. Расхождение: в Hyprland popin и сдвиг соседей стартуют в один момент; у нас popin ждёт буфер. Чтобы не
   было рассинхрона, старт соседей тоже можно отложить до готовности буфера (одна точка t0).

### 7.5 Закрытие окна (windowsOut popin 92% snappy 260 мс + fadeOut 240 мс)
Hyprland анимирует **снимок** (окно уже уничтожено). У нас:
- закрытие нашим биндом (M+Q): сначала анимация на живом окне —
  `s = 1 − 0.08·snappy(t/260мс)`, бокс от центра, `alpha = a0·(1 − smooth(t/240мс))`, декорации вместе
  (в Hyprland они в снимке и масштабируются вместе с ним — при s≥0.92 разница незаметна); затем реальный close.
  Если приложение не закрылось (диалог «Сохранить?») — вернуть (обратная анимация/identity).
- закрытие самим приложением (Cmd+W, выход): нужен серверный хук на снятие окна с экрана, который **удерживает
  последнюю поверхность** (IOSurface retain) и 260 мс рисует её нашим кодом по формуле §3.2 (вместе с
  декорациями) — RE (не подтверждено). Без этого — только мгновенное исчезновение.
- соседи сразу получают windowsMove (drift) — это уже умеем (7.2/7.3).

### 7.6 Рабочие столы: slidefade 12% вместо анимации Dock
Рекомендация: **свои столы внутри одного Space macOS** (как AeroSpace), Space-переключение Dock не использовать.
- Скрытый стол: окна стоят за пределами экрана (`CGXMoveWindowList` — проверено), либо иной серверный способ
  скрыть без хит-теста (не подтверждено).
- Переход old→new (направление `new_id > old_id` → left):
  ```
  y = drift(t)
  новые окна: сразу CGXMove в свои плитки; offset_x = ±0.12·W·(1−y) (знак: left → +), alpha = y
  старые окна: offset_x = ∓0.12·W·y, alpha = 1 − y; по финишу — увести за экран, трансформ/альфу сбросить
  ```
  W — логическая ширина экрана в pt. Декорации каждого окна рисуются с тем же offset и альфой.
  Блюр под окнами — из кэша обоев в экранных координатах (стекло «стоит», окна едут над ним).
  Обои и меню-бар не двигаются — так же, как обои/waybar в Hyprland. 1:1.
- Повторное нажатие посреди перехода: retarget по §2.5.1 (offset — Vector2D-квирк, alpha — float со скейлом).
- `workspace_back_and_forth` и `ws_step` (кольцо 1..5) — в демоне.

### 7.7 Спец-стол (dropterm M+`) и hidden
- dropterm = плавающее окно (правило: 1600×800 @ (480,60) на 2560×1440 — на маке масштабировать пропорционально
  экрану; решение за пользователем). Показ: offset_y = +0.14·H·(1−y), alpha = y, y = overshot(t/400мс); скрытие:
  offset_y = +0.14·H·y, alpha = 1−y.
- Под ним — **блюр всего экрана** с альфой y (blur:special=true) и dim 0: нужен full-screen блюр-квад ПОД окном
  dropterm (z-проблема 7.10). Варианты: свой квад при z-загрузка модуля�; или вспомогательное прозрачное окно нашего
  процесса на весь экран со встроенным серверным блюром фона (`CGSSetWindowBackgroundBlurRadius` /
  SLS-аналог — наличие в macOS 26 не подтверждено), поставленное прямо под dropterm, альфа анимируется.
- hidden (M+W): окно гаснет на месте fadeOut 240 мс (alpha), соседи drift; по финишу — за экран.
  Возврат: окно сразу ставится в новую плитку с трансформом из старой позиции (drift) + fadeIn 300 мс.

### 7.8 Смена фокуса
- follow_mouse=1: фокус при пересечении курсором границы окна (без подъёма тайловых окон — в Hyprland фокус не
  меняет z тайловых; для плавающих — не проверял). Источник событий мыши — серверный путь событий/демон.
- Рамка: кроссфейд старого и нового градиента в OkLab, smooth 600 мс; тень 0.467↔0.267 и glow 0.2↔0 —
  smooth **800 мс** (не 600!). Фокусное окно рисует тень поверх краёв соседей (§3.4).

### 7.9 Декорации: рамка, скругление, тень, glow, блюр
Рамка и glow в Hyprland рисуются ПОВЕРХ окна, тень и блюр — ПОД. Наш `metalCallbacks` рисует поверх всего.
- **Рамка + glow** (поверх) — overlay годится: формулы §5.1, §5.4 в своём Metal-шейдере; клиппинг по окнам,
  которые выше по z (плавающие/меню/Dock), иначе рамка тайлового окна нарисуется поверх них.
- **Скругление 18/2.6**: macOS-окна уже скруглены своим радиусом (у Tahoe больше 18 и другая форма). Для 1:1
  нужна маска слоя окна суперэллипсом r=17 (поверхность) — только в композите (z-загрузка модуля�/правка слоя, 7.10)
  или серверным радиусом угла окна, если он существует и настраивается (не подтверждено; форму Apple
  «continuous corner» сравнить замером с суперэллипсом p=2.6).
- **Тень**: варианты: (а) свой шейдер §5.3 под окном (нужна z-загрузка модуля�); (б) нативная тень окна macOS
  с параметрами под гаусс **σ≈11 pt, смещение (0,10), плотность ~0.91 (=0.467·1.95, clamp)** — z правильный
  автоматически; функция параметров тени на сервере не подтверждена (`CGSSetWindowShadowAndRimParameters` /
  SLS-свойства — проверить). Тень должна быть вырезана под окном (у полупрозрачных — важно).
- **Блюр**: только для окон с прозрачным буфером. Тайловые = блюр **только обоев** (кэш, пересчёт при смене обоев):
  dual-kawase §5.5 по IOSurface окна рабочего стола, σ≈10.4 **логических** pt → на Retina ≈ 10.4×(px/pt) device px
  (у Air ~1.74–2 px/pt), т.е. либо size×2 при тех же passes, либо passes+1 (σ: p3 ≈ 21 px). Затем vibrancy,
  brightness 0.92, noise 0.008. Рисовать ПОД окном (z). Временная замена — серверный блюр фона окна
  (если доступен) с радиусом ~σ — без vibrancy/brightness, не 1:1.
- Альфы декораций и блюра умножаются на fadeAlpha окна (открытие/закрытие/стол).
- Масштаб единиц: Hyprland-px (Linux scale 1) ≡ mac-pt по числам (физически mac-pt на ~15% мельче:
  27" 1440p 109 ppi против Air ~128 pt/дюйм). Предлагается оставлять числа конфига в pt.

### 7.10 Фундаментальная проблема z-порядка и её решение без компромисса
`metalCallbacks` — после всего кадра. Для 1:1 нужны вставки на правильной глубине (тень/блюр под окном,
маска скругления, обрезка содержимого при resize, снимок закрытия, блюр под спец-столом).
Решение (RE, не подтверждено): `CompositorMetal::composite(this, WSCompositeSourceLayer* layers, dest, …)` получает
**список слоёв** (memory: project_windowserver_re). Если разобрать `WSCompositeSourceLayer` (источник-текстура,
src/dst rect, opacity, transform, возможно corner radius/маска), то перед композитом можно:
- менять src-rect слоя окна (обрезка/дотягивание при resize — 7.3 R1),
- вставлять собственные слои (тень/блюр/рамка как текстуры, отрендеренные нами) сразу до/после слоя окна,
- держать слой закрытого окна ещё 260 мс (7.5).
Это «путь Б» — целевой; всё остальное в этом документе работает и без него, но с оговорками z.
Промежуточный способ с правильным z без RE: прозрачные **вспомогательные окна демона** (ignoresMouseEvents),
поставленные прямо над/под окном приложения (order relative to wid — для чужих wid не подтверждено), с их
содержимым (рамка/тень) и тем же трансформом/альфой из WS-кода — синхронно. Ограничение: при resize-анимации
их содержимое нельзя менять покадрово трансформом без искажения толщины рамки → на время resize рисовать
рамку overlay-ем.

### 7.11 Прочие бинды/поведения
- M+Shift+B (balance): в Hyprland — серия фокусов (рамки мигают кроссфейдами) и `splitratio 1` всем родителям →
  каждый setBox ретаргетит drift. У нас достаточно: все ratio=1 разом, одно событие (визуально почти то же; если
  нужен 1:1 — повторить побочные кроссфейды рамок, не нужно по ощущению).
- M+Shift+стрелки: resize по §6.5 (сдвиг разделителя ближайшего сплита на ±60 pt, а не «шире своё окно»),
  repeat, анимация drift.
- maximize/fullscreen: §3.6 — maximize = setBox на рабочую область (drift); fullscreen = на весь экран без рамки
  и скругления, остальные окна гаснут fadeIn-кривой 300 мс.
- polkit dim_around: чёрный 0.4 на весь экран под окном (z!).
- Окна, которые приложение не даёт уменьшить (min-size): Hyprland такие делает плавающими только если maxSize
  меньше слота; min-size тайлового окна он клампит (`misc:size_limits_tiled`, умолч. — не проверял). Наш учёт
  min-size в tile.py — собственная доработка.

---

## 8. Приоритет по заметности для глаза
1. Синхронный drift всех окон при перекладке (open/close/move/resize/togglesplit) — одна t0, одна кривая.
2. Resize-содержимое как в Hyprland (контент сразу финальный, рамка едет, обрезка/дотягивание) — 7.3.
3. Рамка 2 px с градиентом 45° и кроссфейдом 600 мс; неактивная тусклая.
4. Открытие popin 86% с bounce-перелётом 1.2% + fade 300 мс, без мелькания исходного размера.
5. Столы slidefade 12% drift вместо Dock.
6. Закрытие popin 92% snappy 260 мс + fade 240 мс.
7. Скругление 18 суперэллипс p=2.6 (у macOS-окон сейчас другой радиус — заметно на каждом окне).
8. Тень range 34 / offset 10 / cubic (≈гаусс σ11), активная/неактивная.
9. Блюр под прозрачными окнами (kitty-подобные): σ≈10.4 pt, brightness 0.92, vibrancy.
10. Спец-стол dropterm slidefadevert 14% overshot + блюр всего экрана; glow 0.2 у фокусного.

## 9. Расхождения текущего кода с Hyprland (для исправления)
- `hook/config/hyprcfg.py`: неполное дерево `PARENT` (нет fadeGlow, fadePopups*, fadeDpms, shadowangle, glowangle,
  monitorAdded), borderangle не помечен выключенным; палитра — запасная, а не matugen (§1.1).
- `hook/src/anim.c`: крит./передемпф. ветки — Эйлер (у Hyprland аналитика); retarget — «накопление offset»,
  а у Hyprland begun=текущее значение, spring value=0, нормированная скорость сохраняется (§2.5.1);
  время шага — момент после кадра N (лучше — время композита N+1).
- `hook/scripts/tile.py`: move = swap с соседом; у Hyprland — удалить и вставить по фокусной точке (§6.4).
  Вставка нового окна: Hyprland делит **активное** окно, сторону берёт по курсору относительно центра
  делимого бокса (§6.2).
- Ни в одном месте у Hyprland `speed` не влияет на spring — не масштабировать пружины на speed.
