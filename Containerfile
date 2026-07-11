# Containerfile for the PASCOM client on non-Ubuntu Linux hosts.
#
# The pascom Linux client is only supported on Ubuntu. This image wraps the
# official client tarball in an Ubuntu 24.04 LTS userland so it can run on
# any Linux host with Podman (audio via the host's PipeWire/PulseAudio
# socket, GUI via Wayland or X11).
#
# SPDX-FileCopyrightText: foundata GmbH <https://foundata.com>
# SPDX-License-Identifier: GPL-3.0-or-later


#### Config

# URL of the client tarball. The default always delivers the latest release
# (it redirects to a versioned file). To pin a version, pass a versioned URL
# from the release archive, e.g.:
#   podman build \
#     --build-arg PASCOM_CLIENT_URL="https://download.pascom.net/release-archive/client/cloud/pascom_Client-120.R5073-linux.tar.bz2" \
#     -t pascom-client .
ARG PASCOM_CLIENT_URL="https://my.pascom.net/update/client/cloud/linux"


#### Stage 1: Download and extract the official PASCOM client tarball

FROM docker.io/library/ubuntu:24.04 AS download

ARG PASCOM_CLIENT_URL

RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
      bzip2 \
      ca-certificates \
      curl \
 && rm -rf /var/lib/apt/lists/*

# The tarball contains a single top-level "pascom_Client" directory with the
# binary, an AppRun launcher script and bundled libraries (Qt 6, FFmpeg,
# OpenSSL, ICU, ...).
RUN curl --fail --silent --show-error --location --retry 3 \
      --output "/tmp/pascom_client.tar.bz2" "${PASCOM_CLIENT_URL}" \
 && mkdir "/tmp/extracted" \
 && tar -xjf "/tmp/pascom_client.tar.bz2" -C "/tmp/extracted" \
 && mv "/tmp/extracted/pascom_Client" "/opt/pascom_Client" \
 && rm -rf "/tmp/pascom_client.tar.bz2" "/tmp/extracted"


#### Stage 2: Runtime image

FROM docker.io/library/ubuntu:24.04

# Runtime dependencies of the client binary and its bundled Qt platform
# plugins (wayland, xcb) which are NOT part of the tarball. The list was
# determined empirically: run "ldd" against the main binary and all bundled
# Qt plugins inside a pristine ubuntu:24.04 container and resolve every
# "not found" entry to its Ubuntu package (see DEVELOPMENT.md). A build-time
# self-check below fails the build if the list ever becomes incomplete.
#
# Notes:
# - libasound2-plugins provides the ALSA-to-PulseAudio bridge; the client's
#   PJSIP stack opens ALSA devices, which /etc/asound.conf (below) routes to
#   the PulseAudio/PipeWire socket of the host.
# - libglib2.0-bin provides "gdbus", used by the xdg-open shim to open URLs
#   in the host's browser via the XDG desktop portal.
# - pulseaudio-utils ("pactl") is only included to ease debugging audio.
RUN apt-get update \
 && apt-get install --yes --no-install-recommends \
      ca-certificates \
      fontconfig \
      fonts-dejavu-core \
      libasound2-plugins \
      libasound2t64 \
      libbrotli1 \
      libcurl4t64 \
      libdbus-1-3 \
      libdrm2 \
      libegl1 \
      libfontconfig1 \
      libfreetype6 \
      libgl1 \
      libglib2.0-0t64 \
      libglib2.0-bin \
      libgssapi-krb5-2 \
      libpulse0 \
      libwayland-client0 \
      libwayland-cursor0 \
      libwayland-egl1 \
      libx11-6 \
      libx11-xcb1 \
      libxcb-cursor0 \
      libxcb-icccm4 \
      libxcb-image0 \
      libxcb-keysyms1 \
      libxcb-randr0 \
      libxcb-render-util0 \
      libxcb-render0 \
      libxcb-shape0 \
      libxcb-shm0 \
      libxcb-sync1 \
      libxcb-util1 \
      libxcb-xfixes0 \
      libxcb-xkb1 \
      libxcb1 \
      libxext6 \
      libxkbcommon-x11-0 \
      libxkbcommon0 \
      libxrandr2 \
      pulseaudio-utils \
      shared-mime-info \
      xkb-data \
 && rm -rf /var/lib/apt/lists/*

# The client (owned by root on purpose: this disables the client's built-in
# self-updater; rebuild the image to update, see README.md).
COPY --from=download /opt/pascom_Client /opt/pascom_Client

# Route ALSA to PulseAudio (which is the host's PipeWire/PulseAudio socket,
# bind-mounted at runtime). Without this, the client's PJSIP audio backend
# tries to open ALSA hardware devices which do not exist in the container.
RUN printf '%s\n' \
      'pcm.!default { type pulse }' \
      'ctl.!default { type pulse }' \
      > /etc/asound.conf

COPY container/xdg-open /usr/local/bin/xdg-open
COPY container/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/xdg-open /usr/local/bin/entrypoint.sh

# Build-time self-check: fail if any shared library dependency of the main
# binary or the essential bundled Qt plugins cannot be resolved. Optional
# plugin categories the softphone never loads (SQL drivers, print support,
# the GTK3 platform theme, exotic image formats) are excluded on purpose:
# they reference libraries that are either irrelevant or not available in
# Ubuntu 24.04 (see DEVELOPMENT.md).
RUN missing="$(export LD_LIBRARY_PATH="/opt/pascom_Client/lib"; \
      { ldd "/opt/pascom_Client/pascom_Client"; \
        find "/opt/pascom_Client/plugins/platforms" \
             "/opt/pascom_Client/plugins/platforminputcontexts" \
             "/opt/pascom_Client/plugins/wayland-decoration-client" \
             "/opt/pascom_Client/plugins/wayland-graphics-integration-client" \
             "/opt/pascom_Client/plugins/wayland-shell-integration" \
             "/opt/pascom_Client/plugins/xcbglintegrations" \
             "/opt/pascom_Client/plugins/tls" \
             "/opt/pascom_Client/plugins/multimedia" \
             "/opt/pascom_Client/plugins/networkinformation" \
             "/opt/pascom_Client/plugins/iconengines" \
             -name '*.so' -exec ldd {} \; ; \
        ldd "/opt/pascom_Client/plugins/platformthemes/libqxdgdesktopportal.so"; \
      } 2>/dev/null | grep 'not found' | sort -u)"; \
    if [ -n "${missing}" ]; then \
      printf 'Unresolved library dependencies:\n%s\n' "${missing}"; \
      exit 1; \
    fi

# Home directory for the unprivileged runtime user. The launcher script
# bind-mounts a host directory here for persistent client configuration and
# runs the container with the host user's UID (--userns=keep-id), which is
# not known at build time - hence the permissive mode on the (empty) fallback.
RUN mkdir -p /home/pascom && chmod 0777 /home/pascom
ENV HOME="/home/pascom"

# Make the client prefer the XDG desktop portal platform theme (file dialogs
# and URL opening are delegated to the host). The AppRun launcher script of
# the client respects pre-set values.
ENV QT_QPA_PLATFORMTHEME="xdgdesktopportal" \
    QT_PLATFORMTHEME="xdgdesktopportal" \
    BROWSER="/usr/local/bin/xdg-open" \
    LANG="C.UTF-8"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
