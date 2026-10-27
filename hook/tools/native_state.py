"""Exact native ABI payloads for a fresh, initially stopped engine.

No OS code bytes, session receipts, or live reads. The caller must validate the
supported framework UUIDs, then sign the returned function cells IA/0 before
publication. Every optional effect, birth state, resource, and pending command
starts empty; no previous engine context is accepted as an input.
"""
import ctypes
import math
import struct
import sys
if sys.flags.optimize:
    raise RuntimeError('Native ABI validation requires Python optimization disabled')
U=ctypes.c_uint64;I=ctypes.c_uint32;D=ctypes.c_double

# Exact ctx ABI from anim4.c. All unlisted cells remain zero, including lazy
# selectors, optional effects/birth/observer state and saved window storage.
CONTEXT_FUNCTIONS = {
    0x00:'CGXSetWindowTransform3DList',0x08:'reschedule_callback_on_session',
    0x28:'CGXWindowByID',0x30:'CGRegionGetBoundingBox',0x38:'CGXMoveWindowList',
    0x40:'CGXSetWindowListAlpha',0x48:'exp',0x50:'sin',0x58:'cos',
    0x78:'WSDisplayScheduleGetPrevNextVBL',
    0x88:'_ZN9CGXWindow33set_window_list_global_clip_shapeEP13CGXConnectionP15CGSRegionObjectPKjj',
    0x90:'CGRegionCreateWithRect',0x98:'CFRelease',
    0xa0:'_ZNK9CGXWindow22resolved_corner_radiusEv',0xa8:'CGRegionCreateDifferenceWithRegion',
    0xb0:'mach_absolute_time',0xc0:'objc_msgSend',0xc8:'sel_registerName',
    0xd0:'objc_getClass',0xd8:'CGColorCreateSRGB',
    0xe0:'_ZN27WSCAContextScopeTransactionC1E19WSCAScopeParameters',
    0xe8:'_ZN27WSCAContextScopeTransaction18addContextToCommitEP9CAContext',
    0xf0:'_ZN27WSCAContextScopeTransactionD1Ev',0x148:'PKGSpaceForID',
    0x150:'window_ordering_group_list_create_from_window_id_array',
    0x158:'PKGWindowsMoveToManagedSpace',0x160:'free',
    0x218:'CGPathCreateWithRoundedRect',0x220:'CGPathRelease',
    0x228:'_ZN9CGXWindow23set_debug_corner_radiusEd',
    0x230:'_ZN9CGXWindow25clear_debug_corner_radiusEv',
    0x238:'CGPathCreateMutable',0x240:'CGPathAddRoundedRect',0x248:'CGPathAddRect',
    0x280:'CGXScheduleUpdateDisplaysIntersectingWindow',0x338:'CGXOrderWindow',
    0x340:'_ZL19CreateCloneOfWindowP9CGXWindow6CGRectPK10PKGDisplayb',
    0x348:'_ZNK9CGXWindow21screen_rect_from_rectE6CGRect',0x350:'PKGWindowGetDisplay',
    0x358:'PKGDisplayGetMain',0x360:'_ZN9CGXWindow18set_level_internalEP13CGXConnectionis',
    0x368:'_ZN9CGXWindow14release_windowEP13CGXConnectionPS_',
    0x370:'WSAddNotificationCallback',0x378:'WSRemoveNotificationCallback',0x388:'WSWindowGetID',
    0x3b0:'_ZN9CGXWindow20set_window_list_tagsEP13CGXConnectionPKPS_m18WSWindowTagBitMaskb',
    0x3c0:'WSPostNotificationToConnection',0x3c8:'CGXWindowGetOwner',
    0x3d8:'WSWindowSetWindowManagerShadowProperties',0x3e0:'WSWindowInvalidateShadowFrame',
    0x3e8:'_ZN9CGXWindow37invalidate_shadow_and_schedule_updateEP13CGXConnection',
    0x3f0:'WSWindowGetDisplayID',
}


