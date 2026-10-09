# П8: анимация закрытия по снимку для любого закрытия окна — рецепт клона окна

Источник: только статический разбор `cache/sl_dis.txt` (SkyLight, macOS 26.7.1 25G241, arm64e). Живой WS не трогался,
код не менялся. [V] — проверено по листингу (адреса), [H] — гипотеза, проверять живьём (шаги в §7).
Связанные места: MASTER §8.2, §8.4, §9.3 «Снимок закрытия», §11 П8, §10 К4/К15; compositor.md §2.

---

## 0. Коротко

1. Подписка изнутри WS: `WSAddNotificationCallback(paciza(cb), 0x3e9, ctx)`. Колбэк вызывается синхронно, внутри
   `CGXWindow::release_window`, до order-out и до `~CGXWindow`. Повторный вход разрешён: список колбэков
   копируется перед обходом.
2. В колбэке:
   `clone = CreateCloneOfWindow(src, screen_rect_from_rect(src, {0,0,w,h}), PKGWindowGetDisplay(src), true)`.
   Получаем серверное окно (владелец NULL) со статичной копией содержимого, уровень 0x19, на экран оно ещё
   не выставлено (ordered out).
3. Ставим клону уровень источника: `set_level_internal(clone, NULL, src+0x20, src+0x28)`. Дальше по желанию
   добавляем его в Spaces источника (`PKGSpacesAddWindowsWithConnection`) и выводим на экран прямо над
   источником: `CGXOrderWindow(NULL, clone_wid, 1, src_wid)`. Источник WS уберёт сам — через несколько
   инструкций после нашего возврата.
4. Клоном движок управляет как обычным окном по wid: трансформ — `CGXSetWindowTransform3DList`, альфа —
   `CGXSetWindowListAlpha`.
5. Освобождение по образцу Apple (`DeallocateItem`): снять бит 54 в `clone+0x928`, затем
   `release_window(*(clone+0x30) /*NULL*/, clone)`. Без снятия бита 54 `release_window` окно НЕ уничтожит,
   а только обнулит ему владельца.
6. Главная неизвестная [H]: бывает ли окно приложения при Cmd+W ещё на экране в момент 0x3e9, или AppKit
   убирает его раньше отдельным OrderWindow. Флаг «на экране» лежит в бите 44 поля `win+0x928`. Если
   окажется, что раньше, нужен перехват момента order-out: событие 0x3ee из `start_order_window` с
   добыванием `CGXWindow*` и op из кадров стека (точные смещения в §4.3, путь Б).
7. 0x538 не подходит: его шлют только при чужом (не владельца) упорядочивании в особом режиме сессии (§4.2).

---

## 1. `CreateCloneOfWindow` — 18709e984 (static `__ZL19CreateCloneOfWindowP9CGXWindow6CGRectPK10PKGDisplayb`)

### 1.1 Аргументы [V 18709e9c4–18709e9e0]
| рег. | смысл |
|---|---|
| x0 | `CGXWindow* src`; при NULL сразу возвращает NULL (`cbz x0` → 18709eacc) |
| d0–d3 | `CGRect frame` (HFA в d0–d3, отдельно от x-регистров) — **экранная рамка в глобальных pt** (см. 1.2) |
| x1 | `const PKGDisplay*`, нужен только чтобы взять bounds и по ним выбрать WS-дисплей |
| w2 | `bool server_owned`: бит 0 = 1 → владелец NULL; 0 → владелец `*(src+0x30)` (соединение приложения) [V 18709eac0–18709ead4] |

Возвращает `CGXWindow*` нового окна или NULL [V 18709ed64].

### 1.2 Координаты рамки [V]
- `frame` передаётся в `CGRegionCreateWithRect` и далее в `WSWindowCreate(owner, 3, region, 0x3800)`
  [V 18709eaec–18709eb04]. Значит, это форма окна в глобальных экранных координатах, тех же, что
  `bbox(win+0x170)` у движка (`actual()`).
- Тот же `frame` уходит в `CreateCaptureSurface` [V 18709ec24–18709ec30], т.е. снимается именно эта
  область экрана.
- Образец Apple, `CreateClonedContentForItem` [V 18709f6b0–18709f6c4]: `r = CGRegionGetBoundingBox(win+0x170)`,
  затем `r.origin = 0,0` (`movi v0/v1 = 0`, размер остаётся), затем `CGXWindow::screen_rect_from_rect(win, r)`.
- `screen_rect_from_rect` (187060038) = `CGXCreateScreenContentShapeForContentShape(win, region(r), 0)` → bbox.
  Внутри учитывается `WSWindowGetTransform`/`WSWindowGetSystemTransform` и mesh [V 186f2d55c–186f2d580].
  Вывод: передаётся рамка окна в его собственных координатах (от 0,0), на выходе — экранная рамка с учётом
  текущего трансформа. Для покоящегося окна (identity) это совпадает с `bbox(win+0x170)`. Для окна, которое
  наш движок как раз анимирует, получится видимая (трансформированная) рамка, и клон встанет туда, где окно
  видно. Делать как Apple.

### 1.3 Дисплей [V]
- Внутри [V 18709e9e4–18709ea64]: `PKGDisplayGetBounds(display)` → `WS::Displays::Manager::display_with_options(
  CAManager, 1, bounds)`. Если результат NULL — запасной путь `CAManager vtable+0xa0` (главный дисплей). Если
  и он NULL — `assert("display != nullptr")` @18709ed94, то есть падение WS. Поэтому передавать надо только
  настоящий PKGDisplay.
