#!/usr/bin/env bash
# hm-auto-update-cancel.sh — generated from programs/hm-auto-update.nix, do
# not edit by hand. Mid-switch cancel: stop the detached switch unit (named
# in the notify text). The switch is a detached `systemd-run --user` unit
# named hm-auto-switch; stopping it aborts the download/activation.
exec systemctl --user stop hm-auto-switch
