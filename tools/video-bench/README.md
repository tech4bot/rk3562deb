# Playback bench

Measures video playback the way a viewer experiences it, on the tablet itself:
it plays a local clip in its own Chrome instance and records what the `<video>`
element reports about its own frames — total frames, dropped frames, and how
fast the video clock advances against the wall clock. A decoder that keeps up
shows the clip's frame rate at 1.0×; one that does not shows fewer frames *and*
a video clock falling behind, which is what constant stop/start looks like from
the outside.

It exists because "it looks choppy" cannot tell you whether frames are being
dropped, decoded slowly, or delivered late, and because CPU load alone is
misleading — the hardware decoder can be busy while playback is still wrong.

## Use

Copy this directory to the tablet, add clips next to it, and run it there:

    scp -r tools/video-bench/ tablet:vbench/
    ssh tablet 'cd vbench && ./run.sh hw t1080p30.mp4 20 \
        --enable-features=VaapiVideoDecodeLinuxGL,VaapiIgnoreDriverChecks'

`run.sh <label> <clip> <seconds> [chrome args…]` prints the frame statistics,
the CPU all Chrome processes used over the window, and how many samples had
`/dev/mpp_service` open (the proof that decoding really was on the hardware).
With no Chrome arguments it tests the installed wrapper, which is how a normal
launch behaves.

Test clips can be generated on any machine with ffmpeg; B-frames matter, since
they are what exposed the decode-order bug fixed in
`overlay/vaapi-patches/0002-*`:

    ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30:duration=30 \
      -c:v libx264 -profile:v high -preset veryfast -b:v 4500k \
      -pix_fmt yuv420p -movflags +faststart t1080p30.mp4

## Results on the C20e (Chrome 153, Fedora 44, 1080p30 H.264 with B-frames)

| decode path | frame rate | video clock | Chrome CPU |
|---|---|---|---|
| hardware, before the decode-order fix | 15–20 fps | 0.66× (slow motion) | 97% of one core |
| hardware | 30.0 fps | 1.0× | 128% of one core |
| software | 30.0 fps | 1.0× | 208% of one core |

1080p60 reaches about 50 fps: 20.2 ms per frame from packet to decoded frame,
of which 15.7 ms is MPP/rkvdec2 and 4.5 ms is the driver's copy into the
surface buffer (`RK_VAAPI_COPY_STATS=1` prints both).
