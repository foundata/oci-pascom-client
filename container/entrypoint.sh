#!/usr/bin/env bash

# Entrypoint of the PASCOM client OCI image: sets sane Qt defaults for a
# containerized GUI session, then hands over to the official AppRun launcher.
#
# SPDX-FileCopyrightText: foundata GmbH <https://foundata.com>
# SPDX-License-Identifier: GPL-3.0-or-later

set -u

# Prefer native Wayland, fall back to X11/XWayland (";" is Qt's fallback
# separator). Respect a value pre-set by the caller (e.g. the launcher script
# or "podman run --env").
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland;xcb}"

# Delegate file dialogues and URL opening to the host via the XDG desktop
# portal (the host's session D-Bus socket is bind-mounted by the launcher
# script). Already set as image default, kept here for robustness.
export QT_QPA_PLATFORMTHEME="${QT_QPA_PLATFORMTHEME:-xdgdesktopportal}"
export QT_PLATFORMTHEME="${QT_PLATFORMTHEME:-${QT_QPA_PLATFORMTHEME}}"

# Some code paths resolve URL handlers via GLib instead of xdg-open. Point
# GLib's launcher to the portal-based shim, too.
export GIO_LAUNCH_DESKTOP="${GIO_LAUNCH_DESKTOP:-/usr/local/bin/xdg-open}"

exec "/opt/pascom_Client/AppRun" "$@"
