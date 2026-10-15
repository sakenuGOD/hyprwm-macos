// Channel header: hook/src/chan.h unchanged (no duplicated structures), plus chanlib.c declarations.
#pragma once
int hs_curve_compatible(unsigned id,unsigned type,double a,double b,double c,double d);
#include "../../../../src/chan.h"

unsigned ch_abi(void);
unsigned ch_off(int what);
void *ch_open(const char *path, int create);
void ch_curve_bezier(int id, float p1x, float p1y, float p2x, float p2y);
void ch_curve_spring(int id, double mass, double k, double d);
int ch_geom(int op, unsigned wid, unsigned flags, double x, double y, double w, double h,
            double fx, double fy, double fw, double fh, unsigned cpos, unsigned csize, double dpos, double dsize);
int ch_alpha(unsigned wid, unsigned flags, double a, double fa, unsigned calpha, double dalpha);
int ch_forget(unsigned wid);
int ch_under(unsigned wid, unsigned under);
int ch_space(unsigned wid, unsigned long long sid);
int ch_cfg(unsigned wid, double x, double y, double w, double h);
int hs_snapshot_final(unsigned wid, unsigned flags, double x,double y,double w,double h,
                      double fx,double fy,double fw,double fh,unsigned cp,unsigned cs,double dp,double ds);
int ch_effects(unsigned flags, unsigned curve, const double *values);
int ch_shadow(unsigned flags, unsigned curve, double duration, const double *values);
void ch_commit(void);
int ch_event(struct ch_evt *out);