def context_image(*,code,symbols,channel,control,queue,session,display,mach_us,resolve):
    """Return a zero-based 16KiB context and its IA/0 function-cell offsets."""
    if not isinstance(display,int) or not 0<display<2**32:
        raise ValueError('A verified active display is required')
    if not math.isfinite(mach_us) or not 0<mach_us<1000:
        raise ValueError('Invalid mach timebase')
    data=bytearray(16384)
    pointers=[]
    def put(offset,value,function=False):
        if not isinstance(value,int) or not 0x100000000<=value<0x800000000000:
            raise ValueError('Invalid native pointer')
        struct.pack_into('<Q',data,offset,value)
        if function:pointers.append(offset)
    for offset,name in CONTEXT_FUNCTIONS.items():put(offset,resolve(name),True)
    for offset,name in [(0x10,'_anim_rgba_normal_present_dispatch'),
                        (0x380,'_anim_will_release'),(0x6e8,'_anim_tick')]:
        relative=symbols[name]
        if not isinstance(relative,int) or relative<=0:
            raise ValueError('Invalid same-image function offset')
        put(offset,code+relative,True)
    for offset,value in [(0x18,queue),(0x20,session),(0x60,channel),(0x6e0,control)]:put(offset,value)
    struct.pack_into('<4I',data,0x68,0x30000000,0,0x170,1)
    struct.pack_into('<I',data,0x80,display)
    struct.pack_into('<d',data,0xb8,mach_us)
    return bytes(data),pointers
class Capture(ctypes.Structure):
 _fields_=[('magic',U),('size',I),('version',I),('node',U*3)]+[(k,U) for k in [
 'engine','is_main','thread_self','stack_top','stack_size','session_control','generate','populate','free_layers',
 'release_enumerator','compositor','texture','retain_obj','release_obj','status_selector',
 'expected_texture','expected_context_count','expected_capture_backing']]+[('cohort_pc',U*5)]+[(k,U) for k in [
 'native_flags','native_capture_flag','source','creator','pid_version']]+[(k,I) for k in ['wid','stage','dead','reason']]+[
 ('capture_rect',D*4)]+[(k,U) for k in ['clone','capture','texture_ref','command_buffer']]+[(k,I) for k in ['clone_wid','gpu_status']]+[(k,U) for k in [
 'callbacks','nonmain','wrong_cohort','misses','encoded','update','update_after','context','index','changed_seed',
 'command_before','command_after','depth_before','depth_after','context_count','width','height','format']]+[
 ('scale',D),('baked_alpha',D)]+[(k,U) for k in [
 'source_unchanged','present_unchanged','gpu_pending','width_selector','height_selector','format_selector','type_selector',
 'scheduled_before','scheduled_after','stream_before','stream_after','capture_witness','prepare_idle_permit',
 'command','command_sequence','command_claimed','command_ack','command_result','active_command','dispatch_calls']]+[('control_us',D),('first_order_qualifier',U)]
CaptureV1=Capture
class Capture(CaptureV1):
 _fields_=[('birth_token',U),('client_context',U),('client_id',I),('client_commit_sequence',I),('client_transaction_seed',I),('client_included',I)]
assert ctypes.sizeof(Capture)==720 and Capture.engine.offset==0x28 and Capture.source.offset==0xf0

