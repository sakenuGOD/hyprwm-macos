// Shim: compiles hook/src/chanlib.c itself (shared code for the Python and Swift daemons).
#include "../../../src/chanlib.c"
#include <math.h>

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
