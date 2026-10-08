# WindowServer RE stand

Цель: Hyprland-подобные анимации окон на macOS через хук композитинга в SkyLight
(внутри эппловского WindowServer). Подробности и план — в памяти Claude
`project_windowserver_re.md`.

## Что где

- `extracted/` — бинари для реверса: `SkyLight` (8.3M, вся логика), `QuartzCore`
  (6M, CoreAnimation), `WindowServer` (154K, тонкая обёртка).
- `ghidra_proj/WS_RE` — проект Ghidra. SkyLight импортирован и проанализирован.
- `GhidraMCP-7.0.0-rc.1-ghidra12.1.4.zip` — пропатченное под Ghidra 12.1.4
  расширение (оригинал bethington помечен 12.1.3). Копия на `~/Desktop/GhidraMCP.zip`.
- `.venv/` — MCP-мост (`bridge-mcp-ghidra`).
- `re.sh` — helper (см. ниже).

## Поднять стенд

1. `./re.sh gui` — запустить Ghidra.
2. Открыть проект `WS_RE`, двойной клик по `SkyLight`.
3. File → Configure → включить плагин **GhidraMCP** (ставится один раз, состояние
   запоминается). HTTP-сервер на :8089 поднимается сам.
4. `./re.sh status` — проверить, что сервер отвечает.

Агент Claude: инструменты `mcp__ghidra__*` появляются в НОВОЙ сессии Claude Code
(MCP-серверы грузятся при старте сессии; сервер уже зарегистрирован через
`claude mcp add ghidra`). В текущей сессии, где сервер добавили, доступ — через
`re.sh` / прямые HTTP-эндпоинты :8089.

## re.sh

- `./re.sh status` — сервер + залочен ли проект + число функций.
- `./re.sh gui` — запустить Ghidra.
- `./re.sh functions <regex>` — грепнуть имена функций (регистронезависимо).
- `./re.sh decompile <func>` — декомпиляция одной функции.
- `./re.sh import-extra` — добавить QuartzCore+WindowServer в проект
  (Ghidra должна быть ЗАКРЫТА — проект лочится).

## Первая веха (не начата)

Найти точку сборки финального кадра (куда вешать хук) → нарисовать там красный
прямоугольник поверх всего экрана. Статикой (эта машина, SIP не трогаем),
проверка — потом на тестовой системе через LLDB по SSH.

Уже всплывшие кандидаты (`./re.sh functions`):
- `generate_composite_layer`
- `_CompositeDestinationCreateCommon`, `_WSCompositeDestinationCreateWithIOSurface`
- `__CGSFlushSurfaceInline`, `_CGSWindowFlushRegion`
- группа `composite_destination_*`

Открытые вопросы: где именно финальная компоновка уходит в Metal; не помешает ли
PAC (arm64e) хукать в нужной точке. Оба проверяются на стенде.
