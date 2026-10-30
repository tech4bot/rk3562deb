/* rkisp1_awb.c — persistent AWB gain feeder for the Rockchip vendor ISP
 * (rkisp, ISP v3.2 / v3.2-lite as on RK3562).
 * Feeds AWB gain params in a loop while the ISP is streaming.
 * Usage: ./rkisp1_awb [r gr gb b [gains-file]]
 *        (Q8: 256=1.0x)
 * With a gains file ("r gr gb b" on one line), new gains written there are
 * picked up while streaming; rkcam-webcam uses it for automatic white balance.
 *
 * The vendor driver expects struct isp32_isp_params_cfg (64-bit module masks)
 * on the params node; the mainline struct rkisp1_params_cfg used previously is
 * accepted but its fields land at the wrong offsets, so the gains were ignored.
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
#include <linux/rk-isp32-config.h>

#define PARAMS_DEV "/dev/video28"
#define NUM_BUFS   2

static volatile int running = 1;
static void sig_handler(int s) { (void)s; running = 0; }

static void fill_params(struct isp32_isp_params_cfg *p, int r, int gr, int gb, int b)
{
    struct isp32_awb_gain_cfg *g = &p->others.awb_gain_cfg;

    memset(p, 0, sizeof(*p));
    p->module_en_update  = ISP32_MODULE_AWB_GAIN;
    p->module_ens        = ISP32_MODULE_AWB_GAIN;
    p->module_cfg_update = ISP32_MODULE_AWB_GAIN;
    /* The driver rejects the block if any gain set is zero; use one set. */
    g->gain0_red = g->gain1_red = g->gain2_red = g->awb1_gain_r = (__u16)r;
    g->gain0_green_r = g->gain1_green_r = g->gain2_green_r = g->awb1_gain_gr = (__u16)gr;
    g->gain0_green_b = g->gain1_green_b = g->gain2_green_b = g->awb1_gain_gb = (__u16)gb;
    g->gain0_blue = g->gain1_blue = g->gain2_blue = g->awb1_gain_b = (__u16)b;
}

/* Re-read the gains file when it changed; returns 1 if the gains changed. */
static int reload_gains(const char *path, struct timespec *mtime,
                        int *r, int *gr, int *gb, int *b)
{
    struct stat st;
    int nr, ngr, ngb, nb;
    FILE *f;

    if (!path || stat(path, &st) < 0)
        return 0;
    if (st.st_mtim.tv_sec == mtime->tv_sec && st.st_mtim.tv_nsec == mtime->tv_nsec)
        return 0;
    *mtime = st.st_mtim;
    f = fopen(path, "r");
    if (!f)
        return 0;
    if (fscanf(f, "%d %d %d %d", &nr, &ngr, &ngb, &nb) != 4 ||
        nr < 1 || ngr < 1 || ngb < 1 || nb < 1 ||
        nr > 4095 || ngr > 4095 || ngb > 4095 || nb > 4095) {
        fclose(f);
        return 0;
    }
    fclose(f);
    *r = nr; *gr = ngr; *gb = ngb; *b = nb;
    return 1;
}

