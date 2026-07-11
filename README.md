# OCI Image: PASCOM client (for non-Ubuntu Linux hosts)

The [PASCOM desktop client]((https://www.pascom.net/downloads/)) for Linux is only supported on [Ubuntu](https://ubuntu.com/) (as 2026-Q3). This project packages the official PASCOM client in an Ubuntu LTS based [OCI](https://opencontainers.org/) container so it can also be used on other Linux distributions like [Fedora](https://fedoraproject.org/).

This is an community effort; there is no official support by [PASCOM](https://www.pascom.net/) running the client this way, but the [forum](https://forum.pascom.net/t/stand-linux-client-abseits-von-ubuntu-hier-fedora/11687/8) might help you out when there are problems.

Main features:

- **Working audio, including Bluetooth headsets**: the host's [PipeWire](https://pipewire.org/) / [PulseAudio](https://www.freedesktop.org/wiki/Software/PulseAudio/) is passed into the container via its native socket. Both the client's PJSIP telephony stack (ALSA, bridged to PulseAudio) and its device enumeration (PulseAudio API) work.
- **Native Wayland support** with X11/XWayland fallback, hardware-accelerated rendering (`/dev/dri`) and camera passthrough for video calls.
- **Desktop integration**: notifications and the browser-based login open on the *host* (via the session D-Bus and the [XDG desktop portal](https://flatpak.github.io/xdg-desktop-portal/)); persistent client configuration; example `.desktop` launcher.
- **Unprivileged execution**: rootless Podman, running with the host user's UID (`--userns=keep-id`). The container uses host networking, which the browser-based login (`localhost` callback) and SIP/RTP media require (see [`DEVELOPMENT.md`](DEVELOPMENT.md) for details).

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for background, design decisions and gotchas.



## Table of contents<a id="toc"></a>

- [Requirements](#requirements)
- [How to build](#build)
- [How to use](#usage)
  - [Start the client](#usage-start)
  - [Desktop integration](#usage-desktop)
  - [Updating the client](#usage-update)
  - [Troubleshooting](#usage-troubleshooting)
- [Non-goals / Limitations](#limitations)
- [Licensing, copyright](#licensing-copyright)
  - [Container configuration, repository](#licensing-copyright-project)
  - [Container image](#licensing-copyright-image)
- [Author information](#author-information)



## Requirements<a id="requirements"></a>

Usually just a recent Linux with a graphical desktop (like GNOME or KDE) and Podman. In detail:

1. [Podman](https://podman.io/docs/installation) (rootless setup; tested with Podman ≥ 5) to build and run the container.
2. [`xdg-desktop-portal`](https://flatpak.github.io/xdg-desktop-portal/) with a desktop backend for opening the PASCOM login page in the host's browser.<br>If not already pre-installed, get the packages from your distribution's default repositories: `xdg-desktop-portal` plus the fitting desktop backend (e.g. `xdg-desktop-portal-gnome` or `xdg-desktop-portal-kde`)

The following should be available by default on all common desktop distributions but are listed here for completeness:

- A graphical user session (Wayland or X11) with a session D-Bus.
- PipeWire or PulseAudio providing the native PulseAudio socket at `${XDG_RUNTIME_DIR}/pulse/native` (default on all common desktop distributions, including Fedora Workstation).



## How to build<a id="build"></a>

The image is **not** distributed via a registry as it contains the proprietary PASCOM client (see [licensing](#licensing-copyright-image)).

To build the image locally, do the following:

1. [Install Podman](https://podman.io/docs/installation).
2. Clone or pull the latest changes from the [`foundata/oci-pascom-client` git repository](https://github.com/foundata/oci-pascom-client).
3. Change into the directory and execute the [build command](https://docs.podman.io/en/latest/markdown/podman-build.1.html):
   ```bash
   podman build -t pascom-client .
   ```
   This downloads the latest official client tarball from PASCOMS's servers. To pin a specific client version, pass a versioned URL from PASCOMS's release archive:
   ```bash
   podman build \
     --build-arg PASCOM_CLIENT_URL="https://download.pascom.net/release-archive/client/cloud/pascom_Client-120.R5073-linux.tar.bz2" \
     -t pascom-client .
   ```



## How to use<a id="usage"></a>

### Start the client<a id="usage-start"></a>

Use the [`pascom-client.sh`](pascom-client.sh) launcher script. It wires display, audio, D-Bus, GPU and camera into the container and starts the client with your UID:

```bash
./pascom-client.sh
```

On first start, log in as usual: the client opens the PASCOM login page in your host's default browser. Client configuration and login persist across runs in `~/.local/share/oci-pascom-client/` on the host (change via the `PASCOM_DATA_DIR` environment variable; `PASCOM_IMAGE` overrides the image name).

All command line arguments are passed through to the PASCOM client.


### Desktop integration<a id="usage-desktop"></a>

To get a normal application launcher entry:

```bash
# Make the launcher script available in your PATH
mkdir -p ~/.local/bin
cp pascom-client.sh ~/.local/bin/
chmod +x ~/.local/bin/pascom-client.sh

# Extract the client icon from the image
mkdir -p ~/.local/share/icons/hicolor/256x256/apps
podman run --rm --entrypoint cat localhost/pascom-client:latest \
  /opt/pascom_Client/client.png \
  > ~/.local/share/icons/hicolor/256x256/apps/pascom-client.png

# Install the desktop entry
mkdir -p ~/.local/share/applications
cp pascom-client.desktop ~/.local/share/applications/
```

Note: The tray icon uses the StatusNotifier D-Bus protocol. On GNOME, this additionally requires an extension like [AppIndicator and KStatusNotifierItem Support](https://extensions.gnome.org/extension/615/appindicator-support/) (as it does for the client on Ubuntu, too).


### Updating the client<a id="usage-update"></a>

The client's built-in self-updater is intentionally disabled (the application directory in the image is read-only for the executing user). To update the client, simply rebuild the image; the download URL always delivers the latest release:

```bash
podman build --no-cache -t pascom-client .
```


### Troubleshooting<a id="usage-troubleshooting"></a>

- **No audio devices in the client:** Check that the host socket exists (`ls "${XDG_RUNTIME_DIR}/pulse/native"`) and that audio works inside the container:
  ```bash
  podman exec pascom-client pactl info
  ```
  (while the client is running; the container is named `pascom-client`).
- **Login page does not open:** The URL is also printed to the terminal by the container's `xdg-open` shim if the XDG desktop portal is not reachable; open it manually in that case.
- **Login page opens, but the browser then shows "Unable to connect" to `localhost:3008` while the client keeps "Waiting for credentials":** The container was started without host networking. The login flow redirects the browser to an OAuth callback server the client runs on the host's `localhost:3008`, so the container must share the host's network namespace. Use the shipped launcher script (it passes `--network=host`).
- **SELinux denials:** The launcher script disables SELinux label separation for the container (`--security-opt label=disable`) because it must access sockets in `${XDG_RUNTIME_DIR}`. Do *not* replace this with `:z`/`:Z` volume options, as relabeling `${XDG_RUNTIME_DIR}` breaks the host session.
- **Verbose logs:** The client writes logs to stdout; start it from a terminal via `./pascom-client.sh`.

This is an community effort; there is no official support by [PASCOM](https://www.pascom.net/) running the client this way, but the [forum](https://forum.pascom.net/t/stand-linux-client-abseits-von-ubuntu-hier-fedora/11687/8) might help you out when there are problems.



## Non-goals / Limitations<a id="limitations"></a>

This project is a pragmatic wrapper to run the official PASCOM client on non-Ubuntu hosts. It does **not** provide:

- Guaranteed compatibility with container runtimes other than [Podman](https://podman.io/). We do *not* support [Docker](https://www.docker.com/) (but it might work).
- USB HID device integration for headset call control (e.g. Jabra busy light and call buttons) or Kuando Busylights. Plain audio via any headset works; the extra HID features would need `/dev/hidraw*` passthrough and udev rules (see [`DEVELOPMENT.md`](DEVELOPMENT.md)).
- Automatic client updates (rebuild the image instead, see [above](#usage-update)).


## Licensing, copyright<a id="licensing-copyright"></a>

### Container configuration, repository<a id="licensing-copyright-project"></a>

<!--REUSE-IgnoreStart-->
Copyright (c) 2026 [foundata GmbH](https://foundata.com/) (https://foundata.com)

This project is licensed under the GNU General Public License v3.0 or later (SPDX-License-Identifier: `GPL-3.0-or-later`), see [`LICENSES/GPL-3.0-or-later.txt`](LICENSES/GPL-3.0-or-later.txt) for the full text.

The [`REUSE.toml`](REUSE.toml) file provides detailed licensing and copyright information in a human- and machine-readable format. This includes parts that may be subject to different licensing or usage terms, such as third-party components. The repository conforms to the [REUSE specification](https://reuse.software/spec/). You can use [`reuse spdx`](https://reuse.readthedocs.io/en/latest/readme.html#cli) to create a [SPDX software bill of materials (SBOM)](https://en.wikipedia.org/wiki/Software_Package_Data_Exchange).
<!--REUSE-IgnoreEnd-->

[![REUSE status](https://api.reuse.software/badge/github.com/foundata/oci-pascom-client/)](https://api.reuse.software/info/github.com/foundata/oci-pascom-client/)


### Container image<a id="licensing-copyright-image"></a>

An image built from this repository bundles various software components along with direct and indirect dependencies, which are subject to their respective licenses. When using it, **you are responsible for ensuring that your usage complies with all relevant licenses** for the software contained within the image.

For further licensing information about the software contained in an image built from this repository, please refer to the following resources:

- https://ubuntu.com/legal/open-source-licences
- https://www.pascom.net/en/terms-and-conditions/

Do **not** push or otherwise redistribute the built image (e.g. to a public registry) as an image built from this repository contains the **proprietary PASCOM client** (downloaded from PASCOM's official servers at build time).


### Trademarks<a id="trademarks"></a>

* [PASCOM® is a word and figurative trademark](https://register.dpma.de/DPMAregister/marke/register/3020190007065/DE) of [PASCOM GmbH](https://www.pascom.net/), registered in Germany and probably other countries.



## Author information<a id="author-information"></a>

This [project](https://foundata.com/en/projects/) was created and is maintained by [foundata](https://foundata.com/).

The PASCOM client OCI project is *not* associated with [PASCOM GmbH](https://www.pascom.net).
