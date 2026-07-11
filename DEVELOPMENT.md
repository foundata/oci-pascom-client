# Development notes

Reasoning, design decisions and gotchas for maintaining this project. For usage, see [`README.md`](README.md).


## Table of contents

- [Background: why this project exists](#background)
- [Approach: OCI container vs. Flatpak](#approach)
- [What is in the vendor tarball](#tarball)
- [Design decisions](#design)
  - [Base image: Ubuntu 24.04 LTS](#design-base)
  - [Multi-stage build, no client bits in the repository](#design-multistage)
  - [Dependency list and build-time self-check](#design-deps)
  - [Audio](#design-audio)
  - [Display](#design-display)
  - [Browser-based login and file dialogs (XDG desktop portal)](#design-portal)
  - [Networking](#design-network)
  - [User, home directory, persistence](#design-user)
  - [SELinux](#design-selinux)
  - [Self-updater](#design-updater)
- [Gotchas](#gotchas)
- [Verification / test results](#verification)
- [Debugging tips](#debugging)
- [Possible future improvements](#future)


## Background: why this project exists<a id="background"></a>

As of 2026-Q3, PASCOM only supports Ubuntu for its Linux desktop client. Running the client natively on Fedora was attempted in late 2024 / early 2025 and documented in the PASCOM community forum: [Stand Linux Client abseits von Ubuntu (hier: Fedora)](https://forum.pascom.net/t/stand-linux-client-abseits-von-ubuntu-hier-fedora/11687). Summary of that attempt (Fedora 41, client generation of that time):

1. **Startup failure due to library mismatches.** The client bundles parts of its userland (e.g. OpenSSL) but links other libraries from the system (e.g. `libcurl.so.4`). Fedora's `libcurl` required newer OpenSSL symbol versions (`OPENSSL_3.2.0`) than the bundled `libcrypto` provided. Workaround at the time: copy `libcurl.so.4` from Ubuntu 24.04 into the client's `lib/` directory. This class of mixed bundled/system linking is fragile on any non-Ubuntu system and breaks again with every library update.
2. **Browser login failure.** The client resolves GLib's `gio-launch-desktop` at an Ubuntu-specific path (`/usr/lib/*/glib-2.0/`); Fedora ships it in `/usr/libexec/`.
3. **No audio devices (showstopper).** While Qt saw audio devices, the client's PJSIP telephony stack could not enumerate any capture/playback device. Debug logs showed ALSA configuration errors (`Unknown parameter CARD`, `cannot find card '$CARD'`, `Could not create pj audio device`), ending in "pascom Softphone cannot be used as no speakers have been detected". Root cause: PJSIP opens ALSA devices directly and expects the Ubuntu ALSA/PulseAudio configuration layout; Fedora's PipeWire + ALSA setup differs enough that device enumeration fails.

Instead of patching the client's environment on every Fedora update, give the client the exact userland it was built for (Ubuntu LTS) inside a container and pass through only well-defined, distribution-independent interfaces: Wayland/X11 sockets, the PulseAudio native socket, the session D-Bus and device nodes:

1. System libraries in the container are the Ubuntu versions the client was linked against.
2. `gio-launch-desktop` lives at the expected Ubuntu path (and URL opening is delegated to the host via portal anyway, see below).
3. PJSIP's ALSA layer talks to Ubuntu's ALSA-to-PulseAudio bridge, which talks to the host's PipeWire through its PulseAudio-compatible socket. The socket protocol is stable and distribution-independent.


## Approach: OCI container vs. Flatpak<a id="approach"></a>

Flatpak was tried and might be an attractive long-term (portals are first-class, sandboxed PipeWire/PulseAudio access, desktop integration for free), and a manifest wrapping the vendor tarball ("extra-data" style) is feasible. But the Freedesktop/KDE runtimes are *not* Ubuntu: the same mixed bundled/system linking issues from the native attempt resurface (the client links `libcurl`, `libasound`, `libpulse`, X11/GL libraries from the system) and would have to be solved by bundling and possibly patching ELF headers per release. More initial and per-release effort, harder to debug. A Flatpak might still be a reasonable follow-up project but was the wrong tool for the first working version.


## What is in the vendor tarball<a id="tarball"></a>

`https://my.pascom.net/update/client/cloud/linux` HTTP-302-redirects to the latest versioned tarball, e.g. `https://download.pascom.net/release-archive/client/cloud/pascom_Client-120.R5073-linux.tar.bz2` (this also reveals the pinnable release-archive URL scheme). Findings from analyzing `pascom_Client-120.R5073` (single top-level directory `pascom_Client/`):

- `pascom_Client`: the main binary (Qt 6 application; embeds PJSIP/`pjsua2` for SIP/telephony).
- `AppRun`: launcher script: prepends `lib/` to `LD_LIBRARY_PATH`, defaults `QT_QPA_PLATFORMTHEME`/`QT_PLATFORMTHEME` to `gtk3` (respects pre-set values, which this image uses to switch to `xdgdesktopportal`), locates `gio-launch-desktop`, adds `lib-ubuntu20/` on Ubuntu 20.04 (focal) only.
- `lib/`: bundled libraries: Qt 6.10, ICU 73, FFmpeg 7, OpenSSL 3, libjabra. **Not** bundled (system-linked): `libcurl`, `libasound`, `libpulse`, `libdbus`, X11/xcb/Wayland client libraries, GL/EGL, fontconfig/freetype, glib, KRB5. this list is exactly what the image has to provide.
- `plugins/`, `qml/`: Qt plugins, including platform plugins `libqwayland.so` and `libqxcb.so` and the platform themes `libqgtk3.so` and `libqxdgdesktopportal.so` (the latter enables the portal integration used here).
- `update.sh`: self-updater (intentionally defunct in the image, see [below](#design-updater)).
- `create-starter.sh`: generates a `.desktop` entry for a native installation; not used here (a container-aware one is shipped instead). Noteworthy detail from it: the window class is `net.pascom.pascom_Client` on Wayland and `pascom_Client` on X11.
- `pascom-configure-jabraheadset.sh`, `pascom-configure-kuando-busylight.sh`: install udev rules for HID call control devices (call buttons, busylight via `/dev/hidraw*`; the client uses the bundled `libjabra` for this). Out of scope (see [README limitations](README.md#limitations)) because it conflicts with the project's "unprivileged, no host changes" design:
  - udev rules are inherently host-side and need root; a container cannot provide them. Without them the `hidraw` nodes are `root:root 0600`, and `--userns=keep-id` gives the container exactly the host user's (lack of) access.
  - Passing all of `/dev/hidraw*` would also expose unrelated HID devices (e.g. FIDO2 security keys) to the proprietary client; a safe implementation must filter by USB vendor ID via `/sys/class/hidraw`.
  - Hotplug: `podman run --device` snapshots devices at start; a replugged headset re-enumerates as a new `hidrawN` the running container cannot see. Rootless Podman has no `--device-cgroup-rule` and cannot `mknod`, so replugging would require a client restart.
  - `libjabra` enumerates via libudev; without a udev daemon in the container this likely needs `/run/udev/data` mounted read-only, and verification requires the physical hardware.
  - Plain headset audio (including Bluetooth) works without any of this, see [gotchas](#gotchas).
- The binary uses the PulseAudio client API directly for device enumeration (`pa_context_get_sink_info_list`, `pa_context_get_source_info_list`), while PJSIP handles the actual audio streams via ALSA. Both paths must therefore work in the container.


## Design decisions<a id="design"></a>

### Base image: Ubuntu 24.04 LTS<a id="design-base"></a>

`ubuntu:24.04` (noble) was chosen over newer releases on purpose: the client generation at the time of writing is built for/against Ubuntu 24.04 (the forum workaround used 24.04's `libcurl`; the client runs and reports "Type: ubuntu 24.04" without complaints). A newer Ubuntu could reintroduce the OpenSSL-symbol-mismatch class of problems between the system `libcurl` and the *bundled* OpenSSL, i.e. the exact failure seen on Fedora. Rule of thumb: track the newest Ubuntu LTS that pascom officially supports, not the newest LTS that exists.

### Multi-stage build, no client bits in the repository<a id="design-multistage"></a>

The tarball is downloaded from pascom's servers in a separate build stage (which also keeps `curl`/`bzip2` out of the runtime image) at *build time*. Nothing proprietary is stored in this repository, and the built image must not be redistributed (see [README licensing](README.md#licensing-copyright-image)). pascom publishes no checksums; the download at least happens via TLS from the official host. `PASCOM_CLIENT_URL` is a build argument so a specific release can be pinned via the release-archive URL scheme.

### Dependency list and build-time self-check<a id="design-deps"></a>

The package list in the `Containerfile` was determined empirically: run `ldd` against the main binary and the bundled Qt plugins inside a **pristine** `ubuntu:24.04` container (with `LD_LIBRARY_PATH` pointing to the bundled `lib/`) and map every `not found` entry to its Ubuntu package. A `RUN` step repeats this check at build time and fails the build if a future client release adds dependencies: the failure message lists exactly what is missing.

The self-check deliberately covers only plugin categories the softphone loads (platforms, Wayland/xcb integration, TLS, multimedia, input, network information, icon engines, the portal platform theme). Excluded categories reference libraries that are unavailable or pointless in Ubuntu 24.04 and are lazily loaded only on demand, so they never fail at runtime:

- `sqldrivers/`: Oracle (`libclntsh`), MySQL, ODBC, PostgreSQL, Firebird, Mimer client libraries; the client uses SQLite only.
- `printsupport/` (`libcups`), `platformthemes/libqgtk3.so` (GTK3 stack; the portal theme is used instead).
- `imageformats/libqtiff.so` wants `libtiff.so.5`, which no noble package provides (noble ships `libtiff.so.6`), propably a leftover from the vendor's Qt build environment.


### Audio<a id="design-audio"></a>

Only the **PulseAudio native socket** (`${XDG_RUNTIME_DIR}/pulse/native`, served by `pipewire-pulse` on modern hosts) is passed into the container, deliberately *not* `/dev/snd`: exposing raw ALSA hardware would put the container's ALSA stack back in charge of hardware the host's PipeWire already owns, recreating the original problem (device contention, broken enumeration) instead of solving it.

Inside the container:

- `libpulse0` serves the client's direct PulseAudio API usage (device enumeration, `PULSE_SERVER` is set by the launcher script).
- `libasound2-plugins` provides the ALSA→PulseAudio bridge (`libasound_module_pcm_pulse.so`) and `/etc/asound.conf` routes the ALSA `default`/`ctl` devices to it, which serves PJSIP's ALSA-based audio streams. The config is written explicitly instead of relying on the Debian/Ubuntu ALSA config drop-ins, to be deterministic.
- No PulseAudio cookie handling is needed: `pipewire-pulse` accepts same-UID connections on the socket, and the container runs with the host user's UID (`--userns=keep-id`).


### Display<a id="design-display"></a>

`QT_QPA_PLATFORM="wayland;xcb"` (Qt fallback list): native Wayland when the socket is mounted, X11/XWayland otherwise. The launcher mounts the host's Wayland socket to the fixed in-container name `wayland-0` and, as fallback, `/tmp/.X11-unix` plus `XAUTHORITY` (read-only). `/dev/dri` is passed for hardware-accelerated rendering (works, verified via the `amdgpu` messages in the log), `/dev/video*` for camera/video calls. `--ipc=host` (for X11 MIT-SHM) proved unnecessary; Qt's xcb platform falls back gracefully.


### Browser-based login and file dialogs (XDG desktop portal)<a id="design-portal"></a>

The cloud login requires opening a browser. Inside the container there is none, and installing one would be absurd. Solution: the host's **session D-Bus socket** is mounted, and everything URL/file-dialog-related is delegated to the host's `xdg-desktop-portal`:

- `QT_QPA_PLATFORMTHEME=xdgdesktopportal` (the client bundles this Qt platform theme) for dialogs.
- A shim at `/usr/local/bin/xdg-open` (also wired via `BROWSER` and `GIO_LAUNCH_DESKTOP`) calls `org.freedesktop.portal.OpenURI.OpenURI` via `gdbus`, so URLs open in the host's default browser. If no portal is reachable, it prints the URL for manual opening.

The session bus also provides host notifications and the tray icon (StatusNotifier; on GNOME an extension is required, as on Ubuntu).


### Networking<a id="design-network"></a>

The container runs with `--network=host`. A private network namespace breaks the client in two ways:

1. **Login callback**: after authenticating, the identity provider redirects the host's browser to `http://localhost:3008/...`, where the client runs a temporary OAuth callback HTTP server. With a private network namespace, the host's `localhost:3008` never reaches the client and the browser shows "Unable to connect" while the client keeps "Waiting for credentials". (Publishing the port would fix the login, but not point 2.)
2. **Media**: SIP/RTP uses dynamically negotiated UDP ports; pushing them through a rootless NAT stack (pasta/slirp4netns) is a recipe for one-way-audio and latency problems.

Host networking is the established pattern for containerized softphones; the reduced isolation is an accepted trade-off here (the client talks to the LAN/WAN like a natively installed softphone would). Verified: with `--network=host`, the client's listener sockets appear in the host's network namespace (`ss -ltnp` on the host shows `pascom_Client`).


### User, home directory, persistence<a id="design-user"></a>

`--userns=keep-id` runs the client with the host user's UID, so all mounted sockets and files are accessible without permission games. `HOME` is forced to `/home/pascom`, backed by a bind-mounted host directory for persistent logins/settings (`PASCOM_DATA_DIR`). `/home/pascom` exists `0777` in the image only as a fallback since the runtime UID is unknown at build time. `XDG_RUNTIME_DIR` inside the container is a tmpfs; Podman's `--tmpfs` cannot set an owner (`uid=` is rejected as a mount option), hence sticky `mode=1777`, the sockets bind-mounted into it keep their own ownership.


### SELinux<a id="design-selinux"></a>

The launcher uses `--security-opt label=disable` instead of `:z`/`:Z` volume labels: the container must access sockets in `${XDG_RUNTIME_DIR}` and `/tmp/.X11-unix`, and **relabeling those directories would break the host session** (they are shared with every other process of the user). Disabling label separation for this one container is the established pattern for desktop-app containers. On hosts without SELinux the option is harmless.


### Self-updater<a id="design-updater"></a>

`/opt/pascom_Client` is owned by root while the client runs unprivileged; the client detects this and disables its updater itself (log: `Disabling update because application directory is not writable`). This is intentional: updates via `update.sh` would be lost on container removal (`--rm`) and bypass image reproducibility. Update path: rebuild the image.


## Gotchas<a id="gotchas"></a>

- **Ubuntu 24.04 `t64` package names**: many library packages were renamed for the 64-bit `time_t` transition (`libasound2t64`, `libcurl4t64`, `libglib2.0-0t64`, ...). Keep this in mind when porting the package list to other Ubuntu releases.
- **First-run log noise**: `SQL Query failed ... "Parameter count mismatch"` criticals on an empty settings database and the `RendererController: Unknown renderer mode ""` message are client quirks, not container issues (they also appear on native Ubuntu first runs). Same for `qt.multimedia: Couldn't load pipewire-0.3 library`. Qt Multimedia probes for native PipeWire, then falls back to its FFmpeg/PulseAudio path, which is the path this image intends.
- **Window class differs per display server**: `net.pascom.pascom_Client` on Wayland, `pascom_Client` on X11 (affects `StartupWMClass` in `.desktop` files; the shipped one assumes Wayland).
- **`podman run --tmpfs` cannot chown**: `uid=`/`gid=` mount options are rejected; that is why the in-container `XDG_RUNTIME_DIR` tmpfs is `mode=1777`.
- **Do not relabel runtime dirs on SELinux hosts** (`:z`/`:Z` on `${XDG_RUNTIME_DIR}` or `/tmp/.X11-unix`), it breaks the host session. Use `label=disable` (see [above](#design-selinux)).
- **No published checksums** for the client tarball; version pinning is only possible via the release-archive URL (`--build-arg PASCOM_CLIENT_URL=...`).
- **Headset HID extras**: call-control buttons/busy lights (Jabra, Kuando) need `/dev/hidraw*` passthrough plus the udev rules from the vendor scripts on the *host*; plain headset audio (including Bluetooth) works without any of this since it goes through PipeWire.
- **`--replace` in the launcher**: a crashed previous container with the same name would otherwise block starting; note this also means you cannot run two instances (which the client does not support anyway).
- **JACK probe noise**: PJSIP probes for a JACK server at startup (`jack server is not running or cannot be started`, `Cannot connect to server socket`). Harmless; the ALSA→PulseAudio path is used.
- **Stale login browser tabs**: each login attempt carries a one-time `state` parameter. Completing the flow in a browser tab left over from an earlier (failed) attempt is silently ignored by the client ("Waiting for credentials" forever). Always use the freshly opened tab.
- **Softphone requires a softphone device on the PASCOM side**: if the user's preferred device is another endpoint (e.g. the mobile app), the client logs `Can't enable softphone because user doesn't have softphone device`, PJSIP stays unregistered and calls are placed via click-to-dial on that other device. This is account/device configuration in PASCOM, not a container issue. Audio device detection in the container works regardless (`New audio devices added` toast).


## Verification / test results<a id="verification"></a>

Tested 2026-07-07 on Fedora 44 (Workstation, Wayland/GNOME, PipeWire 1.4, SELinux disabled on the test host), Podman 5.8.3, client `120.R5073` (Qt 6.10.1):

- Image builds; build-time `ldd` self-check passes; image size ~700 MB.
- `pactl info`/`list` inside the container reaches the host PipeWire and lists all sinks/sources, including a Bluetooth headset and USB webcam microphone.
- ALSA→PulseAudio bridge works end-to-end: `arecord -D default` inside the container records from the host microphone.
- Client starts (offscreen and on Wayland), identifies as Ubuntu 24.04, and **detects audio devices**: `[service.DesktopAudioController] New audio devices added, do you want to use them?` (this is what failed natively on Fedora).
- Hardware-accelerated rendering active (`/dev/dri`, amdgpu).
- Self-updater disables itself as designed.
- Portal URL opening works: the `xdg-open` shim opens URLs in the host browser via `org.freedesktop.portal.OpenURI`.
- Browser-based login flow reaches the OAuth callback: with `--network=host` the client's listener sockets bind in the host network namespace, so the identity provider's redirect to `http://localhost:3008/...` connects (with a private network namespace this visibly fails: browser "Unable to connect", client stuck on "Waiting for credentials").
- Full login verified with a real account: WebSocket session established, roster/contacts/BLF loaded, click-to-dial calls placed and hung up successfully (via a mobile endpoint as preferred device; PJSUA initialized but stayed unregistered as the account had no softphone device assigned at test time, see [gotchas](#gotchas)).
- Known issue observed: reproducible client crash right after hangup in click-to-dial mode, analyzed as an upstream use-after-free (see [gotchas](#gotchas)).
- Not yet exercised: a call via the *local* softphone device (audio both ways), video calls, tray icon. The transport paths for all of these are in place and verified individually.


## Debugging tips<a id="debugging"></a>

```bash
# Shell in the running client container
podman exec -it pascom-client bash

# Audio stack from inside
podman exec pascom-client pactl info
podman exec pascom-client pactl list short sinks sources

# One-off shell with the same wiring as the client (replace entrypoint)
podman run --rm -it --entrypoint bash \
  ... # (mount/env options, see pascom-client.sh)
  localhost/pascom-client:latest

# What would break on a new client release? (dependency check by hand)
podman run --rm -v /path/to/new/pascom_Client:/mnt:ro docker.io/library/ubuntu:24.04 \
  bash -c 'export LD_LIBRARY_PATH=/mnt/lib; ldd /mnt/pascom_Client | grep "not found"'
```

Client logs go to stdout; persistent logs and settings live in the data directory (`~/.local/share/oci-pascom-client/.local/share/pascom_Client/`).


## Possible future improvements<a id="future"></a>

- **Flatpak manifest** wrapping the vendor tarball (`extra-data`), now that the required runtime pieces are known precisely from this project. Would give portals/audio sandboxing for free but requires bundling the system-linked libraries per release.
- **Native PipeWire socket** passthrough (`${XDG_RUNTIME_DIR}/pipewire-0`) plus `libpipewire-0.3-0t64`, letting Qt Multimedia use PipeWire directly instead of the PulseAudio compatibility layer. Not needed functionally; evaluate only if audio issues surface.
- **Quadlet/systemd user unit** instead of the launcher script.
- **HID passthrough opt-in** (`/dev/hidraw*` + udev rules) for Jabra call control / busy lights.
- **CI rebuild reminder**: periodic job that downloads the tarball, compares the redirect target version and notifies when a rebuild is due (the redirect filename contains the version).
