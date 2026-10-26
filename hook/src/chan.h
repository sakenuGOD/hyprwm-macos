// Shared memory between daemon and WindowServer engine (/tmp/hyprwm/chan, MAP_SHARED mmap on both sides).
// Daemon writes commands to the cmd ring and publishes cmd_head with one atomic release store:
// the engine applies everything published together in ONE tick with a shared t0,
// as in Hyprland, where all variables for one event start in the same tick.
// Engine writes window state (wins), events (evt), and heartbeat (ticks/now).
#pragma once

typedef unsigned int u32;
typedef unsigned long long u64;

#define CH_MAGIC  0x3531574d52505948ULL   // "HYPRWM15"
#define CH_NW     64
#define CH_NCURVE 16
#define CH_INSTANT CH_NCURVE   // deliberately outside curve table; curve 0 is a real user curve
#define CH_NCMD   256
#define CH_NEVT   128
#define CH_BAKED  255
#define CH_NTRAJ  256
#define CH_NCONN  32

enum { CV_NONE = 0, CV_BEZIER = 1, CV_SPRING = 2 };
enum { OP_GEOM = 1, OP_ALPHA = 2, OP_FORGET = 3, OP_WARP = 4, OP_UNDER = 5, OP_SPACE = 6, OP_FILL = 7, OP_RAISE = 8, OP_SNAP = 9, OP_CFG = 10, OP_EDGE = 11, OP_EFFECTS = 12, OP_SHADOW = 13, OP_BIRTH = 14 };
// Advertised by the native consumer, never by a channel writer or old engine.
#define CH_CAP_EFFECTS 0x80000000u
#define CH_CAP_SHADOW 0x40000000u
#define CH_CAP_SNAPSHOT 0x20000000u // Atomic old-buffer underlay; absent on older consumers.
#define CH_CAP_SNAPSHOT_COVER 0x10000000u // Full frozen cover + typed acquisition/configure/handoff receipts.
#define CH_CAP_TERMINAL_MOVE 0x08000000u // Live geometry transfers native origin at its final WS frame.
#define CH_CAP_BIRTH 0x04000000u // Native first-order custody; absent until its consumer is installed.
#define CH_CAP_ORDINARY_PREPARE 0x02000000u // Actual old-R OWN adoption before a geometry batch.
#define CH_CAP_VIEWPORT 0x01000000u // Live 1:1 source pan beneath a fixed tile.
#define CH_VIEWPORT 0x56504557u
// Versioned OP_EDGE extension. Old consumers reject flags>2 without mutation.
#define CH_ORDINARY_PREPARE 0x4f574e50u
// pad0/pad1: UInt64 request nonce; cpos: 1 prepare, 0 cancel; xywh: future goal.
// EV_ORDINARY: x/y nonce halves; w: 1 adopted, 2 restored, 3 refused; h: version1.
// BIRTH preserves the channel ABI. pad0/pad1 are the exact low/high token halves.
// ARM uses that pair as policy epoch and x as heartbeat lifetime. Other per-window
// commands use the native birth token. CLAIM carries geometry AND alpha together.
// The consumer validates token/epoch before any native geometry/alpha mutation.
#define CH_BIRTH_ACTION_MASK 0xff000000u
enum { BIRTH_ARM=0x01000000u, BIRTH_DISARM=0x02000000u, BIRTH_PREPARE=0x03000000u,
       BIRTH_CLAIM=0x04000000u, BIRTH_CANCEL=0x05000000u, BIRTH_ACK=0x06000000u, BIRTH_QUERY=0x07000000u };
enum { BIRTH_HELD=1, BIRTH_PREPARING=2, BIRTH_READY=3, BIRTH_PRESENTING=4,
       BIRTH_REVEALED=5, BIRTH_CANCELLED=6, BIRTH_GONE=7, BIRTH_CONFLICT=8 };
// EDGE: flags=1 prepare, 2 grant an ACKed prepare, 0 revoke; x=exact integer nonce;
// y on grant is actual client ACK timestamp+2s (monotonic seconds).
// Production permission is independent of a per-window client preparation grant.
#define CH_EDGE_PERMISSION 0xffffffffu
   // CFG: explicit frame/cancel (w=h=0); F_NATIVE also sends intermediate frames via this CAP6 transport.
#define CH_CFG_NOTIFY 0x7f17     // WS -> application notification type
#define CH_CFG_MAGIC  0x47464348u // "HCFG"
#define CH_STREAM_NOTIFY 0x7f18u  // additive configure-only bridge; distinct from retained CAP5 callback
#define CH_STREAM_MAGIC 0x47464353u // "SCFG"
struct ch_cfgmsg { u32 magic, wid; double x, y, w, h; double t0; };   // payload (0x30)
   // SNAP: window snapshot below it during motion (shrinking: preserve old content where the box exceeds the new buffer)
   // RAISE: above window k.flags (wid; 0 = above all at its level), without activation; active above neighbors (Hyprland)
   // FILL: k.flags = RGBA8 window edge color (0 = none): fills empty band B-A (edge extension); UNDER: k.flags = backdrop wid
   // SPACE: move window to desktop (k.x = desktop id) inside WS; client SLSMoveWindowsToManagedSpace cannot move foreign windows
