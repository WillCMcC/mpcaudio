/*
 * mpc_uac2_tee.so — LD_PRELOAD shim for the Akai MPC app (MPC 3.9.1, Gen 1).
 *
 * Copies everything the MPC app writes to its main output (the internal "ACVA" codec) into the
 * USB-B UAC2 gadget playback PCM ("hw:UAC2Gadget,0"), so a host computer records the MPC's main
 * mix while the built-in outs keep working. Nothing is changed in what the app plays itself.
 *
 *  - Real-time path (the app's audio thread) only does a memcpy into a lock-free SPSC ring.
 *  - A worker thread drains the ring into the gadget, (re)opens it when the gadget appears,
 *    recovers xruns, and corrects clock drift between the codec and the USB host by slipping
 *    one frame now and then (+-226 ppm max).
 *  - If the gadget isn't up, or formats don't match, the shim stays passive.
 *
 * Env: MPC_TEE=0 disables; MPC_TEE_SRC=ACVA (source card id); MPC_TEE_DST=hw:UAC2Gadget,0;
 *      MPC_TEE_GADGET=/sys/kernel/config/usb_gadget/mpcuac2 (only feed the gadget while THIS exists,
 *      so the shim never touches the app's own controller-mode gadget "smexstream");
 *      MPC_TEE_TARGET=768 (target total buffered frames: ring + gadget queue); MPC_TEE_LOG=/tmp/mpc-uac2-tee.log
 *      Test harness only: MPC_TEE_FORCE=1 (load outside /usr/bin/MPC), MPC_TEE_SRC_PCM=<pcm name to treat as main out>
 *
 * v2 (2026-10-18): v1 busy-looped at SCHED_FIFO when the host was not draining the gadget and froze the
 * MPC UI. The worker now always sleeps when idle and runs SCHED_OTHER (nice -5).
 *
 * Build: arm-linux-gnueabihf-gcc -O2 -fPIC -shared -o mpc_uac2_tee.so mpc_uac2_tee.c -ldl -lpthread
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/resource.h>
#include <sys/syscall.h>

/* ---- minimal ALSA ABI (opaque types; resolved with dlsym, no headers needed) ---- */
typedef struct _snd_pcm snd_pcm_t;
typedef struct _snd_pcm_hw_params snd_pcm_hw_params_t;
typedef struct _snd_pcm_sw_params snd_pcm_sw_params_t;
typedef struct _snd_pcm_info snd_pcm_info_t;
typedef long snd_pcm_sframes_t;
typedef unsigned long snd_pcm_uframes_t;
enum { SND_PCM_STREAM_PLAYBACK = 0 };
enum { SND_PCM_NONBLOCK = 1 };
enum { SND_PCM_ACCESS_RW_INTERLEAVED = 3 };

