#include "../src/display_sink.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
static struct display_sink sink;
static unsigned char *input;
static int old_ref,new_ref,calls,freed,enums,mode;
static int old_object,new_object,head_object,enum_object,window_object;
static void *retain(void *p){assert(p==&old_object);old_ref++;return p;}
static void release(void *p){
    if(p==&old_object){assert(old_ref>1);old_ref--;}
    else {assert(p==&new_object && new_ref==1);new_ref--;}
}
static void free_layers(void *p){assert(p==&head_object);freed++;}
static void release_enum(void *p){assert(p==&enum_object);enums++;}
static int generate(void *r,void *w){
    assert(r==sink.redraw && w==&window_object);calls++;
    assert(!((unsigned long long)r&15));
    for(unsigned i=0;i<0xb8;i++)if(i<0x60 || i>=0x88 || (i>=0x70 && i<0x78))
        assert(((unsigned char *)r)[i]==input[i]);
    for(unsigned i=0xb8;i<0xc0;i++)assert(!((unsigned char *)r)[i]);
    assert(!display_sink_get(r,0x68) && !display_sink_get(r,0x80));
    assert(display_sink_get(r,0x78)==&sink.head);
    assert(display_sink_get(r,0x60)==(mode==2?0:&old_object));
    if(mode!=2){
        assert(old_ref==2);sink.head=&head_object;
        display_sink_put(r,0x68,&enum_object);
        if(mode==1){release(&old_object);new_ref=1;display_sink_put(r,0x60,&new_object);}
    }
    // Private modifications must not be written back into the native R.
    ((unsigned char *)r)[0x91]^=1;
    return mode==2?0:19;
}
int main(void){
    // Exactly b8 readable bytes; ASAN detects the previously proposed c0 copy.
    input=malloc(0xb8);assert(input);memset(input,0x53,0xb8);
    struct display_sink_api api={generate,retain,release,free_layers,release_enum};
    for(mode=0;mode<3;mode++){
        memset(&sink,0,sizeof(sink));old_ref=1;new_ref=calls=freed=enums=0;
        display_sink_put(input,0x60,mode==2?0:&old_object);display_sink_put(input,0x80,0);
        unsigned char before[0xb8];memcpy(before,input,sizeof(before));
        assert(display_sink_run(&sink,&api,input,&window_object)==DISPLAY_SINK_COMPLETE);
        assert(!sink.phase && !sink.head && calls==1 && freed==(mode!=2) && enums==(mode!=2));
        assert(old_ref==1 && !new_ref && sink.native_result==(mode==2?0:19));
        assert(!memcmp(before,input,sizeof(before)));
    }
    calls=0;display_sink_put(input,0x80,&head_object);
    assert(display_sink_run(&sink,&api,input,&window_object)==DISPLAY_SINK_REFUSED && !calls);
    display_sink_put(input,0x80,0);sink.phase=DISPLAY_SINK_GENERATE;
    assert(display_sink_run(&sink,&api,input,&window_object)==DISPLAY_SINK_REFUSED && !calls);
    sink.phase=0;
    assert(display_sink_run(&sink,&api,sink.redraw,&window_object)==DISPLAY_SINK_REFUSED && !calls);
    struct display_sink *tail=calloc(1,sizeof(*tail));assert(tail);
    assert(display_sink_run(tail,&api,(char *)tail+0xc0,&window_object)==DISPLAY_SINK_REFUSED && !calls);
    free(tail);
    api.retain=0;
    assert(display_sink_run(&sink,&api,input,&window_object)==DISPLAY_SINK_REFUSED && !calls);
    free(input);puts("Sink private R extent, ownership replacement, cleanup and refusal PASS");
}
