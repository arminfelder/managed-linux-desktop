#!/bin/sh
# apt runs it after a kernel install: $1 = kernel version.
set -eu
exec /usr/local/sbin/mld-uki "$1"