GEOMETRY_FIELDS=['invert', 'affine', 'apply_rect', 'transform_region', 'combined_shape', 'adopt_shape', 'intersection', 'region_union', 'region_empty', 'retain_cf', 'release_cf', 'display_rgb', 'native_display_rgb', 'substitute', 'features', 'colorspace', 'update_region', 'added_contexts', 'invalidate_backdrops', 'clip_backdrops', 'scale', 'accelerator', 'hdr', 'bit_depth', 'offset', 'display']
RENDER_FIELDS=['callbacks', 'new_renderer', 'destroy_renderer', 'destination', 'release_destination', 'prepare_layers', 'empty_shape', 'free_shape', 'textures', 'render_options', 'get_state', 'set_state', 'flush', 'begin_update', 'finish_update', 'isolated', 'hosted', 'skip_backdrops', 'use_skylight_attributes', 'attributes_from_state', 'attributes', 'vbl_time', 'interval', 'displays', 'get_protection', 'protection', 'get_flags', 'add_flags', 'get_time', 'greedy', 'ignore_flatten_cache', 'flatten_backdrops', 'create_flatten_surface', 'lock_context', 'unlock_context', 'root', 'assign_root', 'add_context']
SELECTOR_FIELDS=['texture_2d', 'storage', 'usage', 'hazards', 'new_texture', 'command_buffer', 'pass_descriptor', 'attachments', 'attachment_at', 'attachment_texture', 'load', 'store', 'clear', 'render_encoder', 'end', 'commit', 'device', 'read_bytes']
class Geometry(ctypes.Structure): _fields_=[(name,U) for name in GEOMETRY_FIELDS]
class Render(ctypes.Structure): _fields_=[('geometry',Geometry)]+[(name,U) for name in RENDER_FIELDS]
class Selectors(ctypes.Structure): _fields_=[(name,U) for name in SELECTOR_FIELDS]
class RGBA(ctypes.Structure):
 _fields_=[('pc',Capture),('magic',U),('size',I),('version',I),('api',Render),('sel',Selectors)]+[(k,U) for k in [
 'texture_class','pass_class','renderer','metal','queue','device','clear_buffer','update','root',
 'shared_renderer','shared_metal','shared_queue']]+[(k,I) for k in [
 'clear_status','clear_submitted','render_called','sealed','normal_wrapper_sequence','own_wrapper_sequence','own_client_sequence','inclusion',
 'original_nodes','prepared_nodes','selected_type','destination_flags','last_own_status','destroyed','command_buffer_bound','source_flags']]+[
 ('encode_us',D),('readback',U),('readback_capacity',U),('readback_bytes',U),('readback_stride',U),('readback_count',I),('readback_error',I)]

class ClientAPI(ctypes.Structure): _fields_=[(n,U) for n in ["map_vtable","map","transform_set"]]
class RGBA(RGBA):
 _fields_=[("client_api",ClientAPI)]+[(n,I) for n in ["content_mode","client_nodes","client_reason","cohort_contexts"]]+[("client_mapping",D*16)]

class ViewAPI(ctypes.Structure):
 _fields_=[(n,U) for n in ['create','bind_local','shape','empty_region','event_shape','no_shadow','depth','resolution','order','display_id','manager','geometry_seed','changed_seed','manager_vtable','layer_id','lookup_handle','effective_alpha']]
class View(ctypes.Structure):
 _fields_=[('magic',U),('size',I),('version',I),('capture',U),('api',ViewAPI)]+[(n,U) for n in ['window','context','root','body','texture']]+[(n,I) for n in ['wid','context_id','bound','prepared','shown','retired','reason','qualified']]+[(n,D*4) for n in ['target','current','display_bounds']]+[(n,D) for n in ['alpha','current_alpha','source_w','source_h','scale']]+[(n,I) for n in ['display','geometry_seed','changed_seed','suspended']]+[(n,U) for n in ['observations','mutations','source_creator','source_pid_version']]+[('source_wid',I),('presentation_mode',I)]+[(n,U) for n in ['command','sequence','claimed','ack','active']]+[('result',ctypes.c_int),('pre_display',I),('commit_checks',U),('commit_sequence',I),('committed',I),('render_seed',I),('commit_pad',I)]

MODEL_FIELDS=['allocate','copy_layer','release','new_array','sublayers','animations','modifiers','remote_effects','number','corner_contents','corner_center','corner_radii','mask','filters','compositing_filter']
class ModelAPI(ctypes.Structure): _fields_=[(n,U) for n in MODEL_FIELDS]
class Model(ctypes.Structure):
 _fields_=[('magic',U),('size',I),('version',I),('api',ModelAPI),('layer_id',U),('lookup_handle',U)]+[(n,I) for n in ['reason','nodes','copies','clock_contexts','witness','pad']]+[('clock_before',U),('clock_after',U)]
class RGBA(RGBA): _fields_=[('model',U)]
assert ctypes.sizeof(RGBA)==1776 and RGBA.model.offset==1768
assert ctypes.sizeof(Model)==192 and 2048+ctypes.sizeof(Model)<4096

# v3 append-only client domain; previous RGBA layout remains available for typed retirement.
LegacyRGBA=RGBA
class ClientDomain(ctypes.Structure):
 _fields_=[('bounds',D*4),('mapped',D*4),('pixel_width',U),('pixel_height',U)]+[(n,I) for n in ['client_id','commit_sequence','selected','gpu_complete']]