#define FN(ret, name, args) static ret (*p_##name) args
FN(int, snd_pcm_open, (snd_pcm_t **, const char *, int, int));
FN(int, snd_pcm_close, (snd_pcm_t *));
FN(int, snd_pcm_hw_params, (snd_pcm_t *, snd_pcm_hw_params_t *));
FN(snd_pcm_sframes_t, snd_pcm_writei, (snd_pcm_t *, const void *, snd_pcm_uframes_t));
FN(int, snd_pcm_hw_params_get_rate, (const snd_pcm_hw_params_t *, unsigned *, int *));
FN(int, snd_pcm_hw_params_get_channels, (const snd_pcm_hw_params_t *, unsigned *));
FN(int, snd_pcm_hw_params_get_format, (const snd_pcm_hw_params_t *, int *));
FN(int, snd_pcm_hw_params_get_access, (const snd_pcm_hw_params_t *, int *));
FN(int, snd_pcm_hw_params_malloc, (snd_pcm_hw_params_t **));
FN(void, snd_pcm_hw_params_free, (snd_pcm_hw_params_t *));
FN(int, snd_pcm_hw_params_any, (snd_pcm_t *, snd_pcm_hw_params_t *));
FN(int, snd_pcm_hw_params_set_access, (snd_pcm_t *, snd_pcm_hw_params_t *, int));
FN(int, snd_pcm_hw_params_set_format, (snd_pcm_t *, snd_pcm_hw_params_t *, int));
FN(int, snd_pcm_hw_params_set_channels, (snd_pcm_t *, snd_pcm_hw_params_t *, unsigned));
FN(int, snd_pcm_hw_params_set_rate, (snd_pcm_t *, snd_pcm_hw_params_t *, unsigned, int));
FN(int, snd_pcm_hw_params_set_buffer_size_near, (snd_pcm_t *, snd_pcm_hw_params_t *, snd_pcm_uframes_t *));
FN(int, snd_pcm_hw_params_set_period_size_near, (snd_pcm_t *, snd_pcm_hw_params_t *, snd_pcm_uframes_t *, int *));
FN(int, snd_pcm_sw_params_malloc, (snd_pcm_sw_params_t **));
FN(void, snd_pcm_sw_params_free, (snd_pcm_sw_params_t *));
FN(int, snd_pcm_sw_params_current, (snd_pcm_t *, snd_pcm_sw_params_t *));
FN(int, snd_pcm_sw_params_set_start_threshold, (snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t));
FN(int, snd_pcm_sw_params_set_avail_min, (snd_pcm_t *, snd_pcm_sw_params_t *, snd_pcm_uframes_t));
FN(int, snd_pcm_sw_params, (snd_pcm_t *, snd_pcm_sw_params_t *));
FN(int, snd_pcm_prepare, (snd_pcm_t *));
FN(int, snd_pcm_wait, (snd_pcm_t *, int));
FN(snd_pcm_sframes_t, snd_pcm_avail_update, (snd_pcm_t *));
FN(int, snd_pcm_info_malloc, (snd_pcm_info_t **));
FN(void, snd_pcm_info_free, (snd_pcm_info_t *));
FN(int, snd_pcm_info, (snd_pcm_t *, snd_pcm_info_t *));
FN(int, snd_pcm_info_get_card, (const snd_pcm_info_t *));
FN(int, snd_card_get_index, (const char *));
FN(const char *, snd_strerror, (int));

static int resolved;
static int resolve(void) {
    if (resolved) return resolved > 0;
#define R(name) do { p_##name = dlsym(RTLD_NEXT, #name); if (!p_##name) p_##name = dlsym(RTLD_DEFAULT, #name); if (!p_##name) { resolved = -1; return 0; } } while (0)
    R(snd_pcm_open); R(snd_pcm_close); R(snd_pcm_hw_params); R(snd_pcm_writei);
    R(snd_pcm_hw_params_get_rate); R(snd_pcm_hw_params_get_channels); R(snd_pcm_hw_params_get_format);
    R(snd_pcm_hw_params_get_access); R(snd_pcm_hw_params_malloc); R(snd_pcm_hw_params_free);
    R(snd_pcm_hw_params_any); R(snd_pcm_hw_params_set_access); R(snd_pcm_hw_params_set_format);
    R(snd_pcm_hw_params_set_channels); R(snd_pcm_hw_params_set_rate);
    R(snd_pcm_hw_params_set_buffer_size_near); R(snd_pcm_hw_params_set_period_size_near);
    R(snd_pcm_sw_params_malloc); R(snd_pcm_sw_params_free); R(snd_pcm_sw_params_current);
    R(snd_pcm_sw_params_set_start_threshold); R(snd_pcm_sw_params_set_avail_min); R(snd_pcm_sw_params);
    R(snd_pcm_prepare); R(snd_pcm_wait); R(snd_pcm_avail_update);
    R(snd_pcm_info_malloc); R(snd_pcm_info_free); R(snd_pcm_info); R(snd_pcm_info_get_card);
    R(snd_card_get_index); R(snd_strerror);
#undef R
    resolved = 1;
    return 1;
}

/* ---- config / logging ---- */
static int enabled = -1;           /* -1 unknown, 0 off, 1 on */
static const char *src_card = "ACVA";
static const char *dst_pcm = "hw:UAC2Gadget,0";
static long target_fill = 768;          /* target TOTAL buffered frames (ring + gadget queue), ~17 ms */
static const char *gadget_dir = "/sys/kernel/config/usb_gadget/mpcuac2";
static const char *src_pcm_name;    /* test only: match source by PCM name instead of card id */
#define DST_QUEUE (target_fill + 128) /* max frames queued in the gadget PCM (just above target: ~20 ms) */
#define IDLE_SLEEP_US 1500          /* worker sleeps this long whenever there is nothing to do */
static _Atomic unsigned long pushed_total, loops_total;
static FILE *logf_;
static pthread_mutex_t log_mx = PTHREAD_MUTEX_INITIALIZER;

