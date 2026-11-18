#!/bin/sh
# apt runs it after a kernel removal: $1 = kernel version.
set -eu
exec /usr/local/sbin/mld-uki remove "$1"
