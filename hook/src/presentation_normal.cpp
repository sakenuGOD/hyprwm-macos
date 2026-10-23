// Native original exceptions propagate unchanged. Only isolated OWN capture
// failures are caught; the C abort closes its exact lock and quarantines output.
using Original=void *(*)(void *,void *,void *,void **);
extern "C" void anim_rgba_normal_capture(void *,void *,void *,void **,void *,void *,unsigned long long);
extern "C" void anim_rgba_normal_abort(void *) noexcept;
extern "C" __attribute__((noinline)) void *anim_rgba_normal_prepare(
        void *compositor,void *head,void *destination,void **shape,void *binding,Original original) {
    void *prepared=original(compositor,head,destination,shape);
    try {
        anim_rgba_normal_capture(compositor,head,destination,shape,binding,prepared,
            (unsigned long long)__builtin_frame_address(0));
    } catch(...) {
        anim_rgba_normal_abort(binding);
    }
    return prepared;
}
