#ifndef HY_SHADOW_CONTRACT_H
#define HY_SHADOW_CONTRACT_H
#include <stdint.h>

// A proposed OP13 payload uses exactly the existing command's thirteen doubles:
// range,power,scale,offsetX,offsetY,activeRGBA[4],inactiveRGBA[4]. Flags are separate.
// fadeShadow duration/curve and raw rounding/power remain existing FX consumers.
typedef struct {
    double range, power, scale, offsetX, offsetY;
    double active[4], inactive[4];
} HYShadowConfig;
typedef struct { double x,y,w,h; } HYShadowBox;
typedef struct {
    // Coordinates relative to the supplied unclipped decoration container.
    // Its geometryFlipped selects Y direction; config offsetY always means down.
    // Included-decoration box and surface box are distinct upstream inputs.
    HYShadowBox decorationBox, surfaceBox;
    double monitorScale, rawRounding, roundingPower, borderSize;
    // One externally evaluated fadeShadow clock for source and helper.
    // Window opacity belongs to the parent: never multiply it here again.
    double activeProgress;
    uint64_t generation;
} HYShadowFrame;
// Plain C ABI shared by validation, native rendering and the Metal shader.
typedef struct {
    uint32_t width,height;
    float radius,power,range,shadowPower,cutoutRadius,yFlipped;
    float cutout[4],color[4];
} HYShadowParams;
typedef struct {
    HYShadowParams pixels;
    HYShadowBox logicalBox;
    double monitorScale;
    uint64_t generation;
} HYShadowDraw;
typedef enum {
    // Actual CAContext / CALayerHost / RenderServer route. IOSurface rows are
    // reversed against layer-local Y precisely when the root is geometryFlipped.
    HYShadowTransportRegistered=0,
    // Public offscreen CARenderer has different root-flipped sampling semantics.
    HYShadowTransportPublicCARenderer=1
} HYShadowTransport;
typedef enum {
    HYShadowValid=0, HYShadowMissing, HYShadowNonfinite, HYShadowUnsupportedConfig,
    HYShadowUnsupportedColor, HYShadowInvalidFrame, HYShadowInvalidTexture,
    HYShadowInvalidTransport
} HYShadowStatus;
#ifdef __cplusplus
extern "C" {
#endif
HYShadowStatus HYShadowValidateConfig(const HYShadowConfig *config);
HYShadowStatus HYShadowValidateFrame(const HYShadowFrame *frame);
HYShadowStatus HYShadowPrepare(const HYShadowConfig *config,const HYShadowFrame *frame,int geometryFlipped,HYShadowDraw *draw);
HYShadowStatus HYShadowPrepareForTransport(const HYShadowConfig *config,const HYShadowFrame *frame,int geometryFlipped,HYShadowTransport transport,HYShadowDraw *draw);
// Inputs must first pass Prepare. Equality is of actual GPU scalar values;
// translation, owner identity and generation deliberately require separate gates.
int HYShadowEquivalentPixels(const HYShadowDraw *a,const HYShadowDraw *b);
const char *HYShadowStatusDescription(HYShadowStatus status);
#ifdef __cplusplus
}
#endif
#endif
