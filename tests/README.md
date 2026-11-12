Host tests for the lab build. No libvirt, no VM.

`tests/render-test.sh [--record-baseline] [ubuntu|fedora|all] [TEST...]`

The script copies the tracked files to a temporary directory and writes a test `lab.env`.
It replaces `guest-exec.sh` with a stub, builds fake ISOs and runs `./build.sh client iso`.
Output lines: `ok NAME`, `FAIL NAME: message`, `skip NAME: reason`. Exit code 1 on any failure.
`tests/baseline/ubuntu/` is the recorded Ubuntu render. Record it again only for a wanted Ubuntu change.
`KEEP=1` keeps the temporary copy.
