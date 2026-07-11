#!/usr/bin/env bash

# Launcher for the PASCOM client OCI container.
#
# Wires the host's Wayland/X11 display, PipeWire/PulseAudio socket, session
# D-Bus (notifications, tray, URL opening via portal), GPU and camera devices
# into the container and starts the PASCOM client with the host user's UID.
#
# Environment variables (all optional):
#   PASCOM_IMAGE     Image to run (default: localhost/pascom-client:latest)
#   PASCOM_DATA_DIR  Host directory for persistent client configuration
#                    (default: ${XDG_DATA_HOME:-~/.local/share}/oci-pascom-client)
#
# All command line arguments are passed through to the pascom client.
#
# SPDX-FileCopyrightText: foundata GmbH <https://foundata.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

image="${PASCOM_IMAGE:-localhost/pascom-client:latest}"
data_dir="${PASCOM_DATA_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/oci-pascom-client}"

if ! command -v podman > /dev/null 2>&1; then
    printf 'Error: podman not found. See https://podman.io/docs/installation\n' >&2
    exit 1
fi

if [ -z "${XDG_RUNTIME_DIR:-}" ] || [ ! -d "${XDG_RUNTIME_DIR}" ]; then
    printf 'Error: XDG_RUNTIME_DIR is not set or does not exist. A running graphical user session is required.\n' >&2
    exit 1
fi

# Persistent home directory of the client (stores account and settings).
mkdir -p "${data_dir}"

uid="$(id -u)"
rt_inside="/run/user/${uid}" # XDG_RUNTIME_DIR inside the container

args=(
    run
    --rm
    --replace
    --name "pascom-client"
    --hostname "pascom-client"

    # Run with the host user's UID/GID so bind-mounted sockets and the data
    # directory are accessible without permission fiddling.
    --userns=keep-id

    # Host networking (a network namespace would break the client):
    # 1. The browser-based login redirects the host's browser to a callback
    #    HTTP server the client runs on localhost:3008, which must therefore
    #    be the *host's* localhost.
    # 2. SIP/RTP media uses dynamic UDP ports; NAT-ing them through a
    #    rootless network stack (pasta/slirp4netns) invites one-way-audio
    #    class problems.
    --network=host

    # Do not relabel anything: the container must access sockets in
    # XDG_RUNTIME_DIR and relabeling those (":z"/":Z") would break the host
    # session on SELinux-enabled systems. Harmless where SELinux is disabled.
    --security-opt "label=disable"

    # Writable runtime dir (sticky, world-writable like /tmp, as tmpfs
    # mounts are root-owned and Podman's --tmpfs cannot chown); display and
    # audio sockets get bind-mounted into it below.
    --tmpfs "${rt_inside}:rw,mode=1777"
    --env "XDG_RUNTIME_DIR=${rt_inside}"

    # Persistent client configuration.
    --volume "${data_dir}:/home/pascom"
    --env "HOME=/home/pascom"
)

# Locale and timezone passthrough (cosmetic, but nice to have).
[ -n "${LANG:-}" ] && args+=(--env "LANG=${LANG}")
[ -n "${TZ:-}" ] && args+=(--env "TZ=${TZ}")

# Audio: host PipeWire/PulseAudio native socket. This is the only audio path
# into the container (no ALSA device passthrough needed or wanted).
pulse_socket="${XDG_RUNTIME_DIR}/pulse/native"
if [ -S "${pulse_socket}" ]; then
    args+=(
        --volume "${pulse_socket}:${rt_inside}/pulse/native"
        --env "PULSE_SERVER=unix:${rt_inside}/pulse/native"
    )
else
    printf 'Warning: no PulseAudio/PipeWire socket at %s - audio will not work.\n' "${pulse_socket}" >&2
fi

# Session D-Bus: notifications, tray icon (StatusNotifier) and URL opening
# through the host's XDG desktop portal.
dbus_socket="${XDG_RUNTIME_DIR}/bus"
if [ -S "${dbus_socket}" ]; then
    args+=(
        --volume "${dbus_socket}:${rt_inside}/bus"
        --env "DBUS_SESSION_BUS_ADDRESS=unix:path=${rt_inside}/bus"
    )
else
    printf 'Warning: no session D-Bus socket at %s - notifications, tray icon and browser-based login will not work.\n' "${dbus_socket}" >&2
fi

# Display: native Wayland when available, X11/XWayland otherwise. Qt inside
# the container is configured with QT_QPA_PLATFORM="wayland;xcb" and picks
# whatever is present.
have_display=0
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    case "${WAYLAND_DISPLAY}" in
        /*) wayland_socket="${WAYLAND_DISPLAY}" ;;
        *) wayland_socket="${XDG_RUNTIME_DIR}/${WAYLAND_DISPLAY}" ;;
    esac
    if [ -S "${wayland_socket}" ]; then
        args+=(
            --volume "${wayland_socket}:${rt_inside}/wayland-0"
            --env "WAYLAND_DISPLAY=wayland-0"
        )
        have_display=1
    fi
fi
if [ -n "${DISPLAY:-}" ] && [ -d "/tmp/.X11-unix" ]; then
    args+=(
        --volume "/tmp/.X11-unix:/tmp/.X11-unix:ro"
        --env "DISPLAY=${DISPLAY}"
    )
    if [ -n "${XAUTHORITY:-}" ] && [ -f "${XAUTHORITY}" ]; then
        args+=(
            --volume "${XAUTHORITY}:${rt_inside}/Xauthority:ro"
            --env "XAUTHORITY=${rt_inside}/Xauthority"
        )
    fi
    have_display=1
fi
if [ "${have_display}" -eq 0 ]; then
    printf 'Error: neither a Wayland nor an X11 display was found (WAYLAND_DISPLAY/DISPLAY).\n' >&2
    exit 1
fi

# GPU (hardware accelerated rendering) and cameras (video calls), if present.
[ -d "/dev/dri" ] && args+=(--device "/dev/dri")
for video_dev in /dev/video*; do
    [ -c "${video_dev}" ] && args+=(--device "${video_dev}")
done

exec podman "${args[@]}" "${image}" "$@"