enum { F_FROM = 1, F_MOVE = 2, F_STRETCH = 4, F_WAIT = 8, F_HOLD = 16, F_NATIVE = 32, F_STREAM = 64, F_EDGE = 128, F_SNAPSHOT = 256, F_MOVE_END = 512 }; // MOVE_END: keep native origin until live visual geometry completes.
   // STRETCH: stretch content to B (opening, like m_animatingIn); OP_GEOM / OP_ALPHA flags
enum { EV_GONE = 1, EV_SETTLED = 2, EV_DONE = 3, EV_NEW = 4, EV_MOVED = 5, EV_REL = 6, EV_CLONE = 7, EV_ERROR = 8, EV_SNAPSHOT = 9, EV_BIRTH = 10, EV_ORDINARY = 11, EV_VIEWPORT = 12 };
// VIEWPORT: x/y nonce halves, w/h actual offsets. Reset reports zero offsets.
// BIRTH: x/y exact UInt32 token halves, w creator PID, h BIRTH_* state. The
// native pending table remains authoritative; retry publication until state ACK.
enum { SNAP_ACQUIRED=1, SNAP_DEFERRED=2, SNAP_REVEALED=3, SNAP_CANCELLED=4, SNAP_CONFIGURED=5 };
// SNAPSHOT: source WID; x=clone WID, y=result, w=pending mode(3=cover), h=positive epoch.
enum { ERR_SLOT = 1, ERR_CFG_OWNER = 2, ERR_SPACE_ABI = 3, ERR_SPACE_TARGET = 4, ERR_CMD_RING = 5 };
// ERROR: exact failing opcode in x (0 for ring overflow), reason in y,
// monotonically increasing error counter in w; WID is 0 for ring overflow.
   // REL: window released (0x3e9): x = on screen (bit 44), y = has owner, w = level, h = our slot (1) / geo (2)
   // CLONE: close snapshot displayed (wid = clone, x = source window); MOVED: idle window left target (x,y,w,h = A)
   // NEW: server window appeared (increasing ids); DONE: visible window animations ended (B = target)

struct ch_curve {                // 0x1010
    u32 type, pad;
    double mass, k, d;           // spring
    double bx[CH_BAKED], by[CH_BAKED];   // bezier: baked points t=(i+1)/255, matching hyprutils
};

struct ch_cmd {                  // 0x88
    u32 op, wid, flags, cpos, csize, calpha, pad0, pad1;
    double x, y, w, h;           // target (global pt, top-left origin)
    double fx, fy, fw, fh;       // source (F_FROM)
    double dpos, dsize, dalpha;  // bezier duration, seconds (speed*100 ms)
    double a, fa;                // alpha: target / source (F_FROM)
};

struct ch_var {                  // 0x70
    double b[2], g[2], v[2];     // begun / goal / value
    double sv, svel;             // normalized spring value and velocity
    double t0, last, dur;        // start, last spring step, bezier duration
    u32 curve, active;
};

struct ch_win {                  // 0x1e8
    u32 wid, used, settling, clipped;   // clipped: server clip follows visible frame
    struct ch_var pos, size, alpha;
    double ax, ay, aw, ah;       // actual server window frame (last tick)
    double m[4];                 // applied transform: sx, sy, tx, ty
    double done_t;               // when animations ended (waiting for application size)
    double cur_alpha;            // applied alpha
    double clip[4];              // last applied clip (global pt)
    u32 stretch, under;          // stretch: content to B (opening); under: backdrop wid (0 = none)
    double um[4];                // applied backdrop transform
    double ualpha;               // applied backdrop alpha
    double radius;               // server window corner radius (resolved_corner_radius)
    double pa[4];                // previous tick's A
    u32 stable, rset;            // stable: consecutive ticks with unchanged A; rset: engine applied Hyprland radius
    double a0[2];                // buffer size at animation start (old application frame)
    u32 held, needs;             // held: awaiting batch start; needs: awaiting application frame at new size
    u32 geo, moved;              // geo: 0=unowned, 1=visual, 2=native stream, 3=live edge, 4=terminal native-origin move; moved: EV_MOVED already sent
    double ub[6];                // last backdrop clip: B (x,y,w,h) and visible buffer area (w,h)
    u32 wait, fill;              // wait: 1=F_WAIT frame readiness, 2=unclaimed prehide lease (≤150ms); fill: RGBA8
    double wait_t;               // when waiting started
    u64 mask;                    // mask CALayer on window Hosting layer (0 = none); lives in WS
    double mrect[2];             // applied visible size (cw, ch)
    double mhost[2];             // Hosting bounds when masking (y0, h): layer resizes after window shape
    struct ch_var act;           // P6: active border progress 0..1 (border curve, 600 ms crossfade)
    u64 bl_in, bl_act;           // hidden compatibility ring, single visible gradient (colors interpolate on focus)
    double bframe[4];            // applied border rectangle in Server root coordinates
    double bop;                  // applied active layer opacity
    struct ch_var sact;          // active shadow progress 0..1 (fadeShadow, 800 ms)
    u64 bl_sh;                   // shadow layer (under system Shadow), ring mask (shadow outside window)
    double sop;                  // applied shadowOpacity
    u64 bl_fill;                 // CAShapeLayer filling empty band B-A (edge color, under content)
    double fkey[5];              // applied bw, bh, aw, ah, color; recalculate path only on change
};

