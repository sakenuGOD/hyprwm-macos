// Тело колбэка metalCallbacks: заливает прямоугольник цветом через metal_clear_rect.
// Позиционно-независимо: всё (адрес функции, rect, цвет) приходит через ctx (x3).
// Вызывается внутри composite() с активным MetalContext (x0).
typedef struct { double a,b,c,d; } R;                 // CGRect ABI = 4 double (HFA)
typedef float V4 __attribute__((__vector_size__(16))); // simd float4 = 1 V-регистр
typedef void (*clear_t)(void *mctx, float scale, R rect, V4 color);
struct ctx { void *fn; double x,y,w,h; float r,g,b,a,scale; };

void cb(void *mctx, void *disp, void *zero, struct ctx *c) {
    (void)disp; (void)zero;
    clear_t fn = (clear_t)c->fn;        // IA/0-подписанный -> compiled blraa совпадёт
    R rect = { c->x, c->y, c->w, c->h };
    V4 col  = { c->r, c->g, c->b, c->a };
    fn(mctx, c->scale, rect, col);
}
