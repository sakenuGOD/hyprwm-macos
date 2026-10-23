// counter.dylib: milestone 1, stage 1: safe verification of the metalCallbacks hook.
// The callback draws NOTHING; it only increments the counter in ctx. This checks:
// (1) insertion into the list, (2) correct PAC signing (blraaz does not crash),
// (3) that composite() actually calls us every frame.
// Loaded once into a live WindowServer; disable only the owned callback through its validated inverse.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ptrauth.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <os/log.h>

// metalCallbacks list node (from CGXInvokeTransition): {next, fn, ctx}
struct cb_node { struct cb_node *next; void *fn; void *ctx; };

// Our counter, referenced by ctx.
volatile uint64_t re_hook_frames = 0;  // exported for reading from lldb

// Callback signature (from composite@186f40968):
//   x0 = MetalContext*, x1 = &shared_ptr<Display>, x2 = 0, x3 = node->ctx
static void my_callback(void *mctx, void *display_sp, void *zero, void *ctx) {
    (void)mctx; (void)display_sp; (void)zero;
    __atomic_add_fetch((volatile uint64_t*)ctx, 1, __ATOMIC_RELAXED);
}

__attribute__((constructor))
static void install(void) {
    os_log_t lg = os_log_create("re.hook", "counter");
    // 1. Find the SkyLight slide from the loaded image.
    const char *needle = "SkyLight.framework";
    intptr_t slide = 0; int found = 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, needle)) { slide = _dyld_get_image_vmaddr_slide(i); found = 1; break; }
    }
    if (!found) { os_log_error(lg, "SkyLight image not found"); return; }

    // 2. metalCallbacks global address = static 0x1ea5fb3b8 + slide.
    // (Static address obtained from nm; log the live slide at runtime to verify.)
    struct cb_node **head = (struct cb_node **)(0x1ea5fb3b8 + slide);
    os_log(lg, "SkyLight slide=%p  metalCallbacks head @ %p", (void*)slide, (void*)head);

    // 3. Build the node. fn MUST be signed with paciza (IA key, modifier 0),
    // because composite() calls it through blraaz.
    struct cb_node *node = (struct cb_node*)calloc(1, sizeof(*node));
    // &my_callback is already IA-signed on arm64e; strip to the raw address,
    // then sign with IA/modifier 0, exactly what blraaz authenticates.
    void *raw = ptrauth_strip((void*)&my_callback, ptrauth_key_asia);
    void *signed_fn = ptrauth_sign_unauthenticated(raw, ptrauth_key_asia, 0);
    node->fn  = signed_fn;
    node->ctx = (void*)&re_hook_frames;

    // 4. Insert at the head of the list (like CGXInvokeTransition).
    node->next = *head;
    *head = node;
    os_log(lg, "installed node=%p fn(signed)=%p ctx=%p &re_hook_frames=%p",
           (void*)node, signed_fn, node->ctx, (void*)&re_hook_frames);
}
