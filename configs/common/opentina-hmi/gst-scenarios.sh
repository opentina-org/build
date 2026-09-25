#!/bin/sh
# OpenTina GStreamer scenario runner.
#
# Usage: gst-scenarios.sh [video|audio|encode|all] [--headless]
#
# --headless replaces the display and audio sinks with fakesink, so the same
# pipelines can be exercised without a compositor or a sound card. That is the
# form used in offline verification; on the board run without it.
set -eu

MODE="${1:-all}"
HEADLESS=0
[ "${2:-}" = "--headless" ] && HEADLESS=1

if [ "$HEADLESS" = "1" ]; then
    VSINK="fakesink sync=false"
    ASINK="fakesink sync=false"
else
    VSINK="waylandsink"
    ASINK="autoaudiosink"
fi

DUR="${OPENTINA_GST_DURATION:-5}"

run() {
    echo "--- $1"
    shift
    if timeout "$((DUR + 10))" gst-launch-1.0 -q "$@"; then
        echo "    ok"
    else
        echo "    FAILED (exit $?)"
        return 1
    fi
}

video() {
    # shellcheck disable=SC2086
    run "video test pattern -> ${VSINK%% *}" \
        videotestsrc num-buffers=$((DUR * 30)) ! \
        video/x-raw,width=1280,height=720,framerate=30/1 ! \
        videoconvert ! $VSINK
}

audio() {
    # shellcheck disable=SC2086
    run "audio test tone -> ${ASINK%% *}" \
        audiotestsrc num-buffers=$((DUR * 50)) ! \
        audio/x-raw,rate=48000,channels=2 ! \
        audioconvert ! $ASINK
}

encode() {
    # VP8 and Vorbis are in plugins-good; no x264enc in this image.
    # shellcheck disable=SC2086
    run "videotestsrc -> VP8 -> WebM -> decode -> ${VSINK%% *}" \
        videotestsrc num-buffers=$((DUR * 15)) ! \
        video/x-raw,width=640,height=480,framerate=15/1 ! \
        videoconvert ! vp8enc deadline=1 ! webmmux ! matroskademux ! \
        vp8dec ! videoconvert ! $VSINK
}

rc=0
case "$MODE" in
    video)  video || rc=1 ;;
    audio)  audio || rc=1 ;;
    encode) encode || rc=1 ;;
    all)    video || rc=1; audio || rc=1; encode || rc=1 ;;
    *)      echo "usage: $0 [video|audio|encode|all] [--headless]" >&2; exit 2 ;;
esac
exit "$rc"