- Из выбранного дисплея берутся: `vtable+0x60` (id в `capsurf+0x7c`), `vtable+0x530` (Compositor*),
  `vtable+0xa0` (scale → `WSWindowSetResolution`), `vtable+0x320` (CGColorSpace).
- Как получить дисплей для окна: **`PKGWindowGetDisplay(src)`** 186e481a8 (экспорт) [V]. Сначала пробует
  `window_lookup_first_active_managed_space_display(win)`, потом
  `managed_display_for_pkg_display(window_lookup_best_pkg_display_for_geometry(win))->+0x10`, в крайнем
  случае сам `best_pkg_display_for_geometry`. Статус-бар использует
  `PKGManagedSpaceGetDisplay(space) ?: PKGDisplayGetMain()` [V 18709f690–18709f698]. Наш запасной вариант —
  `PKGDisplayGetMain()` (14acd0). Перед вызовом клона проверять, что дисплей не NULL.

### 1.4 Что делает с новым окном [V 18709eb08–18709ed3c]
1. `WSWindowCreate(owner, 3, CGRegion(frame), 0x3800)`. Внутри шлётся локальное 0x3e8 @187069974 — наш
   колбэк 0x3e8 (если он есть) получит это окно.
2. `win+0x928 |= 1<<54` (`orr #0x40000000000000`). Это тот же бит, что байт `0x92e` бит 6, который
   проверяет `release_window` @18705aa74–18705aa78 → см. §2.3.
3. Уровень: если `win+0x20 != 0x19`, то `CGXWindow::set_level_internal(win, NULL, 0x19, (short)win+0x28)`,
   т.е. уровень status (25).
4. `WSWindowSetTitle(win, <строка>)`, затем `set_window_list_tags(owner, &win, 0x0001400000010200, 0)` —
   биты 9, 16, 46, 48. Расшифровка [H]: бит 9 — «не принимает события», остальные — служебные Apple.
5. `WSWindowSetDepth(4)`, `WSWindowSetHasAlpha(1)`, `WSWindowInternalSetSharedState(0)`,
   `WSWindowSetResolution(scale)`.
6. `Compositor vtable+0xa0` = `CreateCaptureSurface(frame, 0, 0, 4, scale, 1, colorspace, 1, 0)`. Если вышел
   NULL — `WSSystemWindowRelease(win)`, лог, возврат NULL [V 18709edd8–18709ee28]. **Вывод: NULL-результат
   — штатный исход, его надо проверять.**
7. `CGXWindowArrayAppend(arr, src)` → `capsurf vtable+0x38` = `CaptureSurfaceMetal::Populate(список{src},
   WSWindowGetShape(new), &out, opts 0x1201, …)`. Вызов синхронный: содержимое src кодируется в
   IOSurface клона прямо в этом вызове. Исполнение GPU асинхронно, но идёт в той же очереди компоновщика
   раньше следующего кадра [H].
8. `WSWindowSetCapturedContent(new, capsurf)`: просто `new+0x8b0 = capsurf` без retain [V 187073284].
   Ссылку освобождает `~CGXWindow` (читает `+0x8b0` @ строка листинга 898886).
   **Клон НЕ выводится на экран** — внутри нет ни одного вызова order. Окно рисуется обычным путём WS для
   окна с captured content (`generate_layers_for_window` читает `+0x8b0` @186e1a6d4 и учитывает
   `CGXIsTransformedWindow` @186e1a714 → трансформ к клону применяется) [V частично, H для итоговой картинки].

wid клона = `*(u32*)clone`: так его читают `release_window` (`ldr w8,[x19]`) и `swap_cloned_status_item…`
(`ldr w8,[x23]`). Надёжнее брать `WSWindowGetID(clone)` 18705fa18 (экспорт), так же поступает
`pkg_tile_entry_replace_with_snapshot` @186e3d2a8.

### 1.5 Что Apple делает с клоном дальше
- `CreateClonedContentForItem` 18709f65c [V]: клон кладётся в `item+0xe0`, уровень источника копируется
  прямой записью `clone+0x20 = src+0x20` (`ldr w8,[x8,#0x20]; str w8,[x0,#0x20]`) — пока клон не на экране.
  Вызывается из `PKGSystemStatusBarPrepareToUnregisterWindow` (блок @18709f700): это тот же сценарий
  «окно уходит — снять снимок заранее».
- `swap_cloned_status_item_for_removal_animation` 187098f14 [V]: клон становится отдельным item'ом.
  Дальше: `set_window_list_tags`, `PKGWindowSetAbsoluteSubLevel(owner, clone, -1)`,
  `set_window_list_system_alpha`, `MoveStatusItemToSpace` → `PKGSpacesAddWindowsWithConnection({space},
  {clone}, CGXWindowGetOwner(clone))` @18709d02c, затем анимация ухода.
- Освобождение — `DeallocateItem` 187099840–18709986c [V]:
  ```
  PKGWindowAnimationPop(clone);
  if (clone->flags928 & (1ull<<54)) { clone->flags928 &= ~(1ull<<54); CGXWindow::release_window(clone->owner /*+0x30*/, clone); }
  ```
