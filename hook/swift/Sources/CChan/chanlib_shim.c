// Shim: compiles hook/src/chanlib.c itself (shared code for the Python and Swift daemons).
#include "../../../src/chanlib.c"
#include <math.h>

// Build off-channel first. A failed validation must not leave a partial table.
int hs_curve_record(struct ch_curve *out,unsigned type,double a,double b,double c,double d) {
    if(!out||!isfinite(a)||!isfinite(b)||!isfinite(c)||!isfinite(d))return 0;
    if(type==CV_SPRING) {
        if(a<=0||b<=0||c<0)return 0;
        memset(out,0,sizeof(*out));out->mass=a;out->k=b;out->d=c;out->type=type;return 1;
    }
    if(type!=CV_BEZIER||a<0||a>1||c<0||c>1||
       !isfinite((float)b)||!isfinite((float)d))return 0;
    memset(out,0,sizeof(*out));curve_bezier(out,(float)a,(float)b,(float)c,(float)d);
    for(unsigned i=0;i<CH_BAKED;i++)if(!isfinite(out->bx[i])||!isfinite(out->by[i]))return 0;
    return 1;
}

static int hs_curves_idle(void) {
    const u32 caps=CH_CAP_EFFECTS|CH_CAP_SHADOW|CH_CAP_SNAPSHOT|CH_CAP_SNAPSHOT_COVER|CH_CAP_TERMINAL_MOVE|CH_CAP_BIRTH|CH_CAP_ORDINARY_PREPARE;
    if(!ch||ch->h.magic!=CH_MAGIC||ch->h.size!=sizeof(*ch)||
       (ch->h.version&~caps)!=6||ch->h.stop||ch->h.nactive||ch->h.holding||pend!=pub||
       __atomic_load_n(&ch->h.cmd_head,__ATOMIC_ACQUIRE)!=__atomic_load_n(&ch->h.cmd_tail,__ATOMIC_ACQUIRE))return 0;
    for(unsigned i=0;i<CH_NW;i++)if(ch->win[i].used)return 0;
    return 1;
}

int hs_ordinary_prepare(unsigned wid,unsigned long long nonce,unsigned prepare,double x,double y,double w,double h) {
    if(!ch || !wid || !nonce || prepare>1 || ch->h.magic!=CH_MAGIC || ch->h.size!=sizeof(*ch) ||
       (prepare && !(ch->h.version&CH_CAP_ORDINARY_PREPARE)))return -2;
    struct ch_cmd *k=next_cmd();if(!k)return -1;
    k->op=OP_EDGE;k->wid=wid;k->flags=CH_ORDINARY_PREPARE;k->cpos=prepare;
    k->pad0=(u32)nonce;k->pad1=(u32)(nonce>>32);k->x=x;k->y=y;k->w=w;k->h=h;
    return 0;
}

int hs_curves_bootstrap(void *mapping,const struct ch_curve *expected,unsigned count) {
    const struct ch_curve zero={0};
    if(ch!=mapping||!expected||!count||count>CH_NCURVE||!hs_curves_idle())return 0;
    for(unsigned i=0;i<CH_NCURVE;i++) {
        if(memcmp(&ch->curve[i],&zero,sizeof(zero)))return 0;
        if(i<count) {if(expected[i].type!=CV_SPRING&&expected[i].type!=CV_BEZIER)return 0;}
        else if(memcmp(&expected[i],&zero,sizeof(zero)))return 0;
    }
    for(unsigned i=0;i<count;i++) {
        memcpy((char*)&ch->curve[i]+sizeof(u32),(const char*)&expected[i]+sizeof(u32),sizeof(zero)-sizeof(u32));
        __atomic_store_n(&ch->curve[i].type,expected[i].type,__ATOMIC_RELEASE);
    }
    return 1;
}

int hs_curves_rollback(void *mapping,const struct ch_curve *expected,unsigned count) {
    if(ch!=mapping||!expected||!count||count>CH_NCURVE||!hs_curves_idle()||memcmp(ch->curve,expected,sizeof(ch->curve)))return 0;
    for(unsigned i=0;i<count;i++) {
        __atomic_store_n(&ch->curve[i].type,CV_NONE,__ATOMIC_RELEASE);
        memset((char*)&ch->curve[i]+sizeof(u32),0,sizeof(struct ch_curve)-sizeof(u32));
    }
    return 1;
}

// Read-only migration gate: compare the EXISTING curve index mapping without
// changing channel version/capabilities, window allocation, settings or curves.
int hs_curve_compatible(unsigned id,unsigned type,double a,double b,double c,double d) {
    if(!ch||id>=CH_NCURVE)return 0;
    const struct ch_curve *curve=&ch->curve[id];if(curve->type!=type)return 0;
    if(type==CV_SPRING)return curve->mass==a&&curve->k==b&&curve->d==c;
    if(type!=CV_BEZIER)return 0;
    const float p1x=(float)a,p1y=(float)b,p2x=(float)c,p2y=(float)d;
    for(int i=0;i<CH_BAKED;i++) {
        const float t=(i+1)*(1.0f/CH_BAKED),t2=t*t,t3=t2*t,u=1-t;
        double x=(3*t*u*u*p1x)+(3*t2*u*p2x)+t3,y=(3*t*u*u*p1y)+(3*t2*u*p2y)+t3;
        if(fabs(curve->bx[i]-x)>1e-7||fabs(curve->by[i]-y)>1e-7)return 0;
    }
    return 1;
}

/* Swift-only paired writer. Reserve both records before constructing either;
 * an exhausted ring cannot publish a final configure without its old-buffer capture. */
int hs_snapshot_final(unsigned wid,unsigned flags,double x,double y,double w,double h,
                      double fx,double fy,double fw,double fh,unsigned cp,unsigned cs,double dp,double ds) {
    if (!ch || (ch->h.version & (CH_CAP_SNAPSHOT|CH_CAP_SNAPSHOT_COVER)) != (CH_CAP_SNAPSHOT|CH_CAP_SNAPSHOT_COVER)) return -2;
    if (pend == pub) pend = pub = __atomic_load_n(&ch->h.cmd_head,__ATOMIC_ACQUIRE);
    u32 tail = __atomic_load_n(&ch->h.cmd_tail,__ATOMIC_ACQUIRE);
    if (pend-tail > CH_NCMD-2) return -1;
    if (ch_geom(OP_GEOM,wid,flags|F_MOVE|F_SNAPSHOT,x,y,w,h,fx,fy,fw,fh,cp,cs,dp,ds)) return -1;
    return ch_cfg(wid,x,y,w,h);
}
