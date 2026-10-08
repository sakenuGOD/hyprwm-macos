// counter.dylib — веха 1, этап 1: безопасная проверка хука metalCallbacks.
// Колбэк НИЧЕГО не рисует — только инкрементит счётчик в ctx. Так проверяем:
//   (1) вставка узла в список, (2) корректность PAC-подписи (blraaz не фатал),
//   (3) что composite() реально зовёт нас каждый кадр.
// Загружается разово в живой WindowServer; откат = killall WindowServer.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ptrauth.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <os/log.h>

// Узел списка metalCallbacks (из CGXInvokeTransition): {next, fn, ctx}
struct cb_node { struct cb_node *next; void *fn; void *ctx; };

// Наш счётчик, на который будет смотреть ctx.
volatile uint64_t re_hook_frames = 0;  // экспортируем для чтения из lldb

// Сигнатура колбэка (из composite@186f40968):
//   x0 = MetalContext*, x1 = &shared_ptr<Display>, x2 = 0, x3 = node->ctx
static void my_callback(void *mctx, void *display_sp, void *zero, void *ctx) {
    (void)mctx; (void)display_sp; (void)zero;
    __atomic_add_fetch((volatile uint64_t*)ctx, 1, __ATOMIC_RELAXED);
}

__attribute__((constructor))
static void install(void) {
    os_log_t lg = os_log_create("re.hook", "counter");
    // 1. Найти slide SkyLight по загруженному образу.
    const char *needle = "SkyLight.framework";
    intptr_t slide = 0; int found = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, needle)) { slide = _dyld_get_image_vmaddr_slide(i); found = 1; break; }
    }
    if (!found) { os_log_error(lg, "SkyLight image not found"); return; }

    // 2. Адрес глобала metalCallbacks = статический 0x1ea5fb3b8 + slide.
    //    (статику брали из nm; проверим живой slide в рантайме логом.)
    struct cb_node **head = (struct cb_node **)(0x1ea5fb3b8 + slide);
    os_log(lg, "SkyLight slide=%p  metalCallbacks head @ %p", (void*)slide, (void*)head);

    // 3. Собрать узел. fn ОБЯЗАН быть подписан paciza (ключ IA, модификатор 0),
    //    т.к. composite() зовёт его через blraaz.
    struct cb_node *node = (struct cb_node*)calloc(1, sizeof(*node));
    // &my_callback в arm64e уже IA-подписан; снимаем подпись до сырого адреса,
    // затем подписываем IA/модификатор 0 — ровно то, что аутентифицирует blraaz.
    void *raw = ptrauth_strip((void*)&my_callback, ptrauth_key_asia);
    void *signed_fn = ptrauth_sign_unauthenticated(raw, ptrauth_key_asia, 0);
    node->fn  = signed_fn;
    node->ctx = (void*)&re_hook_frames;

    // 4. Вставить в голову списка (как CGXInvokeTransition).
    node->next = *head;
    *head = node;
    os_log(lg, "installed node=%p fn(signed)=%p ctx=%p &re_hook_frames=%p",
           (void*)node, signed_fn, node->ctx, (void*)&re_hook_frames);
}