- Полный образец «снимок → на экран» — `pkg_tile_entry_replace_with_snapshot_for_connection` 186e3cd4c [V]:
  тот же `WSWindowCreate(…,3,…,0x3800)` + Populate. Дальше `WSConnectionDisableUpdateInternalToken(conn)`
  или `WSDisableUpdateInternalToken()` → `PKGSpacesAddWindowsWithConnection({space,0},{snap,0},conn)` →
  `CGXOrderWindowListSpaceSwitchOptions(conn, [snap_wid], [1], [0], 1, 0)` (над всеми в своём уровне) →
  `PKGSpacesRemoveWindowsWithConnection(…)` → `Reenable…Token`. Этот образец Apple вызывает из
  `pkg_tile_entry_owner_died` 186e3cd2c, т.е. при смерти соединения-владельца. Значит, создавать и
  выставлять окно-снимок во время разрушения соединения — штатный для WS путь.
- Apple откладывает освобождение снимков: `deferred_release_window(void* wid, double)` 186e3c5f4 =
  `window_by_id(wid)` → `release_window(win->owner, win)`. Мы делаем то же из тика.

---

## 2. Уровень, порядок, освобождение

### 2.1 Уровень [V]
`CGXWindow::set_level_internal(CGXWindow*, CGXConnection* /*NULL*/, int level, short sublevel)` 18705d328.
Ровно так её зовёт сам клон: x1=0, w2=уровень, w3=`ldrsh [win,#0x28]` @18709eb38–18709eb48. Для клона:
`set_level_internal(clone, 0, *(int*)(src+0x20), *(short*)(src+0x28))` — до вывода на экран.

### 2.2 Порядок [V]
`CGXOrderWindow(CGXConnection* conn, u32 wid, int op, u32 relwid)` 18705d11c (экспорт). Это обёртка над
`CGXOrderWindowListSpaceSwitchOptions(conn, &wid, &op, &rel, 1, 0)`.
- Допустимые op: 1 (над), −1 (под), 0 (убрать); прочие → ошибка 0x3e9 [V 18705b060–18705b078].
- conn = NULL допустим: так выставлены угловые окна (`create_corner_window` @187149c50: x0=0, op 1, rel 0),
  и так же `DeallocateItem` (владелец клона = NULL). У окна с owner NULL проверки прав пропускаются
  (`ldr x10,[x28,#0x30]; cbz x10 → разрешено` @18705b010–18705b014).
- Наш вызов: `CGXOrderWindow(NULL, clone_wid, 1, src_wid)` — сразу над исходным, пока оно ещё на экране
  (в 0x3e9 order-out исходного ещё впереди, @18705ab78). Затем WS убирает исходное, клон остаётся на его
  месте в стопке. [H] относительное упорядочивание внутри уровня при равных уровнях — проверить живьём.
- Spaces [H, образец V]: в тайловом и статус-барном образцах Apple перед выводом на экран добавляет окно
  в Space: `PKGSpacesAddWindowsWithConnection(x_list* spaces, x_list* windows, CGXConnection* conn)`
  186e3a814, узлы `{void* data; void* next;}`. Список Spaces источника: `**(src+0x248)` (так читает
  `WSWindowCopySpaceList` @186ea377c–186ea3780). Безопаснее собрать свой узел из первого элемента:
  `{ (*(x_list**)(*(void**)(src+0x248)))->data, NULL }`. Без добавления клон, скорее всего, ведёт себя как
  угловые окна (виден на любом Space); на 260 мс это приемлемо. Шаг 2 в §7 решит, нужен ли он.
- Атомарность: внутри 0x3e9 ничего не нужно. Колбэк, вывод клона и order-out исходного выполняются
  подряд в одном обработчике главного потока (`__XTerminateWindow` @1871b6610 / `connectionDeallocate`)
  до следующего `UpdateDisplays` [H, сильная]. При выходе приложения весь цикл освобождения окон и так
  обёрнут в `WSConnectionDisableUpdateInternalToken`/`Reenable…` [V 186f4f360, 186f4f434]: все клоны
  появятся в одном кадре.

### 2.3 Освобождение [V]
- Владелец клона при `server_owned=true` — NULL (сервер). `connectionDeallocate` ищет окна, принадлежащие
  умирающему соединению [V 186f4f3f0–186f4f418], и клон не найдёт. При `server_owned=false` клон
  принадлежал бы приложению и был бы уничтожен вместе с ним, поэтому **только true**.
- Бит 54 (`win+0x928`, он же байт `0x92e` бит 6) в `release_window` @18705aa74: если бит стоит, окно НЕ
  уничтожается, а уходит в `set_owner(win, NULL)` (хвост @18705abd0). Клон рождается с этим битом.
  Порядок освобождения (как в `DeallocateItem`):
  ```c
  *(u64*)(clone+0x928) &= ~(1ull<<54);
  release_window(*(void**)(clone+0x30) /* = NULL */, clone);
  ```
  Внутри: 0x3e9 для клона (колбэк должен его отфильтровать, §3.4) → `CGXPostWindowNotification(0x324)`
  → order-out (если бит 44 «на экране» стоит) с conn=NULL → `~CGXWindow` → free.
- `release_window(NULL, win)` для окна с владельцем NULL — штатный путь Apple (`DeallocateItem`,
  `deferred_release_window`).
- Указатель на клон между тиками не хранить как единственную ссылку. В тике брать `by_id(clone_wid)`:
  окно могли снести при перестройке дисплеев. `WSCompositorDestroyAllTextures` @строки 432176–432185
  обнуляет `+0x8b0` — клон станет пустым, но останется жив.

---

## 3. `WSAddNotificationCallback` / `WSRemoveNotificationCallback`

