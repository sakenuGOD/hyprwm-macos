# hyprwm-swift — демон тайлинга на Swift (порт `hook/hyprwm.py`, MASTER.md §11 П1а)

Состояние на 2026-10-09: **собирается, юнит- и золотые тесты проходят; вживую НЕ запускался ни разу**
(по правилу безопасности: к живому WindowServer в это время ходил другой агент). Python-демон остаётся
рабочим; `start.sh`/`stop.sh` не менялись.

## Сборка и тесты

```sh
cd ~/Developer/re-tools/hook/swift
swift build -c release          # -> .build/release/hyprwm-swift
swift test                      # 16 тестов, ~5 с; WindowServer/канал/живой сокет не трогают
python3 tools/gen_fixtures.py   # пересобрать фикстуры из REFERENCE_*.py (тоже без WS)
```

Сухие режимы бинарника (без SkyLight/AX/канала/сокета, только чтение файлов):

```sh
.build/release/hyprwm-swift --print-config                          # зазоры, кривые, номера, длительности
.build/release/hyprwm-swift --layout ../hyprwm.state.json 3 0 33 1470 923   # раскладка стола из состояния
```

## Устройство

| Цель SwiftPM | Что | Откуда |
|---|---|---|
| `CChan` | канал демон↔движок | **сам** `hook/src/chanlib.c` и `hook/src/chan.h` через шим `#include "../../../src/…"` — структуры не дублируются |
| `CAX` | configure/фокус/меню + обёртки SkyLight/CG (были ctypes в hyprwm.py) | `hook/src/axlib.c` (шим) + `Sources/CAX/sys.c` |
| `CSnap` | снимок окон | `hook/src/winsnap.m` (шим, ARC) |
| `HyprCore` | вся логика без обращения к системе: dwindle (`Tile.swift`), конфиг (`Config.swift`), демон (`WM.swift`), сокет и очередь configure (`Server.swift`), канал (`Channel.swift`), JSON как у Python | порт `tile.py`, `hyprcfg.py`, `engine.py` (anim/setup), `chan.py`, `hyprwm.py` |
| `hyprwm-swift` | живые реализации (`LiveSys`, `LiveEngine`, `Deco`) и цикл | порт `engine.py` (alive/ensure/install), `deco.py`, `WM.run` |

Эталоны, с которыми сверялся порт (снимок на момент порта): `REFERENCE_hyprwm.py`, `REFERENCE_tile.py`,
`REFERENCE_engine.py`, `REFERENCE_chan.py`. Если Python-демон поменяется — обновить снимки,
`python3 tools/gen_fixtures.py`, `swift test`, и перенести правки.

Связь с системой — только через протоколы `SysAPI` / `EngineAPI` / `ChannelAPI` / `DecoAPI` / `ConfigureSink`
(`Interfaces.swift`); тесты подставляют подделки.

### Целевая архитектура (fable_plan §2.1–2.2): что сделано, что нет

- **Один владелец состояния** — объект `WM`, живёт только на главной очереди. Потоков, трогающих состояние,
  нет: ответ configure приходит событием на главную очередь (`cfgQ` + сразу такт), а не через общую очередь
  из чужого потока, как в Python.
- **configure**: последовательная `DispatchQueue` на приложение, «последняя цель побеждает» (серийный номер),
  промежуточные цели пропускаются (`Configurer`, проверено тестом).
- **Команды — сразу**: `DispatchSource` на сокете будит такт в момент подключения; все ждущие подключения
  забираются за раз (P42).
- **Активация приложения** (`NSWorkspace.didActivateApplication`) — внеочередной такт.
- **Одна пачка на событие** — как в Python (`apply` -> один `commit`).
- **НЕ сделано (осталось опросом, как в Python):** кольцо событий движка и снимок окон по-прежнему читаются в
  такте 16 мс (таймер вместо `select`), гейт снимка Q2 тот же. Подписки `SLSRegisterConnectionNotifyProc`,
  `AXObserver` — это П2, не П1а. Явного автомата IDLE/OPENING/MOVING/CLOSING/HIDDEN/FLOAT тоже нет: состояние
  окна, как в Python, лежит в множествах `newbies/optimistic/restoring/closing/hidden/floating` — но теперь у
  одного владельца на одной очереди. Сознательно: сначала 1:1 по поведению (проверяемо тестами), потом автомат.

## Переменные окружения

