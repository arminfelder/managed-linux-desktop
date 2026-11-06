#!/bin/sh
# apt runs it after a kernel install: $1 = kernel version.
exec /usr/local/sbin/mld-uki "$1"
