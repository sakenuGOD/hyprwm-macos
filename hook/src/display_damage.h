// OFF-default full-footprint transition state. The caller owns the immutable
// native region/API/command mapping until exact OFF and all entries have drained.
// Admission means a positively identified serialized MAIN/session turn, an
// eligible S0 bucket, a fixed live B and a covering incoming display vector.
// This helper does not establish that authority or physical presentation.
#define DISPLAY_DAMAGE_MAGIC 0x31474d44574d5748ULL
#define DISPLAY_DAMAGE_COMMAND_MAGIC 0x31434d44574d5748ULL
struct display_damage_command {
    unsigned long long magic;
    unsigned size,version;
    // One atomic word: monotonically increasing revision << 1 | B-sink mode.
    unsigned long long request,completed;
};
struct display_damage {
    unsigned long long magic;
    unsigned size,version;
    void *region;
    void (*invalidate)(void *,void *,void *);
    struct display_damage_command *command;
    unsigned enabled,pad,phase,reason;
    unsigned long long epoch,entry_word,seen_word,completed_word;
    unsigned long long invalidations,native_acks,refused;
};
enum { DISPLAY_DAMAGE_IDLE,DISPLAY_DAMAGE_INVALIDATING,DISPLAY_DAMAGE_ACTIVE,
       DISPLAY_DAMAGE_OBSERVING,DISPLAY_DAMAGE_PREPARING,DISPLAY_DAMAGE_PREPARE_FAILED };
enum { DISPLAY_DAMAGE_OK,DISPLAY_DAMAGE_INVALID,DISPLAY_DAMAGE_BUSY,
       DISPLAY_DAMAGE_ADMISSION,DISPLAY_DAMAGE_REQUEST,DISPLAY_DAMAGE_STALE,
       DISPLAY_DAMAGE_UNWITNESSED };
static int display_damage_configured(struct display_damage *d) {
    return d && d->magic==DISPLAY_DAMAGE_MAGIC && d->size==sizeof(*d) &&
        d->version==1 && !d->pad && d->enabled<=1 && d->invalidate &&
        d->command && d->command->magic==DISPLAY_DAMAGE_COMMAND_MAGIC &&
        d->command->size==sizeof(*d->command) && d->command->version==1;
}
static int display_damage_valid(struct display_damage *d) {
    return display_damage_configured(d) && d->region;
}
static unsigned long long display_damage_begin(struct display_damage *d,
                         unsigned long long epoch,int admitted) {
    if(!display_damage_valid(d))return 0;
    if(!__atomic_load_n(&d->enabled,__ATOMIC_ACQUIRE))return 0;
    unsigned reason=DISPLAY_DAMAGE_OK;
    if(d->phase || d->epoch || d->entry_word)reason=DISPLAY_DAMAGE_BUSY;
    else if(!epoch || admitted!=1)reason=DISPLAY_DAMAGE_ADMISSION;
    if(reason){d->reason=reason;d->refused++;return 0;}
    unsigned long long word=__atomic_load_n(&d->command->request,__ATOMIC_ACQUIRE);
    if(!(word>>1))reason=DISPLAY_DAMAGE_REQUEST;
    else if(word!=d->seen_word && (word>>1)<=(d->seen_word>>1))reason=DISPLAY_DAMAGE_STALE;
    if(reason){d->reason=reason;d->refused++;return 0;}
    d->epoch=epoch;d->entry_word=word;d->reason=DISPLAY_DAMAGE_OK;
    if(word!=d->completed_word) {
        // A throw leaves persistent quarantine. No reset or borrowed cleanup.
        // A native return without a matching frame witness is retried next turn.
        d->phase=DISPLAY_DAMAGE_INVALIDATING;d->invalidations++;
        d->invalidate(0,0,d->region);
    }
    d->seen_word=word;d->phase=DISPLAY_DAMAGE_ACTIVE;
    return word;
}
static int display_damage_end(struct display_damage *d,unsigned long long epoch,
                             unsigned long long word,int native_result,int frame_matches) {
    if(!display_damage_valid(d) || d->phase!=DISPLAY_DAMAGE_ACTIVE ||
       d->epoch!=epoch || d->entry_word!=word || !word)return 0;
    int witnessed=native_result==0 && frame_matches==1;
    if(witnessed) {
        d->completed_word=word;d->native_acks++;
        // This ACK means native construction returned with a matching witness.
        // It never means these pixels were physically presented.
        __atomic_store_n(&d->command->completed,word,__ATOMIC_RELEASE);
    } else d->reason=DISPLAY_DAMAGE_UNWITNESSED;
    d->entry_word=0;d->epoch=0;d->phase=DISPLAY_DAMAGE_IDLE;
    return witnessed;
}
unsigned anim_display_damage_size(void){return sizeof(struct display_damage);}
unsigned anim_display_damage_command_size(void){return sizeof(struct display_damage_command);}