### 3.1 Сигнатуры [V]
- `void WSAddNotificationCallback(cb, u32 type, void* ctx)` 186e743d4: x0=fn, w1=type, x2=ctx.
  Хранилище — `unordered_map<u32 type, vector<Callout{fn, ctx}>>` из `get_server_notifier()`. Новая
  запись вставляется **в начало** вектора (`stp x20,x19,[x23]` при x23=begin, @186e74928). **Повторы не
  проверяются**: две регистрации дадут два вызова. Лимита нет (vector).
- `void WSRemoveNotificationCallback(cb, u32 type, void* ctx)` 186e74950 удаляет первую запись с точным
  совпадением пары (fn, ctx) [V 186e74a30–186e74a7c]. fn сравнивается как есть, т.е. как подписанное
  значение. paciza детерминирован, поэтому то же значение снимает регистрацию. Образец Apple: перед add
  делается remove той же пары (`pkg_tile_entry_set_tile_window` @186e3c38c–186e3c3c0).
- Колбэк вызывается так: `blraaz x8` с x0=type, x1=data, x2=len (u64, assert ≤ UINT32_MAX), x3=ctx
  [V 186e72c78–186e72c88]. **Указатель обязан быть подписан ключом IA с нулевым дискриминатором
  (paciza)**, иначе падение WS на аутентификации. Apple регистрирует ровно так: `paciza x16` @186e3c3b0.
  Наш `install4.py: sign(addr)` = `__builtin_ptrauth_sign_unauthenticated(p, 0 /*IA*/, 0)` — то, что нужно.
- Прототип для C: `void cb(u32 type, void *data, unsigned long len, void *ctx)`.

### 3.2 Синхронность и поток [V/H]
- `WSPostLocalNotification` 186e725d4 → `ordered_callback_record_stack_push` → `invoke_callbacks` →
  `…_pop` → `post_enqueue`/`post_response` колбэки. Вызов **синхронный**, в потоке отправителя.
- 0x3e9 шлёт `release_window`. Её вызывают MIG-обработчики (`__XTerminateWindow`), `connectionDeallocate`,
  `UpdateDisplays` (окно Sarlacc), служебные пути статус-бара, меню, углов и PiP. Всё это главный поток WS
  [H, сильная: в WS это один runloop].
- **Повторный вход [V]:** `invoke_callbacks` копирует вектор Callout во временный буфер (`memmove`
  @186e72c6c) и обходит копию. Поэтому внутри колбэка безопасно: слать вложенные уведомления (0x3e8 из
  `WSWindowCreate`, 0x3ee/0x3ea из упорядочивания), вызывать add/remove, вызывать `release_window` другого
  окна. Последнее делает сам Apple: `deferred_release_window` и статус-бар внутри цепочек
  освобождения/обновления.

### 3.3 ctx
Любой указатель, передаётся колбэку четвёртым аргументом как есть. У Apple это `PKGTileEntry*`. У нас —
`struct ctx*` движка.

### 3.4 Фильтры в колбэке (обязательные)
- `c->dead` → сразу return (старый образ остаётся в памяти после переустановки, §4.4).
- `type != 0x3e9 || !data || len != 8` → return.
- `owner = *(void**)(win+0x30)`: NULL → return. Так отсекаются наши клоны (их собственное освобождение
  шлёт 0x3e9), окна Sarlacc, угловые и прочие серверные окна.
- Уровень `*(int*)(win+0x20) != 0` → return (только обычные окна приложений). [H] Окна-панели можно
  добавить позже.
- `!(*(u64*)(win+0x928) >> 44 & 1)` (окно не на экране) → return и записать в журнал (это ответ на главный
  вопрос §0 п.6). Этот же бит `release_window` проверяет перед order-out @18705ab4c–18705ab50.
- Окно должно вести движок/демон (есть слот `ch_win` с `geo=1`) и стоять на текущем Space (§5).
- Слот уже гаснет (`alpha.g[0] < 0.05` или `cur_alpha < 0.05`) → return: это `close_anim` демона (M+Q),
  он уже показал уход.
- Флаг повторного входа `c->in_cb`: если колбэк вызван изнутри собственного клонирования, выходить.

---

## 4. Другие события и путь Б

### 4.1 Места отправки локальных событий окна [V, полный перебор `mov w0,#… ; bl _WSPostLocalNotification`]
| тип | где | data |
|---|---|---|
| 0x3e8 | `WSWindowCreate` @187069974 | новое окно |
| 0x3e9 | `release_window` @18705ab18 | `CGXWindow*`, len 8 |
| 0x3ee | `start_order_window` @18705bbcc | **NULL**, len 0 — на каждое окно каждой операции упорядочивания, ДО её применения |
| 0x3ea | `finish_order_windows` @18705c0e0 | NULL |
| 0x538 | `finish_order_windows` @18705c1b8 | `{u32 wid, u32 op, u32 rel_wid}`, len 12 |
| 0x3eb | `~CGXWindow` @1870590a4 | поздно: контента уже нет |

### 4.2 Почему не 0x538 [V 18705c124–18705c1c0]
0x538 шлётся только при одновременном выполнении условий: флаг w22 (передан в `finish_order_windows`);
соединение-упорядочиватель ≠ владелец окна (и ≠ `+0x40`); бит 5 в `session->+0xb0->+0x18` и ненулевое
`+0x14`; `window_by_id(...)` второго окна = 0. Это особый режим сессии, а не обычное закрытие. Для П8
событие бесполезно. Поля, когда оно всё же приходит: `[0]=wid` (`ldr w9,[x28]`), `[1]=op` (запись
`+0x18`), `[2]=wid relative`.

