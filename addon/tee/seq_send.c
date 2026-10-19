/* seq_send — test helper: send N note on/off pairs to an ALSA sequencer port (default the USB MIDI gadget, f_midi),
 * i.e. the same route the MPC app's MIDI output takes. libasound is dlopen'ed (no headers on the build host needed
 * beyond the event layout below).  usage: seq_send [notes=10] [client=28] [port=0] */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
typedef struct _snd_seq snd_seq_t;
/* snd_seq_event_t layout (alsa-lib, 28 bytes on 32-bit ARM) */
typedef struct { unsigned char type, flags, tag, queue; unsigned int time[2];
                 unsigned char src_client, src_port, dest_client, dest_port;
                 union { struct { unsigned char channel, note, velocity, off_velocity; unsigned int duration; } note; unsigned char raw8[12]; } data; } ev_t;
enum { SND_SEQ_EVENT_NOTEON = 6, SND_SEQ_EVENT_NOTEOFF = 7, SND_SEQ_QUEUE_DIRECT = 253, SND_SEQ_ADDRESS_SUBSCRIBERS = 254 };
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 10, dc = argc > 2 ? atoi(argv[2]) : 28, dp = argc > 3 ? atoi(argv[3]) : 0;
    void *h = dlopen("libasound.so.2", RTLD_NOW); if (!h) { fprintf(stderr, "dlopen\n"); return 1; }
    int (*seq_open)(snd_seq_t **, const char *, int, int) = dlsym(h, "snd_seq_open");
    int (*set_name)(snd_seq_t *, const char *) = dlsym(h, "snd_seq_set_client_name");
    int (*mkport)(snd_seq_t *, const char *, unsigned, unsigned) = dlsym(h, "snd_seq_create_simple_port");
    int (*connect_to)(snd_seq_t *, int, int, int) = dlsym(h, "snd_seq_connect_to");
    int (*out_direct)(snd_seq_t *, ev_t *) = dlsym(h, "snd_seq_event_output_direct");
    const char *(*se)(int) = dlsym(h, "snd_strerror");
    snd_seq_t *s; int e;
    if ((e = seq_open(&s, "default", 1 /*OUTPUT*/, 0)) < 0) { fprintf(stderr, "seq_open: %s\n", se(e)); return 1; }
    set_name(s, "mpcaudio-test");
    int port = mkport(s, "out", (1u << 0) | (1u << 5) /*READ|SUBS_READ*/, (1u << 1) /*MIDI_GENERIC*/);
    if ((e = connect_to(s, port, dc, dp)) < 0) { fprintf(stderr, "connect %d:%d: %s\n", dc, dp, se(e)); return 1; }
    for (int i = 0; i < n; i++) {
        for (int on = 1; on >= 0; on--) {
            ev_t ev; memset(&ev, 0, sizeof ev);
            ev.type = on ? SND_SEQ_EVENT_NOTEON : SND_SEQ_EVENT_NOTEOFF; ev.queue = SND_SEQ_QUEUE_DIRECT;
            ev.src_port = (unsigned char)port; ev.dest_client = SND_SEQ_ADDRESS_SUBSCRIBERS;
            ev.data.note.channel = 0; ev.data.note.note = 60 + (i % 12); ev.data.note.velocity = on ? 100 : 0;
            if ((e = out_direct(s, &ev)) < 0) fprintf(stderr, "send: %s\n", se(e));
            usleep(150000);
        }
    }
    printf("sent %d notes to %d:%d\n", n, dc, dp);
    return 0;
}
