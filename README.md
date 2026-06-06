# riscv_worker

Build and run **OCluster `linux-riscv64` worker** VMs under QEMU emulation on
non-riscv hardware (x86_64 / arm64 / ppc64le). Each VM is a self-contained,
fully-baked worker: it boots, mounts its disks, connects to its OCluster pool,
and starts taking jobs.

A single `make` produces the image in one cloud-init pass that installs Docker,
fetches the `ocluster-worker` binary, bakes in the pool capability, enables the
service, and powers off. There is no separate provisioning step. It is handy for
adding RISC-V CI capacity (or running any riscv64 workload) on whatever spare
x86_64, arm64, or ppc64le machines you have.

> **Emulation note:** there is no KVM for riscv64 on these hosts, so the guests
> run under pure TCG emulation, well below native riscv speed. The model is to
> run many cheap workers across otherwise-idle hardware.

## Layout

Each worker is a set of three disks (`make NAME=<name>` produces them):

| Disk | Mount | FS | Purpose |
|------|-------|----|---------|
| `<name>.qcow2` | `/` | ext4 | root (Ubuntu 26.04 cloud image, grown to 50G) |
| `<name>-docker.qcow2` | `/var/lib/docker` | ext4 | docker data-root (50G) |
| `<name>-obuilder.qcow2` | `/var/cache/obuilder` | btrfs | obuilder store (50G) |

Disks are thin qcow2, so virtual size is a ceiling, not consumption. The
obuilder btrfs store is the only real grower; `--obuilder-prune-threshold=30`
keeps it ~30% free, so a 50G store caps steady-state usage around 35G. Keep the
sum of all workers' stores comfortably under the host volume.

## One-time setup (per host)

```sh
make deps        # m4, cloud-image-utils, qemu-utils, u-boot-qemu
make qemu        # build + install QEMU 11 into /usr/local (see below)
```

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

```sh
make NAME=riscv-qemu-<host>-1
```

The build downloads the `resolute` (26.04) riscv64 cloud image, creates the
three disks, then boots once with a cloud-init seed that:

1. formats + mounts the docker and obuilder disks,
2. installs docker and the worker-role dependencies,
3. pulls `ocurrent/ocluster-worker:live` and extracts the `ocluster-worker` binary,
4. bakes `/etc/ocluster/pool.cap` (from `secrets/linux-riscv64.cap` or `POOL_CAP=...`),
5. installs and **enables** (does not start) `ocluster-worker.service`,
6. powers off.

The next boot brings up a live worker. Build once **per worker**, since the
hostname and `--name` are baked in. The slow step is the emulated apt/docker
pull (roughly a couple of hours cold, dominated by the base-image pull).

## Run

`run.sh` auto-discovers every built worker in the directory and starts it,
assigning an SSH-forward port (`60022+`) and VNC display (`:0+`) by index, with
no editing needed:

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
  --prune-threshold=30 --obuilder-prune-threshold=30 \
  --capacity=1 --state-dir=/var/cache/obuilder/ocluster -v
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