### 4.3 Путь Б: момент order-out через 0x3ee [V смещения, H применимость]
Если шаг 1 в §7 покажет, что при Cmd+W окно в 0x3e9 уже не на экране (бит 44 = 0), снимок надо делать при
order-out. 0x3ee не несёт данных, но приходит до применения операции. `CGXWindow*` и op лежат в
сохранённых регистрах кадров стека:
- `start_order_window` @18705bbc4–18705bbc8: `x19 = state->win`, `w24 = state->op` (+0x18), затем 0x3ee.
- `WSPostLocalNotification` (пролог 186e725d4: `stp x22,x21,[sp,#-0x30]!; stp x20,x19,[sp,#0x10];
  stp x29,x30,[sp,#0x20]; add x29,sp,#0x20`) сохраняет x19 вызывающего по адресу `fp_post − 0x8`.
- `invoke_callbacks` (пролог 186e72b78: `stp x24,x23,[sp,#-0x40]!; …; add x29,sp,#0x30`) сохраняет x24 по
  адресу `fp_ic − 0x30`. Ни `WSPostLocalNotification`, ни push/get_server_notifier x24 не меняют (callee-saved).
- Цепочка в колбэке:
  ```c
  void **fp = __builtin_frame_address(0);
  void **fp_ic = fp[0];            // кадр invoke_callbacks;  fp[1] (без PAC) == 0x186e72c8c+slide
  void **fp_post = fp_ic[0];       // кадр WSPostLocalNotification; fp_ic[1] == 0x186e7260c+slide
  /* fp_post[1] (без PAC) == 0x18705bbdc+slide — возврат в start_order_window */
  void *win = *(void **)((char *)fp_post - 0x8);
  int op = *(int *)((char *)fp_ic - 0x30);
  ```
  Перед использованием сверять все три адреса возврата (снять PAC через `xpaci`; ожидаемые значения с
  учётом slide кладёт установщик в ctx). При любом несовпадении ничего не делать. Колбэк надо собирать с
  frame pointer (на Darwin это по умолчанию; `-fno-omit-frame-pointer` для верности).
- Минус пути Б: order-out бывает не только при закрытии (Cmd+H, вкладки AppKit, `orderOut:` панелей). Клон
  выставляется сразу и стоит неподвижно; анимация стартует, только если в течение ≤50 мс приходит 0x3e9
  того же wid. Иначе клон освобождается в следующем тике. Для вкладок это мигание новой вкладки под
  клоном на 1–3 кадра. Поэтому путь Б — только если путь А не работает.

### 4.4 Жизненный цикл регистрации и переустановка движка
- `install4.py` не освобождает старый образ (`mmap` остаётся), только ставит `ctx.dead=1`. Колбэк старого
  образа останется зарегистрированным, пока его не снимут. Поэтому:
  - регистрировать и снимать **из тика** (главный поток), а не из lldb: `ev()` выполняется, пока процесс
    остановлен, и может попасть на поток посреди работы с `unordered_map` нотификатора;
  - в тике при `c->dead || h->stop` перед `return`: снять регистрацию (`rm_cb(cb, 0x3e9, c)`) и освободить
    все живые клоны;
  - в колбэке первая строка — `if (c->dead) return;`. Даже если старый тик больше не запустится, старая
    регистрация безвредна: код в памяти, колбэк сразу выходит.
- Двойной регистрации не допускать: флаг `c->cb_on`, плюс remove перед add, как у Apple.

---

## 5. Ловушки

| случай | что будет | что делать |
|---|---|---|
| Окно уже не на экране в 0x3e9 (AppKit сначала OrderWindow, потом TerminateWindow) | Populate по невидимому окну [H: вероятно, пусто или старый кадр]; если клон выставить, «воскреснет» уже исчезнувшее окно | фильтр «бит 44 = 0 → пропуск + журнал»; при массовом пропуске — путь Б (§4.3) |
| Sheet/дочерние окна | каждое — отдельный CGXWindow со своим 0x3e9 и своим клоном, у каждого свой центр popin; Populate берёт только `{src}` | клонировать только окна уровня 0 с geo-слотом (sheet в раскладке демона не участвует) [H]; собирать группу в один снимок значит переписать CreateCloneOfWindow со списком в Populate — не в этой итерации |
| Окно без CA-контента (legacy) | Populate работает со списком CGXWindow, не с CA-деревом; путь `generate_layers_for_window` рисует оба вида [H] | проверить живьём на legacy-окне; при пустом клоне просто освободить |
| Окно другого Space | клон окажется на экране без Space (как угловые окна) — призрак на текущем столе | пропускать, если `window_lookup_first_active_managed_space_display(src)` (static 186e318fc) = NULL [H семантика: «окно в активном managed space»], или по данным демона (текущий Space) |
| Выход приложения целиком | `connectionDeallocate` освобождает окна по одному [V], 0x3e9 на каждое, обновления экрана выключены токеном → все клоны появятся одним кадром. Но CA-контексты умершего процесса могут быть уничтожены раньше (`_connectionDied` → `CARenderContextDestroy`, если нельзя zombify @187089470–187089488) — клон пустой [H] | проверять, что клон не пустой, нельзя дёшево; на худой конец пустой клон даёт ту же картину, что сейчас. Ограничить число клонов за пачку (≤8) — каждый Populate тратит GPU и память размером с окно ×scale² |
| Падение приложения | то же, что выход; zombify-контекст может дать последний кадр | — |
| `close_anim` демона (M+Q) | окно уже погашено до альфы 0 к моменту `ws_close` → клон был бы невидимым или вернул бы окно на кадр | фильтр «слот гаснет / cur_alpha < 0.05» (§3.4); демону — не трогать клоны |
| Наши клоны в сканере новых окон `anim_tick` | у клона растущий wid → `EV_NEW`, демон начнёт его тайлить | в сканере: `owner == NULL` → не слать EV_NEW (или слать `EV_CLONE`); демону — игнорировать окна без pid |
| Собственный 0x3e9 при освобождении клона | колбэк вызовется на нашем же клоне | фильтр `owner == NULL` |
| Трансформ клона | ключ `c->key` в `set_xform` у клона свой (по wid); у окна с captured content трансформ учитывается в `generate_layers_for_window` [V частично] | проверить шагом 3 |
| Маска/рамка/клип движка у клона | `border_win` требует `geo` и CA-дерево (`win+0x18`) — у клона `geo=0`, выйдет; `put_mask` проверяет `cwc` | слот клона: `stretch=1`, `geo=0`, `under=0`, `fill=0`; клип не ставить |
| Ожидание размера у слота клона | A клона не меняется → после конца анимации движок будет ждать settle | освобождать клон по признаку `!pos.active && !size.active && !alpha.active`, не по EV_SETTLED; страховочный таймаут 2 с |
| Сбой `CreateCaptureSurface` | функция сама освобождает окно и возвращает NULL [V] | проверять NULL |
| Переустановка/остановка движка во время анимации | клоны висели бы навсегда (владелец — сервер) | на `dead/stop` освобождать все клоны из таблицы ctx |
| Стоимость в колбэке | WSWindowCreate + IOSurface + Populate ≈ доли мс… единицы мс [H] на главном потоке WS | мерить `mabs()` в колбэке, писать в журнал |

