# OCluster linux-riscv64 worker VMs, fully baked.
#
# These run under QEMU TCG emulation on the arm64 caelum hosts to drain the
# riscv64 backlog while Scaleway is down. A single `make` boots the image once
# with a cloud-init seed that installs docker + the ocluster-worker binary,
# bakes in the linux-riscv64 pool capability, enables the worker service, and
# powers off. The resulting 3-disk set is ready to run (see run.sh).
#
#   make NAME=riscv-qemu-ainia-1      # build one worker image set
#
# Each worker is a separate fully-baked build (hostname + --name baked in), so
# build once per worker. The slow part is the emulated apt/docker pull.

NAME        ?= riscv-qemu-01
# RELEASE is the Ubuntu codename: resolute = 26.04 LTS (Resolute Raccoon).
RELEASE     ?= resolute
ROOT_SIZE   ?= 50G
DOCKER_SIZE ?= 50G
STORE_SIZE  ?= 50G
# Emulated build steps rarely use more than ~4 vCPUs, and the guest uses ~1G of
# real RAM (the rest is reclaimable page cache), so small workers pack densely
# without hurting per-build time. Bump per-host with SMP=/MEM= if you run few.
MEM         ?= 12G
SMP         ?= 4

# Ubuntu 26.04 (resolute) requires the RVA23 profile (-cpu rva23s64), which the
# distro QEMU 8.2 does not provide. `make qemu` builds QEMU 11 into /usr/local;
# QEMU resolves to that build via PATH. Override QEMU= to use a specific binary.
QEMU         ?= qemu-system-riscv64
QEMU_VERSION ?= 11.0.1

# The linux-riscv64 pool capability is read from a local, git-ignored file and
# baked into the image. Create it once (the secrets/ directory is git-ignored):
#   mkdir -p secrets && echo '<capnp://...pool cap...>' > secrets/linux-riscv64.cap
# Override on the command line with POOL_CAP=... if you prefer.
CAP_FILE    ?= secrets/linux-riscv64.cap
POOL_CAP    ?= $(shell cat $(CAP_FILE) 2>/dev/null)

BASE_IMG    := $(RELEASE)-server-cloudimg-riscv64.img

.PHONY: all base clean deps qemu

all: $(NAME).qcow2

# Build the worker: create the three disks, then boot once with the seed so
# cloud-init installs everything and powers off. Network is outbound-only NAT.
$(NAME).qcow2: $(BASE_IMG) seed-$(NAME).iso
	@test -n "$(POOL_CAP)" || { echo "ERROR: POOL_CAP is empty - is $(CAP_FILE) present (or pass POOL_CAP=...)?"; exit 1; }
	qemu-img convert -O qcow2 $(BASE_IMG) $@
	qemu-img resize $@ $(ROOT_SIZE)
	qemu-img create -f qcow2 $(NAME)-docker.qcow2 $(DOCKER_SIZE)
	qemu-img create -f qcow2 $(NAME)-obuilder.qcow2 $(STORE_SIZE)
	$(QEMU) -cpu rva23s64 -m $(MEM) -smp $(SMP) -machine virt,acpi=off -nographic \
		-kernel /usr/lib/u-boot/qemu-riscv64_smode/uboot.elf \
		-drive file=$@,if=virtio \
		-drive file=$(NAME)-docker.qcow2,if=virtio \
		-drive file=$(NAME)-obuilder.qcow2,if=virtio \
		-drive file=seed-$(NAME).iso,format=raw,if=virtio \
		-device virtio-rng-pci \
		-netdev user,id=net0 -device virtio-net-device,netdev=net0

# Render the cloud-init seed. The hostname/worker name and the pool capability
# are substituted in here; the rendered user-data is git-ignored as it holds
# the capability secret.
seed-$(NAME).iso: user-data.yaml.m4
	m4 -D __NAME__=$(NAME) -D __CAP__="$(POOL_CAP)" $< > user-data-$(NAME).yaml
	cloud-localds $@ user-data-$(NAME).yaml

# Build the shared, generic base image (no per-worker identity): boot once to
# install everything, then power off; keep only base.qcow2 (the root). Per-worker
# roots are thin overlays on it (new-worker.sh), so the slow bake happens ONCE
# and each worker is then created in seconds with much less disk.
base: $(BASE_IMG) seed-base.iso
	@test -n "$(POOL_CAP)" || { echo "ERROR: POOL_CAP is empty - is $(CAP_FILE) present (or pass POOL_CAP=...)?"; exit 1; }
	qemu-img convert -O qcow2 $(BASE_IMG) base.qcow2
	qemu-img resize base.qcow2 $(ROOT_SIZE)
	qemu-img create -f qcow2 base-docker.qcow2 $(DOCKER_SIZE)
	qemu-img create -f qcow2 base-obuilder.qcow2 $(STORE_SIZE)
	$(QEMU) -cpu rva23s64 -m $(MEM) -smp $(SMP) -machine virt,acpi=off -nographic \
		-kernel /usr/lib/u-boot/qemu-riscv64_smode/uboot.elf \
		-drive file=base.qcow2,if=virtio \
		-drive file=base-docker.qcow2,if=virtio \
		-drive file=base-obuilder.qcow2,if=virtio \
		-drive file=seed-base.iso,format=raw,if=virtio \
		-device virtio-rng-pci \
		-netdev user,id=net0 -device virtio-net-device,netdev=net0
	rm -f base-docker.qcow2 base-obuilder.qcow2 seed-base.iso user-data-base.yaml
	@echo "base.qcow2 ready - create workers with: ./new-worker.sh <name>"

seed-base.iso: user-data-base.yaml.m4
	m4 -D __CAP__="$(POOL_CAP)" $< > user-data-base.yaml
	cloud-localds $@ user-data-base.yaml

$(BASE_IMG):
	curl -C - -L https://cloud-images.ubuntu.com/$(RELEASE)/current/$@ -o $@

# Build/run-host tooling. QEMU itself comes from `make qemu` (the distro qemu is
# too old for resolute); u-boot-qemu still provides the S-mode bootloader, and
# qemu-utils provides qemu-img. On a remote build host without secrets/, pass the
# capability in directly: make NAME=... POOL_CAP=...
deps:
	sudo apt-get update
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y m4 cloud-image-utils qemu-utils u-boot-qemu numactl btrfs-progs

# Build and install QEMU $(QEMU_VERSION) (riscv64 target only) into /usr/local,
# for -cpu rva23s64. Needed on every host that builds or runs these VMs.
qemu:
	sudo apt-get update
	sudo DEBIAN_FRONTEND=noninteractive apt-get install -y git build-essential ninja-build meson pkg-config python3-venv flex bison libglib2.0-dev libpixman-1-dev libslirp-dev
	curl -L -O https://download.qemu.org/qemu-$(QEMU_VERSION).tar.xz
	tar xf qemu-$(QEMU_VERSION).tar.xz
	cd qemu-$(QEMU_VERSION) && ./configure --target-list=riscv64-softmmu --prefix=/usr/local --enable-slirp && make -j$$(nproc) && sudo make install
	qemu-system-riscv64 --version | head -1

clean:
	rm -f *.qcow2 seed-*.iso user-data-*.yaml *.log
