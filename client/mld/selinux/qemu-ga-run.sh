#!/bin/bash
# The guest agent (virt_qemu_ga_t) starts the lab snippets of build.sh through this file (guest-exec.sh, Fedora).
# The file type virt_qemu_ga_unconfined_exec_t and the boolean virt_qemu_ga_run_unconfined make the snippet unconfined.
# qemu-ga gives PATH=/usr/local/bin:/usr/bin only (seen 2026-11-17). The mld-* commands are in /usr/local/sbin.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
exec /bin/bash "$@"