**Что нельзя звать в колбэке 0x3e9:**
- `release_window` для **src** (повторное освобождение того же окна);
- order-out для **src**;
- `WSCAContextScopeTransaction` для src: его CA-контекст сейчас разбирается [H];
- всё долгое: полный тик, `deco`, ObjC.

Можно (есть прецеденты Apple, §1.5/§3.2): создать окно, Populate, `set_level_internal`, `CGXOrderWindow`,
`PKGSpacesAddWindowsWithConnection`, add/remove колбэков, `CGXSetWindowListAlpha`/трансформ клона,
`release_window` **другого** окна.

---

## 6. Рецепт

### 6.1 Добавления в `struct ctx` (anim4.c)
Хвост ctx сейчас 0x280 (`sched_win`; файл параллельно правят — сверить перед вставкой). Новые поля
начинать с 0x300, таблицу клонов — с 0x800 (ctx — 16 КБ mmap):

```c
// П8: клоны закрытия (close_clone.md)
typedef void *(*clone_fn)(void *src, rect frame, const void *pkgdisp, int server_owned);  // d0–d3 = frame (HFA), x1, w2
typedef rect  (*srr_fn)(void *win, rect r);                                                // CGXWindow::screen_rect_from_rect
struct ctx_p8 {                     // ctx + 0x300
    clone_fn clone;                 // 0x300 __ZL19CreateCloneOfWindowP9CGXWindow6CGRectPK10PKGDisplayb
    srr_fn   srr;                   // 0x308 __ZNK9CGXWindow21screen_rect_from_rectE6CGRect
    void  *(*win_disp)(void *win);  // 0x310 PKGWindowGetDisplay
    void  *(*main_disp)(void);      // 0x318 PKGDisplayGetMain
    void   (*set_level)(void *win, void *conn, int lvl, short sub);   // 0x320 __ZN9CGXWindow18set_level_internalEP13CGXConnectionis
    void   (*order)(void *conn, unsigned wid, int op, unsigned rel);   // 0x328 CGXOrderWindow
    void   (*rel_win)(void *conn, void *win);                         // 0x330 __ZN9CGXWindow14release_windowEP13CGXConnectionPS_
    void   (*add_cb)(void *fn, unsigned type, void *ctx);             // 0x338 WSAddNotificationCallback
    void   (*rm_cb)(void *fn, unsigned type, void *ctx);              // 0x340 WSRemoveNotificationCallback
    void    *cb;                    // 0x348 sign(code + syms["anim_will_release"]) — IA/0
    unsigned (*get_id)(void *win);  // 0x350 WSWindowGetID
    void   (*spaces_add)(void *spaces, void *wins, void *conn);       // 0x358 PKGSpacesAddWindowsWithConnection (опц.)
    void  *(*on_active)(void *win); // 0x360 __ZL48window_lookup_first_active_managed_space_displayP9CGXWindow (опц.)
    u32 cb_on, in_cb;               // 0x368
    u32 nclone, stat_skip_off;      // 0x370 счётчики (журнал)
    u64 ret_ic, ret_post, ret_sow;  // 0x378.. адреса возврата для пути Б (+slide), 0 — путь Б выключен
};
struct p8_clone { u32 wid, src; double t0; u32 live, pad; };   // ctx + 0x800, 32 шт.
```

Настройки закрытия — от демона в `ch->h.reserved[0..3]` (размер структуры канала не меняется; MAGIC оставить,
`version` поднять): `reserved[0]` = on | curve windowsOut <<8 | curve fadeOut <<16; `reserved[1]` = double
длительность размера, с; `reserved[2]` = double длительность альфы, с; `reserved[3]` = double k popin (0.92).

### 6.2 Колбэк (путь А)

