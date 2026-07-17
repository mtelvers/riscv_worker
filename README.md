# riscv_worker

Build and run **OCluster `linux-riscv64` worker** VMs under QEMU emulation on
non-riscv hardware (x86_64 / arm64 / ppc64le). Each VM is a self-contained,
fully-baked worker: it boots, mounts its disks, connects to its OCluster pool,
and starts taking jobs.

A one-time `make base` produces a shared base image in a single cloud-init pass
that installs Docker, fetches the `ocluster-worker` binary, bakes in the pool
capability, enables the service, and powers off. Each worker is then created in
seconds as a thin copy-on-write overlay on that base (`./new-worker.sh <name>`),
so the slow emulated install happens once and every worker after it costs only
its own writes. There is no separate provisioning step. It is handy for adding
RISC-V CI capacity (or running any riscv64 workload) on whatever spare x86_64,
arm64, or ppc64le machines you have.

> **Emulation note:** there is no KVM for riscv64 on these hosts, so the guests
> run under pure TCG emulation, well below native riscv speed. The model is to
> run many cheap workers across otherwise-idle hardware.

## Layout

Each worker is a set of three disks (`./new-worker.sh <name>` produces them):

| Disk | Mount | FS | Purpose |
|------|-------|----|---------|
| `<name>.qcow2` | `/` | ext4 | root, a copy-on-write overlay on `base.qcow2` |
| `<name>-docker.qcow2` | `/var/lib/docker` + `/var/lib/containerd` | ext4 | docker **and** containerd data (50G) |
| `<name>-obuilder.qcow2` | `/var/cache/obuilder` | btrfs | obuilder store (50G) |

The root is an overlay, so a fresh worker's `<name>.qcow2` is only tens of MB
(its writes over the shared `base.qcow2`) rather than a full ~17G copy of the
base. The data disks are private to each worker.

The docker disk is bind-mounted onto **both** `/var/lib/docker` and
`/var/lib/containerd`. Docker 29 keeps the bulk of its data (images, snapshots,
BuildKit cache) under `/var/lib/containerd` via the system containerd, not
`/var/lib/docker`. Putting both on the one disk keeps that data off the root
overlay **and** on the filesystem ocluster's `--prune-threshold` watches, so the
docker prune actually fires on it. (docker's and containerd's top-level dir
names are disjoint, so sharing a directory is safe.)

Disks are thin qcow2 with `discard=unmap`, and the guest mounts use
`discard`/`discard=async` plus `fstrim.timer`, so freed space is returned to the
host instead of ratcheting to high-water. The obuilder btrfs store is the main
grower; `--obuilder-prune-threshold=30` keeps it ~30% free, capping a 50G store
around 35G. Budget ~50G per worker (obuilder + docker/containerd + root) and keep
the sum of all workers comfortably under the host volume — e.g. ~24 workers on a
1.5T volume, not 30.

## One-time setup (per host)

```sh
make deps        # m4, cloud-image-utils, qemu-utils, u-boot-qemu
make qemu        # build + install QEMU 11 into /usr/local (see below)
make uboot       # optional: build a current U-Boot; only needed for CPU=...,zkr=on / max
```

**`make uboot` (optional).** The distro U-Boot (Ubuntu 22.04 ships 2022.01) boots
plain `rva23s64`, but its FDT buffer is too small for a richer CPU — `-cpu
rva23s64,zkr=on` or `-cpu max` fail in U-Boot with `initcall ... err=-28`. `make
uboot` cross-builds a current U-Boot (v2026.07) into `/usr/local`, which boots
those fine. Then run workers with it via `UBOOT=/usr/local/lib/u-boot/qemu-riscv64_smode/uboot.elf CPU=rva23s64,zkr=on ./run.sh`. Not needed for normal use.

