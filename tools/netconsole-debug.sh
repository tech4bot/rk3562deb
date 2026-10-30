#!/bin/sh
# netconsole-debug.sh — stream the kernel log (and journal) to another machine
# over UDP, for freezes that leave nothing on the SD card.
#
# Usage (on the tablet, as root): netconsole-debug.sh REMOTE_IP [PORT]
# Receive on the other machine with e.g.: socat -u UDP-RECV:6666 - >> netconsole.log
#
# Needs CONFIG_NETCONSOLE=m and CONFIG_NETCONSOLE_DYNAMIC=y. Run it once the
# network is up (it uses the current default route); run again after a
# network change.
set -eu

REMOTE_IP="${1:?usage: $0 REMOTE_IP [PORT]}"
PORT="${2:-6666}"
TARGET=/sys/kernel/config/netconsole/debug

# netconsole sends raw Ethernet frames: the destination MAC is the remote
# host's own when it is on the same link, otherwise the next hop's.
route="$(ip -4 route get "${REMOTE_IP}")"
dev="$(echo "${route}" | sed -n 's/.* dev \([^ ]*\).*/\1/p')"
src="$(echo "${route}" | sed -n 's/.* src \([^ ]*\).*/\1/p')"
hop="$(echo "${route}" | sed -n 's/.* via \([^ ]*\).*/\1/p')"
hop="${hop:-${REMOTE_IP}}"
ping -c 1 -W 2 "${hop}" >/dev/null 2>&1 || true
mac="$(ip neigh show "${hop}" dev "${dev}" | sed -n 's/.* lladdr \([^ ]*\).*/\1/p')"
[ -n "${dev}" ] && [ -n "${src}" ] && [ -n "${mac}" ] || {
    echo "netconsole-debug: no route/MAC for ${REMOTE_IP} (dev=${dev} src=${src} mac=${mac})" >&2
    exit 1
}

modprobe netconsole
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
if [ -d "${TARGET}" ]; then
    echo 0 > "${TARGET}/enabled"
else
    mkdir "${TARGET}"
fi
echo "${dev}" > "${TARGET}/dev_name"
echo "${src}" > "${TARGET}/local_ip"
echo "${REMOTE_IP}" > "${TARGET}/remote_ip"
echo "${PORT}" > "${TARGET}/remote_port"
echo "${mac}" > "${TARGET}/remote_mac"
echo 1 > "${TARGET}/enabled"

# The kernel command line has "quiet loglevel=0", which would keep every
# message off the consoles, netconsole included.
dmesg -n 7
# Let journald forward everything (see ForwardToKMsg) without rate limiting.
sysctl -q -w kernel.printk_devkmsg=on
echo "netconsole-debug: ${dev} ${src} -> ${REMOTE_IP}:${PORT} via ${mac}" > /dev/kmsg