```c
void anim_will_release(u32 type, void *data, unsigned long len, struct ctx *c) {
    struct ctx_p8 *p = (struct ctx_p8 *)((char *)c + 0x300);
    if (c->dead || type != 0x3e9 || !data || len != 8 || p->in_cb) return;
    struct ch *ch = c->ch;
    if (ch->h.magic != CH_MAGIC || ch->h.stop || !(ch->h.reserved[0] & 1)) return;
    char *src = data;
    if (!*(void **)(src + 0x30)) return;                       // серверное окно / наш клон
    if (*(int *)(src + 0x20) != 0) return;                     // только обычный уровень
    if (!((*(u64 *)(src + 0x928) >> 44) & 1)) { p->stat_skip_off++; return; }   // уже не на экране (журнал!)
    unsigned swid = *(unsigned *)src;
    struct ch_win *sw = slot(ch, swid, 0);
    if (!sw || !sw->geo) return;                               // не наше окно
    if (sw->alpha.g[0] < 0.05 || sw->cur_alpha < 0.05) return; // close_anim демона уже погасил
    if (p->on_active && !p->on_active(src)) return;            // не на активном Space [H]
    p->in_cb = 1;
    rect a = c->bbox(*(void **)(src + c->shape_off));
    rect fr = p->srr(src, (rect){0, 0, a.w, a.h});
    void *disp = p->win_disp(src);
    if (!disp) disp = p->main_disp();
    char *cl = disp ? p->clone(src, fr, disp, 1) : 0;
    if (cl) {
        p->set_level(cl, 0, *(int *)(src + 0x20), *(short *)(src + 0x28));
        unsigned cwid = p->get_id(cl);
        // опц.: { void *sp = *(void **)(src+0x248); x_list *l = sp ? *(x_list **)sp : 0;
        //         if (l) { x_list s = {l->data, 0}, w = {cl, 0}; p->spaces_add(&s, &w, 0); } }
        p->order(0, cwid, 1, swid);                            // над исходным; исходное WS сейчас уберёт
        // слот клона: стартует сразу (t0 = now), как close_anim демона
        struct ch_win *w = slot(ch, cwid, 1);
        if (w) {
            double now = ch->h.now;                            // время прошлого тика; точнее — SLSCurrentRealTime
            double k = *(double *)&ch->h.reserved[3];
            double cur[4] = {fr.x, fr.y, fr.w, fr.h};
            double to_p[2] = {fr.x + fr.w * (1 - k) / 2, fr.y + fr.h * (1 - k) / 2}, to_s[2] = {fr.w * k, fr.h * k};
            u32 cs = (ch->h.reserved[0] >> 8) & 0xff, ca = (ch->h.reserved[0] >> 16) & 0xff;
            warp(&w->pos, 2, cur); warp(&w->size, 2, cur + 2);
            w->ax = fr.x; w->ay = fr.y; w->aw = fr.w; w->ah = fr.h;
            w->stretch = 1;
            retarget(ch, &w->pos, 2, to_p, cs, *(double *)&ch->h.reserved[1], now);
            retarget(ch, &w->size, 2, to_s, cs, *(double *)&ch->h.reserved[1], now);
            double z[1] = {0.0};
            retarget(ch, &w->alpha, 1, z, ca, *(double *)&ch->h.reserved[2], now);
            p8_add(c, cwid, swid, now);                        // таблица ctx+0x800
        } else p8_free_now(c, cl);                             // слотов нет — сразу освободить
        post_evt(ch, EV_GONE, swid, ch->h.now, 0, 0, 0, 0);    // соседи — в этом же кадре демона
        p->nclone++;
        if (!c->running) c->resched(c->queue, c->self, c, c->session, 1, 1, ch->h.now);  // разбудить тик [H: из колбэка допустимо — это та же постановка в очередь]
    }
    p->in_cb = 0;
}
```

Освобождение (вызывается из тика):
```c
static void p8_free_now(struct ctx *c, char *cl) {
    struct ctx_p8 *p = (struct ctx_p8 *)((char *)c + 0x300);
    *(u64 *)(cl + 0x928) &= ~(1ull << 54);                     // иначе release_window только обнулит владельца
    p->rel_win(*(void **)(cl + 0x30), cl);                      // = NULL; шлёт 0x3e9 → колбэк отфильтрует
}
```

### 6.3 Изменения в `anim_tick`
1. В начале (в ветке `dead/stop/magic`, перед `return`): если `p->cb_on` — `p->rm_cb(p->cb, 0x3e9, c)`,
   `cb_on=0`; освободить все `live`-клоны из таблицы (`by_id(wid)` → `p8_free_now`); `slot_free` их слотов.
2. После чтения команд: если `reserved[0]&1 && !cb_on` → `rm_cb` + `add_cb(p->cb, 0x3e9, c)`, `cb_on=1`;
   если `!(reserved[0]&1) && cb_on` → `rm_cb`, `cb_on=0`.
3. В сканере новых окон: `if (!*(void**)(nw+0x30)) { m = id; continue; }` — серверные окна (в т.ч. клоны)
   не слать как EV_NEW.
4. После цикла `frame_win`: для каждого `live` клона, если `!slot || !(pos|size|alpha).active` или
   `now − t0 > 2.0`, → `win = by_id(wid)`; если `win` есть — `p8_free_now(c, win)`; `slot_free`; `live=0`;
   `post_evt(EV_DONE…)` по желанию.
5. Пока есть живые клоны, `n > 0` (тик продолжается каждый кадр).

