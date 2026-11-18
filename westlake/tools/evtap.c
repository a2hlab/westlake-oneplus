/* evtap: write one multitouch tap (down, short hold, up) into an evdev node, like Android's sendevent.
 * Readers of the node (touchfwd, OH's input service) see it as a finger on the touchscreen.
 * usage: evtap /dev/input/eventN X Y   (X, Y in the device's raw ABS_MT_POSITION units) */
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static int fd;

static void emit(int type, int code, int value) {
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    gettimeofday(&ev.time, NULL);
    ev.type = (unsigned short)type;
    ev.code = (unsigned short)code;
    ev.value = value;
    if (write(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev)) { perror("evtap: write"); exit(1); }
}

int main(int argc, char** argv) {
    if (argc != 4) { fprintf(stderr, "usage: %s /dev/input/eventN X Y\n", argv[0]); return 2; }
    fd = open(argv[1], O_WRONLY);
    if (fd < 0) { perror("evtap: open"); return 1; }
    int x = atoi(argv[2]), y = atoi(argv[3]);
    emit(EV_ABS, ABS_MT_SLOT, 0);
    emit(EV_ABS, ABS_MT_TRACKING_ID, 4242);
    emit(EV_ABS, ABS_MT_POSITION_X, x);
    emit(EV_ABS, ABS_MT_POSITION_Y, y);
    emit(EV_KEY, BTN_TOUCH, 1);
    emit(EV_SYN, SYN_REPORT, 0);
    usleep(90000);
    emit(EV_ABS, ABS_MT_TRACKING_ID, -1);
    emit(EV_KEY, BTN_TOUCH, 0);
    emit(EV_SYN, SYN_REPORT, 0);
    close(fd);
    return 0;
}
