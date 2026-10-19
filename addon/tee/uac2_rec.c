/* uac2_rec — read N seconds from an ALSA capture PCM (default hw:UAC2Gadget,0, S32_LE stereo) and print
 * the peak level per second. Test helper for the computer → MPC direction. libasound is dlopen'ed. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct _snd_pcm snd_pcm_t;
int main(int argc, char **argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 5; const char *name = argc > 2 ? argv[2] : "hw:UAC2Gadget,0";
    void *h = dlopen("libasound.so.2", RTLD_NOW); if (!h) { fprintf(stderr, "dlopen\n"); return 1; }
    int (*o)(snd_pcm_t **, const char *, int, int) = dlsym(h, "snd_pcm_open");
    int (*sp)(snd_pcm_t *, int, int, unsigned, unsigned, int, unsigned) = dlsym(h, "snd_pcm_set_params");
    long (*ri)(snd_pcm_t *, void *, unsigned long) = dlsym(h, "snd_pcm_readi");
    int (*rec)(snd_pcm_t *, int, int) = dlsym(h, "snd_pcm_recover");
    const char *(*se)(int) = dlsym(h, "snd_strerror");
    int (*st)(snd_pcm_t *) = dlsym(h, "snd_pcm_start");
    snd_pcm_t *p; int e;
    if ((e = o(&p, name, 1 /*capture*/, 0)) < 0) { fprintf(stderr, "open %s: %s\n", name, se(e)); return 1; }
    if ((e = sp(p, 10, 3, 2, 44100, 0, 100000)) < 0) { fprintf(stderr, "params: %s\n", se(e)); return 1; }
    st(p);   /* capture won't auto-start: snd_pcm_set_params' start threshold is larger than our 441-frame reads */
    int32_t buf[441 * 2];
    for (int s = 0; s < secs; s++) {
        double peak = 0; long frames = 0;
        for (int i = 0; i < 100; i++) {
            long r = ri(p, buf, 441);
            if (r < 0) { rec(p, (int)r, 1); continue; }
            frames += r;
            for (long k = 0; k < r * 2; k++) { double v = fabs(buf[k] / 2147483648.0); if (v > peak) peak = v; }
        }
        printf("sec %d: %ld frames, peak %.3f (%.1f dBFS)\n", s + 1, frames, peak, 20 * log10(peak > 1e-9 ? peak : 1e-9));
        fflush(stdout);
    }
    return 0;
}
