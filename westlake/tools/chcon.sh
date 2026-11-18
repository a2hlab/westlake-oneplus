#!/bin/sh
# chcon for the Westlake device tools on the OnePlus 6 build: SELinux is disabled there and its toybox has
# no chcon applet, so a label change has no effect. Refuse if SELinux is ever active.
if [ -e /sys/fs/selinux/enforce ]; then echo "chcon: SELinux is active; this no-op stand-in must not be used" >&2; exit 1; fi
exit 0