int main(int argc, char *argv[]) {
    int r = 512, gr = 256, gb = 256, b = 640;
    const char *gains_file = NULL;
    struct timespec gains_mtime = {0};
    if (argc >= 5) { r=atoi(argv[1]); gr=atoi(argv[2]); gb=atoi(argv[3]); b=atoi(argv[4]); }
    if (argc >= 6) gains_file = argv[5];
    reload_gains(gains_file, &gains_mtime, &r, &gr, &gb, &b);

    /* No SA_RESTART: a stop signal must interrupt a blocking DQBUF, which
     * otherwise waits forever once the ISP stops (e.g. switched to the rear
     * camera) and the service only dies at systemd's stop timeout. */
    struct sigaction sa = {0};
    sa.sa_handler = sig_handler;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    int fd = open(PARAMS_DEV, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    struct v4l2_format fmt = {0};
    fmt.type = V4L2_BUF_TYPE_META_OUTPUT;
    fmt.fmt.meta.dataformat = V4L2_META_FMT_RK_ISP1_PARAMS;
    fmt.fmt.meta.buffersize = sizeof(struct isp32_isp_params_cfg);
    if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) { perror("S_FMT"); return 1; }

    struct v4l2_requestbuffers req = {0};
    req.count = NUM_BUFS; req.type = V4L2_BUF_TYPE_META_OUTPUT; req.memory = V4L2_MEMORY_MMAP;
    if (ioctl(fd, VIDIOC_REQBUFS, &req) < 0) { perror("REQBUFS"); return 1; }

    void *maps[NUM_BUFS]; __u32 sizes[NUM_BUFS];
    for (int i = 0; i < NUM_BUFS; i++) {
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_META_OUTPUT; buf.memory = V4L2_MEMORY_MMAP; buf.index = i;
        if (ioctl(fd, VIDIOC_QUERYBUF, &buf) < 0) { perror("QUERYBUF"); return 1; }
        if (buf.length < sizeof(struct isp32_isp_params_cfg)) {
            fprintf(stderr, "rkisp1_awb: params buffer too small (%u < %zu)\n",
                    buf.length, sizeof(struct isp32_isp_params_cfg));
            return 1;
        }
        maps[i] = mmap(NULL, buf.length, PROT_READ|PROT_WRITE, MAP_SHARED, fd, buf.m.offset);
        sizes[i] = buf.length;
        if (maps[i] == MAP_FAILED) { perror("mmap"); return 1; }
    }

    int type = V4L2_BUF_TYPE_META_OUTPUT;
    if (ioctl(fd, VIDIOC_STREAMON, &type) < 0) { perror("STREAMON"); return 1; }

    /* Pre-fill both buffers and queue them */
    for (int i = 0; i < NUM_BUFS; i++) {
        fill_params((struct isp32_isp_params_cfg *)maps[i], r, gr, gb, b);

        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_META_OUTPUT; buf.memory = V4L2_MEMORY_MMAP;
        buf.index = i; buf.bytesused = sizeof(struct isp32_isp_params_cfg);
        if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) { perror("QBUF"); return 1; }
    }

    fprintf(stderr, "rkisp1_awb: R=%d Gr=%d Gb=%d B=%d running\n", r, gr, gb, b);

    /* Dequeue consumed buffers and requeue them to keep the ISP fed */
    unsigned int frames = 0;
    while (running) {
        struct v4l2_buffer buf = {0};
        buf.type = V4L2_BUF_TYPE_META_OUTPUT; buf.memory = V4L2_MEMORY_MMAP;
        if (ioctl(fd, VIDIOC_DQBUF, &buf) < 0) {
            if (errno == EINTR)
                continue;
            if (running) perror("DQBUF");
            break;
        }
        /* Requeue with the current AWB gains (re-read every 10 frames) */
        if (++frames % 10 == 0 &&
            reload_gains(gains_file, &gains_mtime, &r, &gr, &gb, &b))
            fprintf(stderr, "rkisp1_awb: gains R=%d Gr=%d Gb=%d B=%d\n", r, gr, gb, b);
        fill_params((struct isp32_isp_params_cfg *)maps[buf.index], r, gr, gb, b);
        buf.bytesused = sizeof(struct isp32_isp_params_cfg);
        if (ioctl(fd, VIDIOC_QBUF, &buf) < 0) {
            if (running) perror("QBUF requeue");
            break;
        }
    }

    ioctl(fd, VIDIOC_STREAMOFF, &type);
    for (int i = 0; i < NUM_BUFS; i++) munmap(maps[i], sizes[i]);
    close(fd);
    fprintf(stderr, "rkisp1_awb: stopped\n");
    return 0;
}