static void tlog(const char *fmt, ...) {
    if (!logf_) return;
    pthread_mutex_lock(&log_mx);
    time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm);
    fprintf(logf_, "%02d:%02d:%02d ", tm.tm_hour, tm.tm_min, tm.tm_sec);
    va_list ap; va_start(ap, fmt); vfprintf(logf_, fmt, ap); va_end(ap);
    fputc('\n', logf_); fflush(logf_);
    pthread_mutex_unlock(&log_mx);
}

static int is_mpc_process(void) {
    char exe[256]; ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    if (n <= 0) return 0;
    exe[n] = 0;
    return strcmp(exe, "/usr/bin/MPC") == 0;
}

static void init_once(void) {
    if (enabled >= 0) return;
    const char *e = getenv("MPC_TEE");
    const char *force = getenv("MPC_TEE_FORCE");          /* test harness only */
    if ((e && strcmp(e, "0") == 0) || (!is_mpc_process() && !(force && *force == '1')) || !resolve()) { enabled = 0; return; }
    if (access("/data/mpc-uac2/disabled", F_OK) == 0 || access("/run/mpc-uac2/disabled", F_OK) == 0) { enabled = 0; return; }  /* kill switch */
    src_pcm_name = getenv("MPC_TEE_SRC_PCM");
    if ((e = getenv("MPC_TEE_SRC")) && *e) src_card = e;
    if ((e = getenv("MPC_TEE_DST")) && *e) dst_pcm = e;
    if ((e = getenv("MPC_TEE_TARGET")) && atol(e) > 32) target_fill = atol(e);
    if ((e = getenv("MPC_TEE_GADGET")) && *e) gadget_dir = e;
    const char *lp = getenv("MPC_TEE_LOG"); if (!lp) lp = "/tmp/mpc-uac2-tee.log";
    logf_ = fopen(lp, "a");
    tlog("mpc_uac2_tee loaded in pid %d (src=%s dst=%s target=%ld)", getpid(), src_card, dst_pcm, target_fill);
    enabled = 1;
}

/* ---- SPSC ring (frames) ---- */
#define RING_FRAMES 16384u          /* power of two, ~370 ms at 44.1k */
#define MAX_FRAME_BYTES 32u
static uint8_t ring[RING_FRAMES * MAX_FRAME_BYTES];
static _Atomic uint32_t wpos, rpos;
static unsigned frame_bytes;
static _Atomic unsigned long dropped_full;

static inline uint32_t ring_fill(void) { return atomic_load_explicit(&wpos, memory_order_acquire) - atomic_load_explicit(&rpos, memory_order_acquire); }

static void ring_push(const uint8_t *src, uint32_t frames) {          /* RT thread */
    uint32_t w = atomic_load_explicit(&wpos, memory_order_relaxed);
    uint32_t r = atomic_load_explicit(&rpos, memory_order_acquire);
    if (RING_FRAMES - (w - r) < frames) { atomic_fetch_add_explicit(&dropped_full, frames, memory_order_relaxed); return; }
    uint32_t i = w & (RING_FRAMES - 1), first = RING_FRAMES - i;
    if (first > frames) first = frames;
    memcpy(ring + (size_t)i * frame_bytes, src, (size_t)first * frame_bytes);
    if (frames > first) memcpy(ring, src + (size_t)first * frame_bytes, (size_t)(frames - first) * frame_bytes);
    atomic_store_explicit(&wpos, w + frames, memory_order_release);
    atomic_fetch_add_explicit(&pushed_total, frames, memory_order_relaxed);
}

static void ring_pop(uint8_t *dst, uint32_t frames) {                 /* worker */
    uint32_t r = atomic_load_explicit(&rpos, memory_order_relaxed);
    uint32_t i = r & (RING_FRAMES - 1), first = RING_FRAMES - i;
    if (first > frames) first = frames;
    memcpy(dst, ring + (size_t)i * frame_bytes, (size_t)first * frame_bytes);
    if (frames > first) memcpy(dst + (size_t)first * frame_bytes, ring, (size_t)(frames - first) * frame_bytes);
    atomic_store_explicit(&rpos, r + frames, memory_order_release);
}
static void ring_skip(uint32_t frames) { atomic_fetch_add_explicit(&rpos, frames, memory_order_release); }