**Why `make qemu`?** Ubuntu 26.04 (`resolute`) requires the RVA23 profile
(`-cpu rva23s64`), which the distro QEMU (8.2) does not provide. It only has
`-cpu max`, and the guest kernel spins with no output. `make qemu` builds the
`riscv64-softmmu` target of QEMU 11 into `/usr/local`, which PATH then resolves
ahead of the distro build. On Ubuntu 22.04 hosts also `apt install python3-tomli`
first (QEMU's configure needs it; Python 3.12 has it built in).

Provide the pool capability via a **git-ignored** file (or `POOL_CAP=...` on the
command line):

```sh
mkdir -p secrets
echo '<capnp://...linux-riscv64 pool cap...>' > secrets/linux-riscv64.cap
```

## Build

Build the shared base image once, then create each worker as an overlay:

```sh
make base                       # one-time, slow (emulated install)
./new-worker.sh riscv-qemu-<host>-1   # seconds, repeat per worker
./new-worker.sh riscv-qemu-<host>-2
```

`make base` downloads the `resolute` (26.04) riscv64 cloud image and boots it
once with a cloud-init seed that:

1. installs docker and the worker-role dependencies,
2. pulls `ocurrent/ocluster-worker:live` and extracts the `ocluster-worker` binary,
3. bakes `/etc/ocluster/pool.cap` (from `secrets/linux-riscv64.cap` or `POOL_CAP=...`),
4. installs and **enables** (does not start) `ocluster-worker.service`,
5. powers off.

It keeps only `base.qcow2` (the throwaway data disks are discarded). The slow
step is the emulated apt/docker pull, roughly a couple of hours cold, dominated
by the base-image pull. It runs once per host.

`./new-worker.sh <name>` then creates a worker from that base without booting it:
a copy-on-write overlay root, fresh labelled docker (ext4) and obuilder (btrfs)
disks, and the worker's identity (`/etc/hostname`) written into the overlay. The
worker name is not baked into the base; the systemd unit takes `--name` from the
hostname at runtime (`%H`), so one base serves every worker. The next `run.sh`
boot brings up a live worker.

### Fully-baked single worker (alternative)

To build a single self-contained worker with no shared base (hostname and
`--name` baked into its own root), use the per-worker target instead:

```sh
make NAME=riscv-qemu-<host>-1
```

This is the same install, but the identity is baked in and the root is a full
image rather than an overlay. Prefer `make base` + `new-worker.sh` when running
more than one worker on a host.

## Run

`run.sh` auto-discovers every built worker in the directory and starts any that
are not already running, assigning each the next free SSH-forward port
(`60022+`) and VNC display (`:0+`), with no editing needed:

```sh
./run.sh
```

VMs run in the background; serial console goes to `<name>-console.log`, qemu
stdout/stderr to `<name>.log`. SSH in for debugging via the forwarded port
(`ssh -p 60022 opam@<host>`). Override size with `MEM=` / `SMP=`.

### NUMA-aware pinning (`PIN_CORES`)

On a host booted with `isolcpus`, the kernel won't load-balance the isolated
cores, so a broad affinity mask makes QEMU's vCPU threads bunch onto a few of
them. Set `PIN_CORES` to the usable core set and each worker is placed on a
single NUMA node. Its RAM is bound there with `numactl --membind`, and its `SMP`
vCPU threads are pinned **1:1** onto that node's cores (the precise form of
`numactl --cpunodebind`):

```sh
PIN_CORES=4-63,68-127 ./run.sh
```

Workers are spread across nodes (each gets a node-local core block), so CPU and
memory stay on the same socket. Leave `PIN_CORES` **unset** on normal
single-socket or non-isolated hosts. The scheduler spreads vCPUs fine, and there
is no NUMA locality to win.

## Worker config (baked into the systemd unit)

The baked `ocluster-worker.service` runs:

```
ocluster-worker -c /etc/ocluster/pool.cap --name=<name> \
  --obuilder-store=btrfs:/var/cache/obuilder --fast-sync \
  --allow-push ocurrentbuilder/staging,ocurrent/opam-staging \
  --prune-threshold=80 --obuilder-prune-threshold=65 \
  --capacity=1 --state-dir=/var/cache/obuilder/ocluster -v
```

The prune thresholds are `% free below which the worker prunes` — higher means a
smaller cache. They bound each worker's disk: docker (`--prune-threshold=80`)
caps ~10G since it only needs a few base images, and the obuilder build cache
(`--obuilder-prune-threshold=65`) caps ~17.5G. Note both caches **grow to their
cap** (docker keeps old weekly base images until pruned; it does not shrink on
its own), so size the cap, not the expected use.

## Disk-usage alert (`scratch-alert.sh`)

`scratch-alert.sh` runs from a root cron on the worker host (hourly) and Slacks a
warning **only** if `/local/scratch` reaches 85% — it exits silently below that,
so there is no routine ping, just an alert when action is needed. It reads the
webhook URL from a root-only file so no secret lives in the script or git:

```sh
echo 'https://hooks.slack.com/services/...' > /usr/local/etc/scratch-alert.url
chmod 600 /usr/local/etc/scratch-alert.url
install -m755 scratch-alert.sh /usr/local/bin/scratch-alert.sh
( crontab -l 2>/dev/null; echo '0 * * * * /usr/local/bin/scratch-alert.sh' ) | crontab -
```

## Caveats

- **Registry push credentials are not configured.** `--allow-push` only
  whitelists; if a job actually pushes to `ocurrentbuilder/staging` /
  `ocurrent/opam-staging`, the VM needs docker-hub credentials
  (`~/.docker/config.json` or `docker login`). Most opam-CI riscv jobs don't push.
- `secrets/`, the disk images, the rendered `user-data-<name>.yaml` (which
  contains the capability), and the logs are all git-ignored.
- Stale registration after a reboot: stop the worker, `ocluster-admin forget
  linux-riscv64 <name>`, start it again.