| Переменная | По умолчанию | Смысл |
|---|---|---|
| `HYPRWM_STATE_DIR` | `/tmp/hyprwm-swift` | где `hyprwm.state.json` и `minsize_app.json`. **По умолчанию НЕ файлы Python-демона**, чтобы случайный запуск их не перетёр. Для замены Python — `HYPRWM_STATE_DIR=$H` |
| `HYPRWM_CTL` | `/tmp/hyprwm.ctl` | сокет команд (протокол тот же: строка -> строка ответа) |
| `HYPRWM_HOOK` | ищется вверх от бинарника по `config/hypr_shim.lua` | каталог `hook/` (anim4.bin, run_lldb.sh, build/hyprdeco, config/) |
| `HYPRWM_TIME_SCALE`, `HYPRWM_HOLD`, `HYPRWM_DEBUG` | как у Python | |
| `HYPRWM_NO_DECO=1` | — | не запускать `build/hyprdeco` |

Каталог канала `/tmp/hyprwm` не настраивается: он зашит в `scripts/install4.py`.

## Как переключить start.sh (НЕ сделано — сделать при первом живом прогоне)

1. `cd hook/swift && swift build -c release && swift test`.
2. `hook/stop.sh` (Python-демон вернёт скрытые окна и выйдет).
3. В `start.sh` заменить строку запуска демона:
   ```sh
   pkill -f "$H/swift/.build/release/hyprwm-swift" 2>/dev/null
   HYPRWM_STATE_DIR=$H HYPRWM_DEBUG=${HYPRWM_DEBUG:-} nohup $H/swift/.build/release/hyprwm-swift >> /tmp/hyprwm.log 2>&1 &
   ```
   (строку с `hyprwm.py` закомментировать — не запускать оба: Swift-демон откажется стартовать, если на
   сокете уже кто-то отвечает, но Python-демон так не проверяет и отберёт сокет).
4. В `stop.sh` добавить `pkill -f "$H/swift/.build/release/hyprwm-swift"`.
5. Откат: вернуть строку `python3 -u $H/hyprwm.py` — файлы состояния общие и совместимые.

Движок в WindowServer не меняется: демон, как и Python, при старте сверяет sha1 `anim4.bin` с `anim4.state`
и при расхождении ставит движок тем же `run_lldb.sh scripts/install4.py` (новый файл канала, старый не трогается).

## Что перенесено 1:1 и чем это проверено

| Часть | Проверка |
|---|---|
| dwindle: `insert/remove/need/split_box/boxes/with_gaps/find_parent/neighbour`, минимумы `max(выученный, дефолт)`, `round()` половина к чётному | `TileGoldenTests`: 400 случайных деревьев (разные зазоры, `split_width_multiplier`, `default_split_ratio`, минимумы, вставка в несуществующий лист, переворот/ratio) — дерево после **каждого** шага, boxes, зазоры, округление, need, neighbour, find_parent совпадают с `REFERENCE_tile.py` |
| конфиг: `animation()` с наследованием, `curves()`, `gaps()`, `dwindle()`, номера кривых `engine.setup`, длительности `engine.anim` с TIME_SCALE только геометрии, popin N% | `ConfigGoldenTests` против Python на копии `hypr_cfg.json` (все листья дерева анимаций) |
| `sync` (вкладки/двойники, удаление, фокус, вставка с preselect/курсором), `apply` (popin, drift, видимая рамка, configure), `configured` (обучение минимумов), все команды (`focus/move/togglesplit/preselect/float/fullscreen/close/quit/hide/unhide/rescue/balance/resize/exec/reset/retile/status`), `close_anim` + отложенные `shut/check/_restore_check`, `hide/unhide/on_activate/rescue`, `on_moved`, `alpha_guard`, `hide_newbies`, `follow_mouse`, `realign`, разбор событий движка | `WMScenarioTests`: 160 случайных сценариев × 60 шагов = **9600 шагов**; на каждом шаге совпадают ответ, пачка команд канала (op/wid/цель/from/кривые/длительности/флаги), задания configure, системные вызовы (`ax_tileable` с кэшем/backoff, `ax_focus`, `ws_close`, `ws_quit`, `move_to_space`, `ax_forget`) и состояние (деревья, цели, скрытые, минимумы, …); итоговые `hyprwm.state.json`/`minsize_app.json` — **байт в байт**. Эталон — класс `WM` из `REFERENCE_hyprwm.py`, вынутый через `ast` и исполненный с подделками (модульный ctypes/SkyLight не исполняется) |
| такт `run()`: гейт снимка Q2 (сверка 250 мс), команда до первого снимка, ответ configure -> ретаргет в том же такте, EV_GONE, нестабильный снимок, фильтр `hyprdeco`, `wid_max` | `TickTests` (инварианты; эталона для бесконечного цикла нет) |
| протокол сокета: строка -> ответ + `\n`, все ждущие за раз, права 0600, «упавшая» команда — закрытие без ответа | `SocketTests` на временном пути |
| ABI канала: размеры/смещения Swift = C, `ch_geom/ch_alpha` пишут то, что ждёт движок, публикация только `commit`, `pending`, события, слоты, `wid_max`, O_EXCL | `ChannelABITests` на временном файле (не `/tmp/hyprwm`) |
| configure: последняя цель побеждает, промежуточные пропускаются, минимум окна возвращается | `ConfigurerTests` |
| JSON: `json.dump(indent=1)`, `ensure_ascii`, repr float (`1e-05`, `1e+16`), int против float | `JSONTests` + байтовое сравнение файлов в сценариях |