/* ---- shared state between app threads and worker ---- */
static snd_pcm_t *_Atomic main_pcm;         /* the app's ACVA playback handle */
static _Atomic int active;                  /* RT path should push */
static _Atomic unsigned gen;                /* bumps on every (re)configuration */
static unsigned cfg_rate, cfg_channels; static int cfg_format;
static pthread_t worker_tid; static int worker_started;

static int pcm_card(snd_pcm_t *pcm) {
    snd_pcm_info_t *info; int card = -1;
    if (p_snd_pcm_info_malloc(&info) < 0) return -1;
    if (p_snd_pcm_info(pcm, info) >= 0) card = p_snd_pcm_info_get_card(info);
    p_snd_pcm_info_free(info);
    return card;
}

static snd_pcm_t *open_dst(unsigned rate, unsigned ch, int fmt, snd_pcm_uframes_t *out_buffer) {
    snd_pcm_t *pcm = NULL; int err;
    if ((err = p_snd_pcm_open(&pcm, dst_pcm, SND_PCM_STREAM_PLAYBACK, SND_PCM_NONBLOCK)) < 0) return NULL;
    snd_pcm_hw_params_t *hw; p_snd_pcm_hw_params_malloc(&hw);
    snd_pcm_uframes_t buf = 2048, per = 128; int dir = 0;
    if ((err = p_snd_pcm_hw_params_any(pcm, hw)) < 0 ||
        (err = p_snd_pcm_hw_params_set_access(pcm, hw, SND_PCM_ACCESS_RW_INTERLEAVED)) < 0 ||
        (err = p_snd_pcm_hw_params_set_format(pcm, hw, fmt)) < 0 ||
        (err = p_snd_pcm_hw_params_set_channels(pcm, hw, ch)) < 0 ||
        (err = p_snd_pcm_hw_params_set_rate(pcm, hw, rate, 0)) < 0 ||
        (err = p_snd_pcm_hw_params_set_buffer_size_near(pcm, hw, &buf)) < 0 ||
        (err = p_snd_pcm_hw_params_set_period_size_near(pcm, hw, &per, &dir)) < 0 ||
        (err = p_snd_pcm_hw_params(pcm, hw)) < 0) {
        tlog("dst %s rejects %u Hz / %u ch / fmt %d: %s", dst_pcm, rate, ch, fmt, p_snd_strerror(err));
        p_snd_pcm_hw_params_free(hw); p_snd_pcm_close(pcm); return NULL;
    }
    p_snd_pcm_hw_params_free(hw);
    snd_pcm_sw_params_t *sw; p_snd_pcm_sw_params_malloc(&sw);
    p_snd_pcm_sw_params_current(pcm, sw);
    p_snd_pcm_sw_params_set_start_threshold(pcm, sw, per * 2);
    p_snd_pcm_sw_params_set_avail_min(pcm, sw, per);
    p_snd_pcm_sw_params(pcm, sw);
    p_snd_pcm_sw_params_free(sw);
    tlog("dst %s open: %u Hz, %u ch, fmt %d, buffer %lu, period %lu", dst_pcm, rate, ch, fmt, buf, per);
    *out_buffer = buf;
    return pcm;
}

static int our_gadget_up(void) { return access(gadget_dir, F_OK) == 0 && access("/sys/kernel/config/usb_gadget/smexstream", F_OK) != 0; }

static double now_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }

