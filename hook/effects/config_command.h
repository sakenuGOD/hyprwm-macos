#ifndef HY_EFFECTS_CONFIG_COMMAND_H
#define HY_EFFECTS_CONFIG_COMMAND_H
#include "runtime_api.h"

// ABI-neutral OP12: all thirteen command doubles are interpreted only here.
// Never retains pointers into the writer-owned curve table.
static inline int hy_effects_config_command(const struct ch *ch,const struct ch_cmd *k,
                                            struct hy_effects_config *out) {
    if(!ch||!k||!out||k->op!=OP_EFFECTS||k->wid||k->csize||k->calpha||k->pad0||k->pad1||
       k->flags&~(HY_EFFECTS_ROUNDING|HY_EFFECTS_GLOW|HY_EFFECTS_MASTER_OFF)||k->cpos>=CH_NCURVE)return 0;
    out->rounding=k->x;out->power=k->y;out->glow_range=k->w;out->glow_power=k->h;
    out->active[0]=k->fx;out->active[1]=k->fy;out->active[2]=k->fw;out->active[3]=k->fh;
    out->inactive[0]=k->dpos;out->inactive[1]=k->dsize;out->inactive[2]=k->dalpha;out->inactive[3]=k->a;
    out->glow_duration=k->fa;out->enabled=k->flags;
    const struct ch_curve *curve=&ch->curve[k->cpos];
    out->curve.type=curve->type;out->curve.pad=0;
    out->curve.mass=curve->mass;out->curve.k=curve->k;out->curve.d=curve->d;
    for(unsigned i=0;i<CH_BAKED;i++) {out->curve.bx[i]=curve->bx[i];out->curve.by[i]=curve->by[i];}
    return 1;
}
static inline int hy_shadow_config_command(const struct ch *ch,const struct ch_cmd *k,HYShadowConfig *out,double *duration) {
    if(!ch||!k||!out||!duration||k->op!=OP_SHADOW||k->wid||k->flags>1||k->csize||k->calpha||k->cpos>=CH_NCURVE)return 0;
    out->range=k->x;out->power=k->y;out->scale=k->w;out->offsetX=k->h;out->offsetY=k->fx;
    out->active[0]=k->fy;out->active[1]=k->fw;out->active[2]=k->fh;out->active[3]=k->dpos;
    out->inactive[0]=k->dsize;out->inactive[1]=k->dalpha;out->inactive[2]=k->a;out->inactive[3]=k->fa;
    union {double d;u64 bits;} packed={.bits=(u64)k->pad0|((u64)k->pad1<<32)};*duration=packed.d;
    return 1;
}
#endif
