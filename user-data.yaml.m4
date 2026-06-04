#cloud-config
# OCluster linux-riscv64 worker, baked in a single cloud-init pass. Mirrors the
# ansible docker + worker roles (clarke/power-monitoring excluded). __NAME__ and
# __CAP__ are substituted by m4 from the Makefile.
hostname: __NAME__
fqdn: __NAME__
preserve_hostname: false

users:
  - name: opam
    groups: [sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA09mqKPpMJ4tyOpl4l+KTTl1DqjFT2mRD29HW8VwnmB root@alpha

write_files:
  # linux-riscv64 pool capability (substituted from POOL_CAP at build time).
  - path: /etc/ocluster/pool.cap
    permissions: '0400'
    content: |
      __CAP__
  # docker role: enable experimental features.
  - path: /etc/docker/daemon.json
    permissions: '0644'
    content: |
      {
        "experimental": true
      }
  # worker role: keep obuilder/docker mounts out of node-exporter filesystem stats.
  - path: /etc/default/prometheus-node-exporter
    permissions: '0644'
    content: |
      ARGS="--collector.filesystem.ignored-mount-points=^/(sys|proc|dev|run|var/cache/obuilder/.+|var/lib/docker/.+)($|/)"
  # worker role: avoid scheduler connection timeouts.
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
      ExecStart=/usr/local/bin/ocluster-worker -c /etc/ocluster/pool.cap --name=__NAME__ --obuilder-store=btrfs:/var/cache/obuilder --fast-sync --allow-push ocurrentbuilder/staging,ocurrent/opam-staging --prune-threshold=30 --obuilder-prune-threshold=30 --capacity=1 --state-dir=/var/cache/obuilder/ocluster -v
      Restart=always
      RestartSec=60

      [Install]
      WantedBy=multi-user.target

runcmd:
  # --- extra disks: vdb -> docker data-root (ext4), vdc -> obuilder store (btrfs) ---
  - mkfs.ext4 -F -L docker /dev/vdb
  - mkfs.btrfs -f -L obuilder /dev/vdc
  - mkdir -p /var/lib/docker /var/cache/obuilder
  - echo 'LABEL=docker /var/lib/docker ext4 defaults 0 2' >> /etc/fstab
  - echo 'LABEL=obuilder /var/cache/obuilder btrfs defaults 0 2' >> /etc/fstab
  - mount -a
  - mkdir -p /var/cache/obuilder/ocluster
  # --- packages: docker + worker role deps (clarke excluded) ---
  - apt-get update
  - DEBIAN_FRONTEND=noninteractive apt-get -y purge exim4-daemon-light snapd apport mlocate || true
  - DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends install docker.io docker-buildx docker-compose-v2 pass gnupg2 libev4 git libsqlite3-0 ca-certificates netbase prometheus-node-exporter
  - rm -f /.dockerenv
  - systemctl enable --now docker
  # --- ocluster-worker binary, extracted from the published image ---
  - docker pull ocurrent/ocluster-worker:live
  - docker run --rm --entrypoint /bin/cat ocurrent/ocluster-worker:live /usr/local/bin/ocluster-worker > /usr/local/bin/ocluster-worker
  - chmod a+x /usr/local/bin/ocluster-worker
  - /usr/local/bin/ocluster-worker --help >/dev/null
  # --- enable (but do NOT start) the worker, then power off to bake the image ---
  - systemctl daemon-reload
  - systemctl enable ocluster-worker.service
  - poweroff
