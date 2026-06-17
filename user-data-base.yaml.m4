#cloud-config
# Generic OCluster linux-riscv64 worker BASE image (no per-worker identity).
# Built once with `make base`; per-worker roots are thin overlays on this
# (see new-worker.sh). The worker --name is taken from the hostname at runtime
# (systemd %H specifier), and each overlay sets its own /etc/hostname, so the
# base needs no rebuild to change identity. __CAP__ is substituted by m4.
hostname: riscv-worker-base
preserve_hostname: true

users:
  - name: opam
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA09mqKPpMJ4tyOpl4l+KTTl1DqjFT2mRD29HW8VwnmB root@alpha

write_files:
  - path: /etc/ocluster/pool.cap
    permissions: '0400'
    content: |
      __CAP__
  - path: /etc/docker/daemon.json
    permissions: '0644'
    content: |
      {
        "experimental": true
      }
  - path: /etc/default/prometheus-node-exporter
    permissions: '0644'
    content: |
      ARGS="--collector.filesystem.ignored-mount-points=^/(sys|proc|dev|run|var/cache/obuilder/.+|var/lib/docker/.+|var/lib/containerd/.+)($|/)"
  - path: /etc/systemd/system/containerd.service.d/10-data-mount.conf
    permissions: '0644'
    content: |
      [Unit]
      # containerd's root is /var/lib/containerd, which we bind-mount onto the
      # docker data disk (see fstab) so all of docker+containerd's data lives on
      # one disk - the filesystem ocluster's --prune-threshold watches. Wait for
      # that mount, or containerd races on boot and writes to the root overlay
      # before the bind is up, silently recreating the split.
      RequiresMountsFor=/var/lib/containerd
  - path: /etc/sysctl.d/99-ocluster.conf
    permissions: '0644'
    content: |
      net.ipv4.tcp_keepalive_time = 60
  - path: /etc/systemd/system/ocluster-worker.service
    permissions: '0644'
    content: |
      [Unit]
      Description=OCluster worker
      After=network-online.target docker.service
      Wants=network-online.target
      Requires=docker.service
      RequiresMountsFor=/var/cache/obuilder

      [Service]
      # %H = hostname; each overlay sets its own /etc/hostname, so the worker
      # name follows the VM without rebuilding the base image.
      ExecStart=/usr/local/bin/ocluster-worker -c /etc/ocluster/pool.cap --name=%H --obuilder-store=btrfs:/var/cache/obuilder --fast-sync --allow-push ocurrentbuilder/staging,ocurrent/opam-staging --prune-threshold=30 --obuilder-prune-threshold=30 --capacity=1 --state-dir=/var/cache/obuilder/ocluster -v
      Restart=always
      RestartSec=60

      [Install]
      WantedBy=multi-user.target

runcmd:
  # Format the (throwaway) build-time data disks so docker can install; per-worker
  # overlays get their own labelled disks from new-worker.sh, mounted by fstab.
  # docker (/var/lib/docker) and containerd (/var/lib/containerd) share ONE disk:
  # the disk mounts at /var/lib/docker and is bind-mounted onto /var/lib/containerd.
  # They use disjoint top-level names (docker: image/ overlay2/ volumes/ ...;
  # containerd: io.containerd.*), so co-locating them is safe, and it puts
  # containerd's data on the filesystem ocluster's docker prune monitors.
  # discard (+ discard=unmap drives in run.sh, + fstrim.timer) lets the qcow2
  # shrink when prune frees space, instead of ratcheting to high-water.
  - mkfs.ext4 -F -L docker /dev/vdb
  - mkfs.btrfs -f -L obuilder /dev/vdc
  - mkdir -p /var/lib/docker /var/lib/containerd /var/cache/obuilder
  - echo 'LABEL=docker /var/lib/docker ext4 defaults,discard 0 2' >> /etc/fstab
  - echo '/var/lib/docker /var/lib/containerd none bind 0 0' >> /etc/fstab
  - echo 'LABEL=obuilder /var/cache/obuilder btrfs defaults,discard=async 0 2' >> /etc/fstab
  - mount -a
  - systemctl enable fstrim.timer
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get -y purge exim4-daemon-light snapd apport mlocate || true
  - DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install docker.io docker-buildx docker-compose-v2 pass gnupg2 libev4 git libsqlite3-0 ca-certificates netbase prometheus-node-exporter
  - rm -f /.dockerenv
  - systemctl enable --now docker
  - docker pull ocurrent/ocluster-worker:live
  - docker run --rm --entrypoint /bin/cat ocurrent/ocluster-worker:live /usr/local/bin/ocluster-worker > /usr/local/bin/ocluster-worker
  - chmod a+x /usr/local/bin/ocluster-worker
  - /usr/local/bin/ocluster-worker --help >/dev/null
  - systemctl daemon-reload
  - systemctl enable ocluster-worker.service
  - poweroff
