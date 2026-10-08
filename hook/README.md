# metalCallbacks hook — веха 1

Грузится разово в живой WindowServer (НЕ персистентно). Добавляет узел в
глобальный список `metalCallbacks` SkyLight, который composite() обходит каждый
кадр. Нода: {next, signed_fn, ctx}. fn-указатель подписывается paciza (ключ IA,
модификатор 0) — иначе `blraaz` в composite() фатально не пройдёт аутентификацию.

Этапы:
1. counter.dylib — колбэк только инкрементит счётчик в ctx. Проверяем вставку,
   подпись, что зовётся ~58/с. Нулевой риск картинке.
2. redfill.dylib — рисует красное в Metal-контекст кадра (ctx даёт MetalContext*).

Загрузка (после boot-args -arm64e_preview_abi amfi_get_out_of_my_way=1 + ребут):
  см. inject.md
Откат: sudo killall WindowServer
