// OWN process/device only. Exercise the actual native destination push/pop and
// typed destructor without attaching to WindowServer or opening a window.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <assert.h>
#include <stdio.h>
typedef void *(*NewRenderer)(const void *,void *,void *,unsigned);
typedef void (*Textures)(void *,void **,unsigned,int);
typedef void (*DestroyRenderer)(void *);
int main(void){@autoreleasepool {
 id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
 const void **callbacks=dlsym(RTLD_DEFAULT,"kCARenderMetalCallbacksRef");
 NewRenderer create=(NewRenderer)dlsym(RTLD_DEFAULT,"CARenderOGLNew_");
 Textures textures=(Textures)dlsym(RTLD_DEFAULT,"CARenderMTLSetDestinationTextures");
 DestroyRenderer destroy=(DestroyRenderer)dlsym(RTLD_DEFAULT,"CARenderOGLDestroy");
 assert(callbacks && *callbacks && create && textures && destroy);
 MTLTextureDescriptor *desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
 desc.storageMode=MTLStorageModeShared;desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
 desc.hazardTrackingMode=MTLHazardTrackingModeTracked;
 id<MTLTexture> texture=[device newTextureWithDescriptor:desc];assert(texture);
 void *renderer=create(*callbacks,(__bridge void *)device,NULL,0);assert(renderer);
 char *metal=*(char **)renderer;assert(metal && !*(void **)(metal+0x1338));
 id<MTLCommandQueue> queue=(__bridge id)*(void **)(metal+0xef0);assert(queue && queue.device==device);
 id<MTLCommandBuffer> clear=[queue commandBuffer];assert(clear);
 MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
 pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
 pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
 id<MTLRenderCommandEncoder> encoder=[clear renderCommandEncoderWithDescriptor:pass];assert(encoder);
 [encoder endEncoding];[clear commit];[clear waitUntilCompleted];assert(clear.status==MTLCommandBufferStatusCompleted);
 void *t=(__bridge void *)texture;textures(renderer,&t,1,1);
 assert(*(void **)(metal+0x2d8));
 textures(renderer,NULL,0,0);assert(!*(void **)(metal+0x2d8));
 destroy(renderer);
 puts("OWN native renderer clear4/bind/unbind/current-surfaceNULL/typedDestroy PASS");
 return 0;
}}
