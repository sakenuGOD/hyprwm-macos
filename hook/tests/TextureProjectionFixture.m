// Real OWN-process QuartzCore/Metal pixel qualifier. No window, WindowServer
// attach, owner application, or borrowed renderer/queue is used here.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
@interface CALayer (HyprWMTextureFixturePrivate)
@property BOOL contentsOpaque;
@property(copy) NSString *contentsScaling;
@end
enum { AW=64,AH=48 };
static unsigned char pixels[AW*AH*4],reference[AW*AH*4];
static id<MTLTexture> texture(id<MTLDevice> device,unsigned w,unsigned h){
 MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;
 d.hazardTrackingMode=MTLHazardTrackingModeTracked;
 id<MTLTexture> t=[device newTextureWithDescriptor:d];assert(t && t.device==device);return t;
}
static void seal(id<MTLCommandQueue> queue){
 id<MTLCommandBuffer> cb=[queue commandBuffer];assert(cb);[cb commit];[cb waitUntilCompleted];
 assert(cb.status==MTLCommandBufferStatusCompleted && !cb.error);
}
static void raster(id<MTLTexture> input,id<MTLCommandQueue> queue,unsigned w,unsigned h,unsigned char *out){@autoreleasepool {
 id<MTLTexture> target=texture(queue.device,w,h);
 id<MTLCommandBuffer> clear=[queue commandBuffer];MTLRenderPassDescriptor *p=[MTLRenderPassDescriptor renderPassDescriptor];
 p.colorAttachments[0].texture=target;p.colorAttachments[0].loadAction=MTLLoadActionClear;
 p.colorAttachments[0].storeAction=MTLStoreActionStore;p.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,0);
 id<MTLRenderCommandEncoder> e=[clear renderCommandEncoderWithDescriptor:p];assert(e);[e endEncoding];[clear commit];
 CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);assert(color);
 CARenderer *renderer=[CARenderer rendererWithMTLTexture:target options:@{kCARendererMetalCommandQueue:queue,kCARendererColorSpace:(__bridge id)color}];
 CGColorSpaceRelease(color);assert(renderer);
 CALayer *root=[CALayer layer],*body=[CALayer layer];
 assert([body respondsToSelector:@selector(setContentsScaling:)] && [body respondsToSelector:@selector(setContentsOpaque:)]);
 [CATransaction begin];[CATransaction setDisableActions:YES];
 root.anchorPoint=CGPointZero;root.position=CGPointZero;root.bounds=CGRectMake(0,0,w,h);
 root.opaque=NO;root.backgroundColor=NULL;root.masksToBounds=YES;
 body.anchorPoint=CGPointZero;body.position=CGPointZero;body.bounds=root.bounds;
 body.opaque=NO;body.contentsOpaque=NO;body.backgroundColor=NULL;body.contentsScale=1;
 body.contentsGravity=kCAGravityResize;body.contentsScaling=@"stretch";
 body.contentsCenter=CGRectMake(0,0,1,1);body.contentsRect=CGRectMake(0,1-(double)h/AH,(double)w/AW,(double)h/AH);
 body.contents=input;[root addSublayer:body];renderer.layer=root;renderer.bounds=root.bounds;
 [CATransaction commit];
 // Commit this OWN process's local render context before CARenderer reads it.
 // An implicit transaction from prior teardown must not leave a later scope
 // nested above an uncommitted context.
 [CATransaction flush];
 [renderer beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];[renderer addUpdateRect:renderer.bounds];
 [renderer render];[renderer endFrame];
 // The supplied OWN queue is the documented CARenderer submission queue.
 // A later terminal CB fences its submitted render work as well as our clear.
 seal(queue);assert(clear.status==MTLCommandBufferStatusCompleted && !clear.error);
 [target getBytes:out bytesPerRow:w*4 fromRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0];
 assert(body.contents==input && input.device==queue.device);
 [CATransaction begin];[CATransaction setDisableActions:YES];
 renderer.layer=nil;body.contents=nil;
 [CATransaction commit];[CATransaction flush];
}}
static unsigned delta(unsigned a,unsigned b){return a>b?a-b:b-a;}
static unsigned mismatches(const unsigned char *data,unsigned w,unsigned h,int bottom_origin,unsigned *max_delta){
 unsigned bad=0;*max_delta=0;
 for(unsigned y=0;y<h;y++)for(unsigned x=0;x<w;x++) {
  unsigned rx=x<AW?x:AW-1,ry;
  if(bottom_origin){unsigned local=h-1-y;ry=AH-1-(local<AH?local:AH-1);}
  else ry=y<AH?y:AH-1;
  for(unsigned c=0;c<4;c++) {
   unsigned d=delta(data[(y*w+x)*4+c],reference[(ry*AW+rx)*4+c]);
   if(d>*max_delta)*max_delta=d;if(d>1)bad++;
  }
 }
 return bad;
}
int main(int argc,const char **argv){@autoreleasepool {
 assert(argc==1 || argc==2);NSString *directory=argc==2?@(argv[1]):nil;
 id<MTLDevice> device=MTLCreateSystemDefaultDevice();assert(device);
 id<MTLCommandQueue> queue=[device newCommandQueue];assert(queue && queue.device==device);
 const unsigned alpha[4]={0,64,128,255};
 for(unsigned y=0;y<AH;y++)for(unsigned x=0;x<AW;x++) {
  unsigned a=alpha[((x/8)+2*(y/6))%4],i=(y*AW+x)*4;
  pixels[i]=(x*3+y*5)%(a+1);pixels[i+1]=(x*7+y*11)%(a+1);
  pixels[i+2]=(x*13+y*17)%(a+1);pixels[i+3]=a;
 }
 id<MTLTexture> input=texture(device,AW,AH);
 [input replaceRegion:MTLRegionMake2D(0,0,AW,AH) mipmapLevel:0 withBytes:pixels bytesPerRow:AW*4];
 raster(input,queue,AW,AH,reference);
 if(directory)assert([[NSData dataWithBytes:reference length:sizeof(reference)] writeToFile:[directory stringByAppendingPathComponent:@"reference.bgra"] atomically:YES]);
 if(directory)assert([[NSData dataWithBytes:pixels length:sizeof(pixels)] writeToFile:[directory stringByAppendingPathComponent:@"input.bgra"] atomically:YES]);
 unsigned forward=0,reverse=0;
 for(unsigned y=0;y<AH;y++)for(unsigned x=0;x<AW;x++) {
  unsigned a=reference[(y*AW+x)*4+3];
  forward+=delta(a,pixels[(y*AW+x)*4+3])>1;
  reverse+=delta(a,pixels[((AH-1-y)*AW+x)*4+3])>1;
 }
 assert(!reverse); // OWN framebuffer origin is reversed relative to source bytes.
 const unsigned cases[][2]={{64,48},{80,64},{48,32},{80,32},{48,64}};
 unsigned total[2]={0,0},maximum[2]={0,0};
 for(unsigned n=0;n<sizeof(cases)/sizeof(cases[0]);n++) {
  unsigned w=cases[n][0],h=cases[n][1];unsigned char *out=calloc(w*h,4);assert(out);
  raster(input,queue,w,h,out);
  if(directory)assert(([[NSData dataWithBytes:out length:w*h*4] writeToFile:[directory stringByAppendingPathComponent:[NSString stringWithFormat:@"%ux%u.bgra",w,h]] atomically:YES]));
  for(unsigned origin=0;origin<2;origin++) {
   unsigned max=0;total[origin]+=mismatches(out,w,h,origin,&max);if(max>maximum[origin])maximum[origin]=max;
  }
  free(out);
 }
 unsigned char unchanged[sizeof(pixels)];[input getBytes:unchanged bytesPerRow:AW*4 fromRegion:MTLRegionMake2D(0,0,AW,AH) mipmapLevel:0];
 assert(!memcmp(pixels,unchanged,sizeof(pixels)));
 printf("{\"source\":[64,48],\"cases\":6,\"alpha_forward_bad\":%u,\"alpha_reverse_bad\":%u,\"uv_bad\":[%u,%u],\"max_delta\":[%u,%u],\"immutable\":true}\n",forward,reverse,total[0],total[1],maximum[0],maximum[1]);fflush(stdout);
 assert(!total[1]); // Match the native bottom-origin framebuffer, with top-pinned UV.
 puts("OWN native MTLTexture/CALayer RGBA alpha/crop/clamp/interior-scale/GPU4 PASS");return 0;
}}
