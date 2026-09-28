# Hotspot clean-install contract

The public `bootstrap-hotspot.sh` entry point resolves the signed `hotspot-stable` channel, verifies the archive SHA-256 and Minisign signature, installs the host update agent, starts the Compose stack, waits for `/health`, and only then moves the `current` pointer. A failed gate must leave the pointer unchanged.

## Host prerequisites and automated steps

- Supported automatic package installation: apt-based Ubuntu/Debian with working signed package repositories and systemd. The script installs missing `ca-certificates`, `curl`, `python3`, `coreutils`, `minisign`, `util-linux`, `gawk`, `openssl`, `tar`, Docker Engine and Compose v2. Ubuntu 26.04 publishes Compose as `docker-compose-v2`; the script also accepts `docker-compose-plugin` from other supported apt repositories. Docker daemon access is checked before starting Hotspot.
- Operator-supplied input for a new installation: `--server-ip IPv4` and a reachable signed update channel. The installer copies the bundled `.env.example`, generates durable credentials, and leaves optional FQDN/SMS integration unconfigured for Admin UI setup. A managed `--config FILE` remains optional. The customer never selects `sda`, `sdb`, or a storage layout. Storage is selected automatically in this order: an already mounted data filesystem at `--data-root`; exactly one completely blank, unpartitioned data disk of at least 500 GB, formatted as ext4 and mounted persistently at `--data-root`; or a root filesystem with at least 900 GB total and 700 GB free. The separate data filesystem requires at least 500 GB total and 100 GB free. More than one blank candidate, any unmounted disk with existing filesystem/signatures, a missing expected mount, or a nonempty mount directory fail closed. The advanced `--single-disk` flag bypasses automatic formatting and applies the root capacity gate directly.
- The signed Hotspot source archive must pin pullable image digests. A clean-host install may not depend on old Docker cache. A published release must test fresh image pulls, Compose build/start, migration, Object Lock/retention read-back, health, and rollback on a disposable host.

## Current gap to a one-click customer install

The update server serves a signed bootstrap script and release channel; it does not currently provide a browser button that SSH-provisions a remote host. External backup storage is not configurable from the Hotspot UI yet, and the present “full backup” excludes ClickHouse and MinIO WORM evidence. Before production approval, add a UI-configured independent backup target, verify PostgreSQL/ClickHouse/5651 object copy and an empty-host restore, then run a signed installation from the published channel. A one-disk installation still needs independent backup acceptance.

For isolated acceptance, publish to a separately signed `hotspot-candidate` channel and invoke bootstrap with both `--channel hotspot-candidate` and its matching `--channel-url`. Keep `hotspot-stable` unchanged until the acceptance gates pass.

Never place credentials in the command line, release archive, logs, or this document. Managed installs may use a root-readable customer config file; IP-only installs use the installer secret-generation path.
