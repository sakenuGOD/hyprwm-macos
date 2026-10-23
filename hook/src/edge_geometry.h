// Geometry for live edge extension. All rectangles use top-left window points.
// The app buffer remains 1:1. Only two-pixel edge samples fill B minus A.
#ifndef HYPR_EDGE_GEOMETRY_H
#define HYPR_EDGE_GEOMETRY_H
struct edge_rect { double x, y, w, h; };
struct edge_patch { struct edge_rect clip, sample; };
static double edge_min(double a, double b) { return a < b ? a : b; }
static int edge_valid(double a) { return a == a && a > 0 && a < 100000; }
static int edge_layout_cut(double aw, double ah, double bw, double bh,
                           double cutw, double cuth, struct edge_patch out[3]) {
    for (int i=0;i<3;i++) out[i]=(struct edge_patch){0};
    if (!edge_valid(aw)||!edge_valid(ah)||!edge_valid(bw)||!edge_valid(bh)) return -1;
    double cw=edge_min(cutw,bw), ch=edge_min(cuth,bh), ew=edge_min(2,aw), eh=edge_min(2,ah);
    int count=0;
    if (bw>aw) { out[0]=(struct edge_patch){{cw,0,bw-cw,ch},{aw-ew,0,ew,ch}};count++; }
    if (bh>ah) { out[1]=(struct edge_patch){{0,ch,cw,bh-ch},{0,ah-eh,cw,eh}};count++; }
    if (bw>aw && bh>ah) {
        out[2]=(struct edge_patch){{cw,ch,bw-cw,bh-ch},{aw-ew,ah-eh,ew,eh}};count++;
    }
    return count;
}
static int edge_layout(double aw, double ah, double bw, double bh, struct edge_patch out[3]) {
    return edge_layout_cut(aw,ah,bw,bh,aw,ah,out);
}
static double edge_pixel_floor(double position,double scale) {
    double p=position*scale;
    long long n=(long long)p;
    if((double)n>p)n--;
    return n/scale;
}
static int edge_layout_aligned(double aw,double ah,struct edge_rect b,double scale,
                               struct edge_patch out[3]) {
    if(!(scale>=.5 && scale<=16) || b.x!=b.x || b.y!=b.y ||
       b.x>100000 || b.x< -100000 || b.y>100000 || b.y< -100000 ||
       !edge_valid(aw) || !edge_valid(ah))return edge_layout(aw,ah,b.w,b.h,out);
    // Adjacent masked layers at a fractional device pixel both have partial
    // coverage. Source-over then leaves a dark/translucent seam. Share one
    // pixel boundary, moving at most one physical pixel into the edge sample.
    double cw=b.w>aw?edge_pixel_floor(b.x+aw,scale)-b.x:aw;
    double ch=b.h>ah?edge_pixel_floor(b.y+ah,scale)-b.y:ah;
    if(cw<=0)cw=aw;if(ch<=0)ch=ah;
    return edge_layout_cut(aw,ah,b.w,b.h,cw,ch,out);
}
#endif