class RGBA(LegacyRGBA):
 _fields_=[('domain',ClientDomain)]
assert ctypes.sizeof(ClientDomain)==96 and ctypes.sizeof(RGBA)==1872 and RGBA.domain.offset==1776
assert ctypes.sizeof(View)==496

V4RGBA=RGBA
class RGBA(V4RGBA):
 _fields_=[("locked_client",U),("quarantined",I),("lock_pad",I)]
assert ctypes.sizeof(RGBA)==1888
class NormalBinding(ctypes.Structure):
 _fields_=[("magic",U),("size",I),("version",I),("capture",U),("prepare_return",U*2),("composite_return",U*2)]+[(n,U) for n in ["inflight","calls","admitted","misses"]]+[(n,I) for n in ["reason","dead"]]

class Ordinary(ctypes.Structure):
 _fields_=[("magic",U),("size",I),("version",I),("capture",U)]+[(n,U) for n in ["command","sequence","ack"]]+[(n,I) for n in ["enabled","cursor","candidate","reason"]]+[(n,D) for n in ["expires","next_capture","started"]]+[(n,U) for n in ["promoted","refused","retries"]]+[("seen",D*64)]+[(n,U) for n in ["renderer_bytes","renderer_frames","renderer_recycles","budget_refusals"]]+[("candidate_color",U)]+[("retry_successes",U),("capture_generation",U),("capture_time",D),("good_time",D*64),("native_time",D*64),("completion_queued",I),("completion_polls",I),("completion_deadline",D),("fast_promoted",U),("completion_generation",U)]

class BeginSource(ctypes.Structure):
 _fields_=[(n,U) for n in ['window','creator','birth','root','token']]+[(n,D) for n in ['time','issued_max']]+[(n,U) for n in ['serial','good_serial']]+[(n,I) for n in ['seed','valid']]
class BeginBinding(ctypes.Structure):
 _fields_=[('magic',U),('size',I),('version',I),('capture',U),('returns',U*2),('parent_return',U)]+[(n,I) for n in ['dead','claiming']]+[(n,U) for n in ['calls','issued','takeovers','refused','candidate_serial','candidate_token']]+[('candidate_time',D),('candidate_seed',I),('candidate_slot',I),('source',BeginSource*64)]
assert ctypes.sizeof(BeginSource)==80 and ctypes.sizeof(BeginBinding)==5240

class Carrier(ctypes.Structure):
 _fields_=[('magic',U),('size',I),('version',I),('capture',U)]+[(n,U) for n in ['storage','slots','slide','primary_space','copy_spaces','contains','add_space','remove_space']]+[(n,I) for n in ['depth','preparing','dead','before_slot']]+[(n,U) for n in ['passes','claims','restores','refused']]
assert ctypes.sizeof(Carrier)==136

class Drawing(ctypes.Structure):
 _fields_=[('magic',U),('size',I),('version',I),('capture',U),('storage',U),('slots',U)]+[(n,U) for n in ['damage','schedule','bounds','layer_to_window','concat','clone_return','scene_start','scene_end']]+[('dead',I),('pad',I)]+[(n,U) for n in ['content','frame','viewports','sources','refused']]+[('command_cursor',I),('command_seen',I)]
class DrawSlot(ctypes.Structure):
 _fields_=[(n,U) for n in ['window','creator','birth','root','region']]+[('envelope',D*4)]+[(n,U) for n in ['epoch','viewport_epoch','viewport_state']]+[('viewport',D*4),('claimable',I),('pad',I)]+[(n,U) for n in ['request','claim_request','claim_epoch']]+[('future',D*4),('deadline',D),('last_receipt',D),('phase',I),('claim_commit',I),('claim_frame',D*4)]
assert ctypes.sizeof(Drawing)==160 and ctypes.sizeof(DrawSlot)==248

class CloseProfile(ctypes.Structure):
 _fields_=[(name,U) for name in ['callback_pc','notification_pc','order_pc','key','string_type','get_property','string_bytes']]