// P6: focus border (general.col.*, border_size, rounding). Daemon writes, engine reads.
struct ch_deco {
    u32 on, focus;               // focus: active window wid (0 = none)
    u32 curve, ngrad;            // border curve; gradient color count (<=8, baked in OkLab by daemon)
    double dur, width, radius;   // crossfade duration, seconds; border width, pt; window radius, pt (outer = radius+width)
    double grad[8][4];           // RGBA (sRGB, not premultiplied)
    double inact[4];             // inactive border
    double start[2], end[2];     // CAGradientLayer startPoint/endPoint (unit layer coordinates, Y axis upward)
    u32 nofull, only;            // nofull: borderless window (fullscreen); only: border only on this window (test)
    u32 sh_on, scurve;           // custom shadow (decoration.shadow); fadeShadow curve
    double sdur, srad, soff;     // crossfade duration; shadowRadius (sigma); downward offset, pt
    double sop_act, sop_in;      // active/inactive shadowOpacity (color alpha x Gaussian density)
    u32 sys_off, inset10;        // sys_off: suppress system window shadow/outline; inset10: ring extends inward by N/10 pt
                                 // (covers the bright inner outline drawn by the application itself on Tahoe)
    double bez[4], sbez[4];      // border/shadow crossfade curves (cubic-bezier x1,y1,x2,y2), CABasicAnimation in CA
};

struct ch_evt { u32 type, wid; double t, x, y, w, h; };   // 0x30

struct ch_hdr {                  // 0x100
    u64 magic;
    u32 version, size;
    u32 cmd_head;                // daemon writes (release)
    u32 cmd_tail;                // engine writes
    u32 evt_head;                // engine writes (release)
    u32 evt_tail;                // daemon writes
    u32 ticks, frames;           // engine heartbeat
    double now;                  // last tick time (SLSCurrentRealTime)
    u32 nactive, errors;
    double idle_poll;            // idle command polling interval, seconds
    double settle;               // time to wait for application to accept final size, seconds
    double settle_px;            // size tolerance, pt (terminal character grid)
    u32 stop, applied;           // stop: engine stops rescheduling itself; applied: set_xform count
    double last_dt;
    double phase;                // tick phase within frame: fraction of period after vblank
    double period;               // vblank period, seconds (from WS cache)
    double margin;               // te = first vblank after now+margin
    double te;                   // presentation time used to calculate last frame
    u32 wid_max, holding;        // wid_max: highest window id seen; holding: batch awaiting application frames
    double hold_t;               // when batch started waiting
    double hold_max;             // time to wait for application frame, seconds (then start anyway)
    double tick_us_last, tick_us_max;   // tick cost (mach ticks -> microseconds via timebase, computed by engine)
    u32 ticks_late, te_skips;    // tick later than 0.6*T after vblank; te step != T during animation
    u32 traj_head, pad_t;        // 0=off; WID=device gate; CH_EDGE_PERMISSION=per-window grants
    double te_prev;              // te of previous animated tick
    u32 use_mask, mask_only;     // P4: clip B with mask in window CA tree instead of screen clip; mask_only: only this window
    u32 mask_flip, mask_errs;    // mask_flip: layer Y axis upward (y = h - ch); mask_errs: failed tree lookup count
    u64 reserved[5];
};

struct ch_traj { double te; u32 wid, pad; double bx, by, bw, bh, alpha; };   // 0x38

struct ch {
    struct ch_hdr h;
    struct ch_curve curve[CH_NCURVE];
    struct ch_cmd cmd[CH_NCMD];
    struct ch_evt evt[CH_NEVT];
    struct ch_win win[CH_NW];
    struct ch_traj traj[CH_NTRAJ];
    // Connections (CGXConnection*) of applications whose windows were tiled by the engine: a new level-0 window
    // from one is hidden on its creation tick (daemon decides popin or show); engine writes.
    u64 conn[CH_NCONN];
    u32 conn_next, prehide;      // prehide: enabled by daemon
    struct ch_deco deco;
};
