#!/bin/sh
# apt runs it after a kernel removal: $1 = kernel version.
exec /usr/local/sbin/mld-uki remove "$1"
