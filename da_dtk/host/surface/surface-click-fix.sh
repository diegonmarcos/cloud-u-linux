#!/bin/sh
# Fix KWin Wayland stuck input (KDE bug 515195)
# Lighter alternative to full driver reset
dbus-send --session --dest=org.freedesktop.ScreenSaver --type=method_call /ScreenSaver org.freedesktop.ScreenSaver.SimulateUserActivity
echo "Input reset via ScreenSaver - clicks should work now"