static void *worker(void *arg) {
    (void)arg;
    /* Normal (SCHED_OTHER) scheduling on purpose: v1 used SCHED_FIFO and, combined with a busy loop,
       starved the MPC UI/Wi-Fi on CPUs 0-1. A modest nice boost is enough with a 23 ms queue. */
    setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), -5);
    cpu_set_t cs; CPU_ZERO(&cs); CPU_SET(0, &cs); CPU_SET(1, &cs);      /* stay off isolcpus 2-3 (MPC audio) */
    pthread_setaffinity_np(pthread_self(), sizeof cs, &cs);
    snd_pcm_uframes_t dst_buffer = 2048; double next_guard = 0; int was_up = -1;
    snd_pcm_t *dst = NULL; unsigned my_gen = 0; double next_try = 0, next_stat = now_s() + 30, last_slip = 0;
    unsigned long written = 0, xruns = 0, slips_drop = 0, slips_dup = 0, prefilled = 0;
    double avg_fill = target_fill;
    static uint8_t buf[1025 * MAX_FRAME_BYTES];
    for (;;) {
        unsigned g = atomic_load(&gen);
        if (g != my_gen) {                                   /* reconfigured or closed */
            if (dst) { p_snd_pcm_close(dst); dst = NULL; tlog("dst closed (reconfig)"); }
            my_gen = g; next_try = 0;
        }
        if (!atomic_load(&active)) { usleep(100000); continue; }
        if (now_s() > next_guard) {                            /* only ever feed OUR gadget */
            int up = our_gadget_up(); next_guard = now_s() + 1;
            if (up != was_up) { tlog("gadget %s %s", gadget_dir, up ? "present" : "absent (or controller mode) — tee waiting"); was_up = up; }
            if (!up) { if (dst) { p_snd_pcm_close(dst); dst = NULL; } usleep(200000); continue; }
        }
        if (!dst) {
            if (now_s() < next_try) { usleep(50000); continue; }
            dst = open_dst(cfg_rate, cfg_channels, cfg_format, &dst_buffer);
            if (!dst) { next_try = now_s() + 2; continue; }
            ring_skip(ring_fill());                           /* start fresh: no stale audio */
            {                                                 /* pre-fill silence up to the target level */
                static uint8_t zeros[1024 * MAX_FRAME_BYTES];
                long z = target_fill < 1024 ? target_fill : 1024;
                p_snd_pcm_writei(dst, zeros, (snd_pcm_uframes_t)z);
            }
            avg_fill = target_fill;
        }
        atomic_fetch_add_explicit(&loops_total, 1, memory_order_relaxed);
        snd_pcm_sframes_t avail = p_snd_pcm_avail_update(dst);
        if (avail < 0) {
            if (avail == -EPIPE || avail == -ESTRPIPE) { xruns++; p_snd_pcm_prepare(dst); usleep(IDLE_SLEEP_US); continue; }
            tlog("dst error %s — closing, will retry", p_snd_strerror((int)avail));
            p_snd_pcm_close(dst); dst = NULL; next_try = now_s() + 2; continue;
        }
        double t = now_s();
        uint32_t fill = ring_fill();
        long queued = (long)dst_buffer - (long)avail;          /* frames already waiting in the gadget */
        avg_fill = avg_fill * 0.998 + (double)(fill + (queued > 0 ? queued : 0)) * 0.002;   /* total level, tau ~1 s */
        if (t > next_stat) {
            tlog("stats: pushed=%lu written=%lu ring=%u level-avg=%.0f avail=%ld xruns=%lu slip-=%lu slip+=%lu ring-full-drops=%lu backlog-flush=%lu loops=%lu",
                 atomic_load(&pushed_total), written, fill, avg_fill, (long)avail, xruns, slips_drop, slips_dup,
                 atomic_load(&dropped_full), prefilled, atomic_load(&loops_total));
            next_stat = t + 30;
        }
        {                                                     /* backlog (host stalled/just started): one clean cut */
            long total = (long)fill + (queued > 0 ? queued : 0);
            if (total > target_fill + 512 && fill > 0) {
                long cut = total - target_fill; if (cut > (long)fill) cut = (long)fill;
                ring_skip((uint32_t)cut); fill -= (uint32_t)cut; avg_fill = target_fill; prefilled++;
            }
        }
        long room = DST_QUEUE - queued;
        if (room > avail) room = avail;
        if (room < 64 || fill == 0) {                          /* NEVER spin */
            if (room < 64 && fill > 0) ring_skip(fill);       /* host not reading: queue is full, keep ring empty */
            usleep(IDLE_SLEEP_US); continue;
        }
        uint32_t n = fill; if (n > (uint32_t)room) n = (uint32_t)room; if (n > 1024) n = 1024;
        ring_pop(buf, n);
        if (t - last_slip > 0.1 && n > 1) {                   /* drift correction: +-1 frame / 100 ms */
            if (avg_fill > target_fill + 192) { n -= 1; slips_drop++; last_slip = t; avg_fill -= 1; }
            else if (avg_fill < target_fill - 192 && n < 1024 && (long)n < room) { avg_fill += 1;
                memcpy(buf + (size_t)n * frame_bytes, buf + (size_t)(n - 1) * frame_bytes, frame_bytes); n += 1; slips_dup++; last_slip = t;
            }
        }
        snd_pcm_sframes_t r = p_snd_pcm_writei(dst, buf, n);
        if (r == -EPIPE || r == -ESTRPIPE) { xruns++; p_snd_pcm_prepare(dst); }
        else if (r == -EAGAIN) { usleep(IDLE_SLEEP_US); }
        else if (r < 0) { tlog("dst write %s — closing", p_snd_strerror((int)r)); p_snd_pcm_close(dst); dst = NULL; next_try = now_s() + 2; }
        else written += r;
    }
    return NULL;
}

