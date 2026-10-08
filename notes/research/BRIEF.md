# Бриф для исследователей (общий)
Проект: личный тайлинговый WM пользователя на его macOS 26.7.1 (arm64e), цель — ощущение 1:1 как его Hyprland на Linux
(монитор 180 Гц; мак — MacBook Air M4, 60 Гц). Наш код уже исполняется внутри WindowServer (движок hook/src/anim4.c,
такт на таймере главного потока WS, пружины hyprutils 1:1). Видимая рамка = сдвиг-трансформ + серверная прямоугольная
обрезка (set_window_list_global_clip_shape) + окна-подложки (hook/deco). Демон hook/hyprwm.py (dwindle, события,
configure приложениям через AX: src/axlib.c). Цель пользователя — стать полноценным композитором: геометрия окон,
анимации и эффекты зависят только от нашего кода.

ПРАВИЛА: только чтение и отчёт. НЕ запускать lldb/dtrace/sudo, НЕ трогать живой WindowServer и демон, НЕ менять файлы
проекта (кроме своего отчёта в notes/research/). Статика разрешена: /tmp/sl_dis.txt (otool SkyLight), /tmp/sl_map.tsv
(адрес↔имя), бинарники ~/Developer/re-tools/extracted/{SkyLight,QuartzCore,WindowServer} (nm/otool/strings),
AppKit можно извлечь ipsw из dyld cache в /tmp. Интернет — можно. В реверсе НЕ выдумывать: каждый символ/смещение
подтвердить по бинарнику (адрес из sl_map.tsv / otool) или пометить [гипотеза]. Каждая претензия — с доказательством.
Читать: GOAL.md, HANDOFF.md (сессии 5–6), notes/fable_plan.md, notes/anim_feel.md, notes/gap_review_2.md,
evidence/video_audit.md, notes/hyprland_spec_full.md. Параллельно работает агент Fable (notes/wayland_gap.md, когда появится) —
не дублировать, опираться. Отчёт по-русски: сначала «что видит пользователь / что даст», потом детали, в конце —
конкретные шаги для основного агента с проверкой каждого.