Проверка самих тестов (мутации): из 10 внесённых ошибок 8 ловятся (переворот стороны вставки, warp/drift,
таймаут newbies 1.5 с, округление не к чётному, лимит EV_MOVED 3/10 с, порог стража 1 с, дефолтный минимум,
preselect up). Не ловятся 2, и обе эквивалентны на достижимых данных: допуск рамки двойника-вкладки (тот же
двойник находится вторым признаком «окно того же pid ушло с экрана») и `eps` в `with_gaps` (края плиток
совпадают с краем области точно).

## Сознательные отличия от Python

1. **Исправлено падение Python-демона на вкладках.** `sync`: `self.target[w["wid"]] = self.target.pop(twin)`
   без умолчания -> `KeyError`, если у старой вкладки цели уже нет (её сняли `EV_GONE`/`EV_MOVED`/`unhide`).
   В Python исключение в главном цикле убивает демон. Генератор фикстур ловит это на 3–5 из ~165 случайных
   сценариев (traceback указывает ровно на эту строку). Вживую — **[H]**: сценарий «Cmd+W вкладки Ghostty, когда
   `EV_GONE` пришёл раньше снимка» правдоподобен, но не воспроизводился. В Swift цель просто не переносится.
2. Порядок перебора «ушедших» окон при поиске двойника: в Python — порядок хеш-множества (не задан),
   в Swift — по возрастанию wid. Для сравнения эталон в генераторе пропатчен так же (единственная правка
   эталонного кода).
3. Ошибки не убивают демон: полное кольцо команд — запись в лог вместо `RuntimeError`; ошибка снимка/движка в
   такте — лог и следующий такт. Не установился движок при старте — выход с кодом 1 (как падение Python).
4. Снимок окон больше 2 МБ — буфер растёт (Python падал).
5. Файлы состояния пишутся через временный файл + `rename`. Каталог по умолчанию — `/tmp/hyprwm-swift`.
6. Второй экземпляр не стартует, если на сокете уже отвечает демон.
7. `SIGPIPE` игнорируется, `SO_NOSIGPIPE` на сокете (иначе ответ отключившемуся клиенту убивал бы процесс —
   найдено тестом; в Python сигнал игнорируется интерпретатором).
8. Поток configure на приложение не завершается через 30 с простоя (очередь GCD ничего не стоит).
9. Тексты лога те же по смыслу; repr некоторых значений (строка конфига при старте) отличается.
10. Регулярки правил float — `NSRegularExpression` (ICU) вместо `re`; на текущих правилах дотфайлов разницы нет
    (их 6), на экзотическом синтаксисе может быть.
11. `float()` для `resize`: принимаются те же формы (`1e3`, `inf`, `nan`, `_`), неверное число — «команда упала».

## Что НЕ проверено вживую (всё, что касается системы)

- запуск демона вообще: AX-разрешение для нового бинарника (TCC), снимок `ws_snapshot`, SkyLight-вызовы
  (`hs_*` в `sys.c` — те же функции и аргументы, что ctypes в Python, но вызов из Swift/C не прогонялся);
- установка/подключение движка (`LiveEngine` — порт `engine.py` строка в строку, но ни разу не запускался);
- подложки `hyprdeco` (протокол stdin/stdout тот же);
- задержка «команда -> commit» (цель П1а ≤ 2 мс) не измерена;
- сценарии SK T1–T9 (MASTER §11 П1а: «не хуже, чем на Python») не прогонялись.

Первый живой прогон — по правилам MASTER §2: один агент у WS, Python-демон остановлен, после — T1–T9.

## Открытые вопросы

1. `mouse_down()` в Python: `CGEventSourceButtonState(1, 0)` — 1 это `HIDSystemState`, а комментарий говорит
   `combinedSessionState` (0). Перенесено 1:1 (1). Какое имелось в виду?
2. TCC: при запуске через `start.sh` из терминала ответственный процесс — терминал; хватит ли его разрешения
   Универсального доступа для `hyprwm-swift`, или выдавать отдельно?
3. Перейти ли на явный автомат состояний окна (fable_plan §2.1) уже в Swift-демоне до П2, или сначала
   прогнать живьём порт 1:1?
4. Нужна ли команда/сигнал для горячей перезагрузки конфига (P38) — в Python её нет, порт тоже без неё.