### 6.4 install4.py
```python
P8 = 0x300
w64(ctx + P8 + 0x00, sign(sym("_ZL19CreateCloneOfWindowP9CGXWindow6CGRectPK10PKGDisplayb")))
w64(ctx + P8 + 0x08, sign(sym("_ZNK9CGXWindow21screen_rect_from_rectE6CGRect")))
w64(ctx + P8 + 0x10, sign(sym("PKGWindowGetDisplay")))
w64(ctx + P8 + 0x18, sign(sym("PKGDisplayGetMain")))
w64(ctx + P8 + 0x20, sign(sym("_ZN9CGXWindow18set_level_internalEP13CGXConnectionis")))
w64(ctx + P8 + 0x28, sign(sym("CGXOrderWindow")))
w64(ctx + P8 + 0x30, sign(sym("_ZN9CGXWindow14release_windowEP13CGXConnectionPS_")))
w64(ctx + P8 + 0x38, sign(sym("WSAddNotificationCallback")))
w64(ctx + P8 + 0x40, sign(sym("WSRemoveNotificationCallback")))
w64(ctx + P8 + 0x48, sign(code + meta["syms"]["anim_will_release"]))   # paciza: blraaz в invoke_callbacks
w64(ctx + P8 + 0x50, sign(sym("WSWindowGetID")))
w64(ctx + P8 + 0x58, sign(sym("PKGSpacesAddWindowsWithConnection")))
w64(ctx + P8 + 0x60, sign(sym("_ZL48window_lookup_first_active_managed_space_displayP9CGXWindow")))
# путь Б (только если включать): slide = sym("WSPostLocalNotification") - 0x186e725d4
# w64(ctx+P8+0x78, 0x186e72c8c+slide); w64(ctx+P8+0x80, 0x186e7260c+slide); w64(ctx+P8+0x88, 0x18705bbdc+slide)
```
- Имена `sym()` — без ведущего `_` C-уровня, как уже делается для `_ZN9CGXWindow33…`. Static-символы
  (`_ZL…`) есть в таблице SkyLight (sl_syms.tsv, строки 10198 и 11602); lldb `FindSymbols` их находит
  [H — проверить, что `sym()` не падает «нет символа»].
- Регистрацию в lldb **не делать**: её делает тик (§6.3 п.2).
- Снятие старой установки: достаточно `dead=1` (уже есть). Старый тик снимет регистрацию сам, а старый
  колбэк до того выходит по `dead`.
- `build_anim4.sh` проверит, что `anim_will_release` экспортирован (`nm -g` → `syms`). Функция не static.

### 6.5 Демон (hyprwm.py)
- Писать в `reserved[0..3]` параметры windowsOut/fadeOut/popin (те же, что в `close_anim`) и бит on.
- По EV_GONE от колбэка соседи перестраиваются как сейчас (`apply`) — в том же цикле демона.
- Игнорировать окна без pid (клоны) при снимке окон и тайлинге.
- `close_anim` не менять: фильтр движка по альфе исключает двойную анимацию.

---

## 7. Порядок живой проверки (по одному шагу, со снапшотом журнала)

1. **Только журнал.** Колбэк 0x3e9 пишет в кольцо: wid, бит 44, owner≠0, уровень, есть ли слот, `cur_alpha`,
   время. Плюс колбэк 0x3ee с путём Б в режиме «только читать»: проверка трёх адресов возврата, wid, op. Ничего
   не создавать. Закрыть окна: Cmd+W, красная кнопка, Cmd+Q в Safari/Terminal/Telegram/Finder/Ghostty.
   Ответ: окно ещё на экране в 0x3e9 (путь А) или уже нет (путь Б)?
2. **Клон без анимации.** В 0x3e9 создать клон, выставить, через 1 с освободить из тика. Проверить: клон на
   месте пиксель в пиксель, нет кадра пустоты, уровень над соседями правильный, нет утечки (счётчик окон WS),
   повтор 20 раз. Вариант со `spaces_add` и без — на втором Space.
3. **Трансформ/альфа клона** через существующий слот (`stretch=1`).
4. **Полный popin+fade + EV_GONE**, замер стоимости колбэка (`mabs`), пачка при выходе приложения с 5 окнами.
5. Отрицательные случаи: M+Q демона (не должно быть двойного), окно на другом Space, sheet, Cmd+H (путь А не
   срабатывает — правильно), переустановка движка во время анимации (клоны освобождаются).

---

## 8. Риски (сводка)
1. [H, главный] При Cmd+W окно может быть уже убрано с экрана к моменту 0x3e9 → нужен путь Б по стеку
   (хрупкий, привязан к сборке 25G241, защищён сверкой адресов возврата).
2. Колбэк, оставленный зарегистрированным после выгрузки образа, — падение WS при следующем закрытии. Образ
   не выгружается (mmap остаётся) и колбэк проверяет `dead`; `munmap` старого кода добавлять нельзя, пока
   регистрация не снята.
3. Неподписанный или подписанный не тем ключом указатель колбэка — падение WS на `blraaz`.
4. Без снятия бита 54 клон не уничтожится — утечка серверных окон и IOSurface.
5. `server_owned=false` → клон умрёт вместе с приложением и будет считаться его окном.
6. NULL-дисплей → assert внутри CreateCloneOfWindow (падение WS).
7. Пустой клон при выходе приложения (CA-контекст уже уничтожен) [H] — визуально как сейчас.
8. GPU/память: Populate полного окна на каждое закрытие; при выходе приложения с множеством окон —
   ограничить число клонов.
9. Жёсткие смещения (`+0x20` уровень, `+0x28` подуровень, `+0x30` владелец, `+0x170` форма, `+0x248` Spaces,
   `+0x928` биты 44/54, `+0x8b0`) проверены только на 25G241 — держать в `BUILDS`-защите install4.