/* ---- interposed ALSA entry points ---- */
int snd_pcm_open(snd_pcm_t **pcmp, const char *name, int stream, int mode) {
    init_once();
    if (!p_snd_pcm_open && !resolve()) return -ENOSYS;
    int r = p_snd_pcm_open(pcmp, name, stream, mode);
    if (enabled == 1 && r >= 0 && stream == SND_PCM_STREAM_PLAYBACK) {
        int card = pcm_card(*pcmp), src = p_snd_card_get_index(src_card);
        tlog("app opened playback '%s' (card %d; %s is card %d)", name ? name : "?", card, src_card, src);
        if ((card >= 0 && card == src) || (src_pcm_name && name && strcmp(name, src_pcm_name) == 0)) atomic_store(&main_pcm, *pcmp);
    }
    return r;
}

int snd_pcm_hw_params(snd_pcm_t *pcm, snd_pcm_hw_params_t *params) {
    if (!p_snd_pcm_hw_params && !resolve()) return -ENOSYS;
    int r = p_snd_pcm_hw_params(pcm, params);
    if (enabled == 1 && r >= 0 && pcm == atomic_load(&main_pcm)) {
        unsigned rate = 0, ch = 0; int dir = 0, fmt = -1, acc = -1;
        p_snd_pcm_hw_params_get_rate(params, &rate, &dir);
        p_snd_pcm_hw_params_get_channels(params, &ch);
        p_snd_pcm_hw_params_get_format(params, &fmt);
        p_snd_pcm_hw_params_get_access(params, &acc);
        atomic_store(&active, 0);
        unsigned fb = ch * 4;                                /* S32/S24 in 4 bytes; others rejected below */
        if (acc != SND_PCM_ACCESS_RW_INTERLEAVED || (fmt != 10 /*S32_LE*/ && fmt != 6 /*S24_LE*/) || fb == 0 || fb > MAX_FRAME_BYTES) {
            tlog("main out %u Hz %u ch fmt %d access %d — unsupported, tee idle", rate, ch, fmt, acc);
        } else {
            cfg_rate = rate; cfg_channels = ch; cfg_format = fmt; frame_bytes = fb;
            atomic_store(&wpos, 0); atomic_store(&rpos, 0);
            atomic_fetch_add(&gen, 1);
            atomic_store(&active, 1);
            tlog("main out configured: %u Hz, %u ch, fmt %d — tee active", rate, ch, fmt);
            if (!worker_started) { worker_started = pthread_create(&worker_tid, NULL, worker, NULL) == 0; }
        }
    }
    return r;
}

snd_pcm_sframes_t snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t size) {
    snd_pcm_sframes_t r = p_snd_pcm_writei ? p_snd_pcm_writei(pcm, buffer, size)
                                           : (resolve() ? p_snd_pcm_writei(pcm, buffer, size) : -ENOSYS);
    if (r > 0 && pcm == atomic_load_explicit(&main_pcm, memory_order_relaxed) && atomic_load_explicit(&active, memory_order_relaxed))
        ring_push((const uint8_t *)buffer, (uint32_t)r);
    return r;
}

int snd_pcm_close(snd_pcm_t *pcm) {
    if (!p_snd_pcm_close && !resolve()) return -ENOSYS;
    if (enabled == 1 && pcm && pcm == atomic_load(&main_pcm)) {
        atomic_store(&active, 0); atomic_store(&main_pcm, NULL); atomic_fetch_add(&gen, 1);
        tlog("app closed main out — tee idle");
    }
    return p_snd_pcm_close(pcm);
}