class CloseControl(ctypes.Structure):
 _fields_=[('magic',U),('size',I),('version',I),('capture',U),('storage',U),('slots',U)]+[(name,U) for name in ['prepared','shown','adoptions','refused']]+[
  ('rejected_wid',I*32),('rejected_source',U*32),('rejected_stamp',D*32)]
class AcceptedCloseControl(ctypes.Structure):
 _fields_=[('magic',U),('size',I),('version',I),('capture',U),('storage',U),('slots',U)]+[(name,U) for name in ['prepared','shown','adoptions','refused','binding_sequence']]+[('profile',CloseProfile),
  ('epoch',U*2),('callback_depth',U),('policy_expires',D),('armed',I),('dead',I),('publication_tail',I),('publication_head',I)]
assert ctypes.sizeof(CloseProfile)==56 and ctypes.sizeof(CloseControl)==712
assert AcceptedCloseControl.profile.offset==80 and ctypes.sizeof(AcceptedCloseControl)==184


def control_image(engine,address,code,symbols,sl,qc,native_symbol,scene_extent,close_profile):
    data=bytearray(65536)
    def fresh(location,content):
        offset=location-address
        if offset<0 or offset+len(content)>len(data):
            raise ValueError('Native control partition overflow')
        data[offset:offset+len(content)]=content
    fn={'anim_rgba_frame':code+symbols['_anim_rgba_normal_present_frame']}
    g=RGBA();p=g.pc;p.magic=0x31484341434d5748;p.size=720;p.version=1;p.engine=engine
    p.node[1]=fn['anim_rgba_frame'];p.node[2]=address
    g.magic=0x31414247524d5748;g.size=ctypes.sizeof(g);g.version=5;g.content_mode=3
    pointer_offsets=[]
    def field(obj,ctype,name,value,base_offset=0):
     setattr(obj,name,value);pointer_offsets.append(base_offset+getattr(ctype,name).offset)
    for name,symbol in [('is_main','pthread_main_np'),('thread_self','pthread_self'),('stack_top','pthread_get_stackaddr_np'),('stack_size','pthread_get_stacksize_np'),('retain_obj','objc_retain'),('release_obj','objc_release')]:
     field(p,Capture,name,native_symbol(symbol,'libobjc.A.dylib' if symbol.startswith('objc_') else 'libsystem_pthread.dylib'))
    for name,native in [('generate',0x186e19454),('populate',0x187086fc4),('free_layers',0x186e1bbdc),('release_enumerator',0x186ef2790),('compositor',0x186e96f80),('texture',0x186dba5bc)]:field(p,Capture,name,native+sl)
    pointer_offsets.append(Capture.node.offset+8)
    p.session_control=0x1ea5fb550+sl;p.native_flags=0x1ea5f6068+sl;p.native_capture_flag=0x1ea5fa3f2+sl
    p.expected_texture=0x186dba5bc+sl;p.expected_context_count=0x186dba64c+sl;p.expected_capture_backing=0x187086c5c+sl
    p.cohort_pc[:]=[v+sl for v in [0x186f4096c,0x186f404a8,0x186f40508,0x187109080,0x186e134c0]]
    gm={'invert':(qc,0x18a87cd5c),'affine':(qc,0x18a87ce08),'apply_rect':(qc,0x18a87d124),'transform_region':(sl,0x186ed8684),
        'combined_shape':(sl,0x186e98170),'adopt_shape':(sl,0x1871be2b8),'intersection':(sl,0x1871bb088),'region_union':(sl,0x1871bb0a8),
        'region_empty':(sl,0x1871bb1f8),'retain_cf':(sl,0x1871ba128),'release_cf':(sl,0x1871ba118),'display_rgb':(sl,0x1871ba848),
        'substitute':(qc,0x18a7cc22c),'features':(qc,0x18a7ca8dc),'colorspace':(qc,0x18a7ca904),'update_region':(qc,0x18a7cac5c),
        'added_contexts':(qc,0x18a7b8170),'invalidate_backdrops':(qc,0x18a7b84d4),'clip_backdrops':(qc,0x18a7b852c),
        'scale':(qc,0x18a7cacc8),'accelerator':(qc,0x18a7cbd30),'hdr':(qc,0x18a7cbc94),'bit_depth':(qc,0x18a7cc228),
        'offset':(qc,0x18a7cad18),'display':(qc,0x18a7caccc)}
    for name,(bias,native) in gm.items():field(g.api.geometry,Geometry,name,native+bias,RGBA.api.offset)
    g.api.geometry.native_display_rgb=0x1ea5fac68+sl
    rm={'new_renderer':(qc,0x18a7ca7bc),'destroy_renderer':(qc,0x18a7caa14),'destination':(sl,0x186ee4768),
        'release_destination':(sl,0x186d6c0e0),'prepare_layers':(sl,0x186e96b40),'empty_shape':(sl,0x1871be3c8),'free_shape':(sl,0x1871be428),
        'textures':(qc,0x18a7cc2f4),'render_options':(qc,0x18a7cade8),'get_state':(qc,0x18a7cc274),'set_state':(qc,0x18a7cc294),
        'flush':(qc,0x18a6512cc),'begin_update':(qc,0x18a7b7a04),'finish_update':(qc,0x18a7bb178),'isolated':(qc,0x18a7b7f94),
        'hosted':(qc,0x18a7b7fb4),'skip_backdrops':(qc,0x18a7b7fd4),'use_skylight_attributes':(qc,0x18a7b7ff4),
        'attributes_from_state':(sl,0x186e2e148),'attributes':(qc,0x18a7bb5dc),'vbl_time':(qc,0x18a7b8014),'interval':(qc,0x18a7b801c),
        'displays':(qc,0x18a7bb264),'get_protection':(qc,0x18a7bb6f8),'protection':(qc,0x18a7bb6e8),'get_flags':(qc,0x18a7ba734),
        'add_flags':(qc,0x18a7ba7c0),'get_time':(qc,0x18a7bb110),'lock_context':(qc,0x18a76715c),'unlock_context':(qc,0x18a767164),
        'root':(qc,0x18a7673f4),'assign_root':(qc,0x18a65dc40),'add_context':(qc,0x18a677118)}
    for name,(bias,native) in rm.items():field(g.api,Render,name,native+bias,RGBA.api.offset)
    for name,symbol in [('greedy','CARenderUpdateSetGreedy'),('ignore_flatten_cache','CARenderUpdateSetIgnoreFlattenCache'),('flatten_backdrops','CARenderUpdateSetFlattenBackdrops'),('create_flatten_surface','CARenderUpdateSetCanCreateFlattenSurface')]:
     field(g.api,Render,name,native_symbol(symbol,'QuartzCore'),RGBA.api.offset)
    g.client_api.map_vtable=0x1eeecd7e8+qc
    for name,native in [('map',0x18a67a5ac),('transform_set',0x18a67ed14)]:
     field(g.client_api,ClientAPI,name,native+qc,RGBA.client_api.offset)
    g.api.callbacks=0x1ea687f50+qc
    assert all(getattr(g.api.geometry,name) for name in GEOMETRY_FIELDS) and all(getattr(g.api,name) for name in RENDER_FIELDS)
    model=Model();model.magic=0x314c444f4d4d5748;model.size=ctypes.sizeof(model);model.version=1
    model_api={'allocate':0x18a6ee220,'copy_layer':0x18a67a430,'release':0x18a6af610,'new_array':0x18a626418,
     'sublayers':0x18a626548,'animations':0x18a770f60,'modifiers':0x18a70ac80,'remote_effects':0x18a70adb8,
     'number':0x18a67ab48,'corner_contents':0x18a62e464,'corner_center':0x18a62e3c8,'corner_radii':0x18a70c890,
     'mask':0x18a629de0,'filters':0x18a626e3c,'compositing_filter':0x18a622358}
    for name,native in model_api.items():field(model.api,ModelAPI,name,native+qc,2048+Model.api.offset)
    for name,native in [('layer_id',0x18a898850),('lookup_handle',0x18a6731d8)]:field(model,Model,name,native+qc,2048)
    g.model=address+2048;fresh(g.model,bytes(model))
    normal=NormalBinding();normal.magic=0x314c414d524f4e52;normal.size=ctypes.sizeof(normal);normal.version=1;normal.capture=address
    normal.prepare_return[:]=[0x186f40598+sl,0x186f405c0+sl];normal.composite_return[:]=[0x186f404a8+sl,0x186f40508+sl]
    fresh(address+12288,bytes(normal))
    begin=BeginBinding();begin.magic=0x314e494745425252;begin.size=ctypes.sizeof(begin);begin.version=1;begin.capture=address
    begin.returns[:]=[0x186e18850+sl,0x186e18bf4+sl];begin.parent_return=0x186e1058c+sl;begin.candidate_slot=64
    fresh(address+57344,bytes(begin))
    carrier=Carrier();carrier.magic=0x3152454952524143;carrier.size=ctypes.sizeof(carrier);carrier.version=2;carrier.capture=address;carrier.slide=sl
    carrier_api={'primary_space':0x186ea3618,'copy_spaces':0x186ea3754,'contains':0x186e327e4,'add_space':0x186e406e8,'remove_space':0x186e40750}
    for name,native in carrier_api.items():field(carrier,Carrier,name,native+sl,10240)
    fresh(address+10240,bytes(carrier))
    drawing=Drawing();drawing.magic=0x31474e4957415244;drawing.size=ctypes.sizeof(drawing);drawing.version=1;drawing.capture=address
    drawing_api={'damage':(sl,0x186e0925c),'schedule':(sl,0x186f94e5c),'bounds':(sl,0x1871bb198),'layer_to_window':(sl,0x18705f03c),'concat':(qc,0x18a65bd2c)}
    for name,(bias,native) in drawing_api.items():field(drawing,Drawing,name,bias+native,11264)
    drawing.clone_return=code+symbols['_display_native_clone']+0x60;drawing.scene_start,drawing.scene_end=scene_extent
    fresh(address+11264,bytes(drawing))
    view_address=address+4096
    v=View();v.magic=0x31574549564d5748;v.size=ctypes.sizeof(View);v.version=5;v.capture=address;v.pre_display=0
    v.alpha=1;v.presentation_mode=0
    raw={'create':0x187068b1c,'bind_local':0x187060638,'shape':0x18706fd98,'empty_region':0x1871bb068,
     'event_shape':0x18706f304,'no_shadow':0x18706e764,'depth':0x18706d448,'resolution':0x187074ab0,
     'order':0x18705d11c,'display_id':0x187074060,'manager':0x18710fab8,'geometry_seed':0x18713b2f0,'changed_seed':0x18713b0a8,'layer_id':0x18a898850,'lookup_handle':0x18a6731d8,'effective_alpha':0x1870735d4}
    for name,native in raw.items():field(v.api,ViewAPI,name,native+(qc if name in ['layer_id','lookup_handle'] else sl),4096+View.api.offset)
    v.api.manager_vtable=0x1eece0090+sl;fresh(view_address,bytes(v))
    ordinary=Ordinary();ordinary.magic=0x315952414e494452;ordinary.size=ctypes.sizeof(ordinary)
    ordinary.version=1;ordinary.capture=address;ordinary.candidate=64
    fresh(address+12800,bytes(ordinary))
    legacy=CloseControl();legacy.magic=0x3145534f4c434752;legacy.size=ctypes.sizeof(legacy);legacy.version=1;legacy.capture=address
    fresh(address+6144,bytes(legacy))
    close=AcceptedCloseControl();close.magic=0x314c434143475252;close.size=ctypes.sizeof(close);close.version=1;close.capture=address
    for name in ['callback_pc','notification_pc','order_pc','key','string_type']:setattr(close.profile,name,close_profile[name])
    field(close.profile,CloseProfile,'get_property',close_profile['get_property'],7168+AcceptedCloseControl.profile.offset)
    field(close.profile,CloseProfile,'string_bytes',native_symbol('CFStringGetCString','CoreFoundation'),7168+AcceptedCloseControl.profile.offset)
    fresh(address+7168,bytes(close))
    fresh(address,bytes(g))
    if len(pointer_offsets)!=len(set(pointer_offsets)):
        raise ValueError('Overlapping native function cells')
    for offset in pointer_offsets:
        value=int.from_bytes(data[offset:offset+8],'little')
        if offset%8 or not 0x100000000<=value<0x800000000000:
            raise ValueError('Invalid unsigned native function address')
    return bytes(data),pointer_offsets
