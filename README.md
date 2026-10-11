# ansible-postgres-proxmox

Ansible project that builds highly available PostgreSQL clusters on Proxmox VE: from an empty Proxmox cluster to a validated 3-node Patroni cluster behind a virtual IP, with monitoring, in one repository.

```
AlmaLinux 10 · PostgreSQL 18 · Patroni · etcd · pgbouncer · HAProxy · keepalived · Prometheus exporters
```

- **To deploy:** follow [DEPLOYMENT.md](DEPLOYMENT.md) from top to bottom.
- **To operate a running cluster:** [docs/runbook.md](docs/runbook.md) (switchover, failover, rebuilds, users, logs).
- **Proxmox HA for the VMs:** [docs/proxmox-ha.md](docs/proxmox-ha.md) (requirements, setup, failure behaviour).

---

## Contents
1. [Purpose](#1-purpose)
2. [Architecture](#2-architecture)
3. [Components and versions](#3-components-and-versions)
4. [Security model](#4-security-model)
5. [Prerequisites (summary)](#5-prerequisites-summary)
6. [Repository layout](#6-repository-layout)
7. [Environments](#7-environments)
8. [Configuration standards](#8-configuration-standards)
9. [Documentation index](#9-documentation-index)

---

## 1. Purpose

Per environment, the project produces a self-contained PostgreSQL service with:

- **Automatic failover.** Patroni promotes a replica when the primary fails. Clients keep using the same address.
- **Proxmox HA.** Each VM is HA-managed and prefers its own Proxmox node. If a node dies, its VM is restarted on another node and moves back when the node returns. See [docs/proxmox-ha.md](docs/proxmox-ha.md).
- **One stable endpoint.** A virtual IP, with port 5000 for read/write and 5001 for read-only.
- **Connection pooling.** pgbouncer runs in transaction mode on every node.
- **Repeatable builds.** Everything from the VM template to the monitoring exporters is code: idempotent, reviewable with `--check --diff`, and verified by a validation playbook.
- **Hard separation between environments**, even on a shared subnet: firewall, `pg_hba`, pgbouncer hba, and a separate etcd certificate authority per environment.

Two environments are defined, `dev` and `prod`. They are fully separate clusters, each with its own VMs, etcd, Patroni scope, VIP, VRRP ID, secrets and CA.

---

## 2. Architecture

### Per environment
Three VMs, one on each of three Proxmox nodes. Every VM runs the full stack, so any two VMs are enough to keep the service up.

```
                         clients (app_cidrs / admin_cidrs)
                                       │
                     VIP :5000 (read/write)   VIP :5001 (read-only)
                                       │   keepalived moves the VIP to a node with a healthy HAProxy
             ┌─────────────────────────┼─────────────────────────┐
             ▼                         ▼                         ▼
   ┌──────────────────┐      ┌──────────────────┐      ┌──────────────────┐
   │ pgdb01           │      │ pgdb02           │      │ pgdb03           │
   │ HAProxy 5000/5001│─────►│ HAProxy          │      │ HAProxy          │
   │   │  (routes to the node Patroni reports as primary / replica)      │
   │   ▼              │      │                  │      │                  │
   │ pgbouncer 6432   │      │ pgbouncer 6432   │      │ pgbouncer 6432   │
   │   ▼              │      │   ▼              │      │   ▼              │
   │ PostgreSQL 5432  │─WAL─►│ PostgreSQL       │      │ PostgreSQL       │
   │  (primary)       │─────────────────────────────────►(replica)        │
   │ Patroni 8008     │      │ Patroni 8008     │      │ Patroni 8008     │
   │ etcd 2379/2380   │◄────►│ etcd             │◄────►│ etcd             │
   │ keepalived       │      │ keepalived       │      │ keepalived       │
   │ exporters        │      │ exporters        │      │ exporters        │
   └──────────────────┘      └──────────────────┘      └──────────────────┘
```

**Request path:** `VIP:5000` → HAProxy (on the VIP holder) → pgbouncer:6432 on the node whose Patroni `GET /primary` returns 200 → PostgreSQL:5432 on that node. `VIP:5001` works the same way, round-robin over the nodes that pass `GET /replica?lag=16MB`.

**Failover:**
1. Patroni keeps a leader key in etcd, with a 30 s TTL. If the primary fails, the key expires and the healthiest replica is promoted.
2. HAProxy's health checks follow the new primary within seconds, and sessions to the old primary are cut.
3. The softdog watchdog reboots a leader whose Patroni has hung, so a frozen primary can't keep taking writes.

**VIP:** keepalived uses unicast VRRP between the three node IPs. A node whose HAProxy stops answering its `/health` URI gives up the VIP. `nopreempt` keeps the VIP where it is until its node fails.

### Ports

| Port | Component | Reachable from |
|---|---|---|
| 5000 / 5001 | HAProxy → primary / replicas | admin_cidrs, app_cidrs, own env nodes |
| 6432 | pgbouncer | admin_cidrs, app_cidrs, own env nodes |
| 5432 | PostgreSQL (replication, pg_rewind) | own env nodes |
| 8008 | Patroni REST (health checks, `/metrics`) | own env nodes, Prometheus |
| 2379 / 2380 | etcd client / peer (TLS) | own env nodes |
| 2381 | etcd `/metrics` (HTTP) | Prometheus |
| 8404 | HAProxy stats `/stats`, `/metrics`, `/health` | admin_cidrs, Prometheus |
| 9100 / 9187 / 9127 | node / postgres / pgbouncer exporters | Prometheus |
| 22 | SSH | admin_cidrs |
| VRRP (IP proto 112) | keepalived | own env nodes |

Everything else is dropped. The other environment's node IPs and VIP are rejected before any other rule.

### Disk layout (every DB VM)

All disks are SCSI on one VirtIO SCSI single controller (`scsihw: virtio-scsi-single`), each with its own I/O thread and `discard=on`.

| Disk (guest device) | VG / LV | Mount | Holds |
|---|---|---|---|
| scsi0 (sda) | `almalinux` / root, var, home, swap | `/`, `/var`, `/home`, swap | OS (`/boot` is a plain partition) |
| scsi1 (sdb) | `vg_pgdata` / `lv_pgdata` | `/var/lib/pgsql` | PGDATA `/var/lib/pgsql/18/data` |
| scsi2 (sdc) | `vg_pgwal` / `lv_pgwal` | `/pgwal` | WAL `/pgwal/18/pg_wal` (symlinked from PGDATA) |
| scsi3 (sdd) | `vg_pgaudit` / `lv_pgaudit` | `/pg_audit_logs` | PostgreSQL server log incl. pgaudit |

The PostgreSQL disks are found in the guest by their Proxmox serial (`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_pgdata` etc.), never by device order. Replicas are cloned with `pg_basebackup --waldir`, so WAL sits on the WAL disk on every node.

---

## 3. Components and versions

Versions are pinned in `playbooks/group_vars/all/versions.yml` and in each exporter role. They were last checked against upstream on 2026-10-07; re-check them before a deployment.

| Component | Version | Source |
|---|---|---|
| AlmaLinux | 10.2 (x86-64-v3) | DVD ISO, sha256-pinned, installed by kickstart |
| PostgreSQL | 18 (minor: latest, pinnable) | PGDG `pgdg18` |
| pgaudit | `pgaudit_18` | PGDG |
| Patroni | 4.1.5 (+ `patroni-etcd`) | PGDG common (needs `python3-click` from EPEL 10, restricted to that one package) |
| etcd | 3.7.2 | PGDG extras (restricted to `etcd*`) |
| pgbouncer | 1.26.0 | PGDG common |
| HAProxy | 3.0.5 | AlmaLinux 10 AppStream |
| keepalived | 2.2.8 | AlmaLinux 10 AppStream |
| node_exporter | 1.12.1 | GitHub release, sha256-pinned |
| postgres_exporter | 0.20.1 | GitHub release, sha256-pinned |
| pgbouncer_exporter | 0.12.1 | GitHub release, sha256-pinned |

**Automation:**
- **Tooling:** ansible-core 2.20, Python 3.12+, and the collections `community.proxmox` 2.x, `community.general` 13.x, `community.postgresql` 5.x, `community.crypto` 3.x and `ansible.posix` 2.x. `make deps` installs all of them into the repo (`.venv`, `./collections`).
- **Proxmox:** VE 9.x. The VM template is built over SSH with `qm`. The VMs are created through the Proxmox API with a token.

---

## 4. Security model

- **SELinux enforcing** everywhere. Ports and file contexts are labelled; HAProxy uses the `haproxy_connect_any` boolean and stays confined. Nothing is set to permissive.
- **firewalld:**
  - a default-DROP zone, with explicit sources only;
  - an egress policy that rejects connections to the other environment;
  - SSH reachable only from `admin_cidrs`;
  - a guard that refuses to apply the firewall if it would cut off your own SSH session.
- **Authentication:**
  - PostgreSQL uses SCRAM-SHA-256 only.
  - pgbouncer looks users up through a `SECURITY DEFINER` function that never returns superusers.
  - The `postgres` superuser can only use peer auth on the local socket.
- **etcd:**
  - TLS for clients and peers, with one CA per environment;
  - node keys are generated on the node and never leave it;
  - the CA key is stored vault-encrypted.
- **Secrets:**
  - each environment has its own Ansible Vault file and its own vault password;
  - vault files and CA files are git-ignored: this public repository holds no secrets, not even encrypted ones (`vault.yml.example` lists the keys);
  - no secret is ever shown in a diff or log (`no_log`, `diff: false`).
- **Packages:**
  - every repository is GPG-checked, with signing keys pinned by fingerprint;
  - third-party repos are restricted with `includepkgs`;
  - exporter tarballs are checked against their upstream sha256.
- **VMs:**
  - the cloud-init user is SSH key-only with passwordless sudo, and root login is locked;
  - the console password is in the vault, for emergency access only.

---

## 5. Prerequisites (summary)

The full checklist, with commands to verify each item, is in [DEPLOYMENT.md §1](DEPLOYMENT.md#1-prerequisites).

- **Proxmox:**
  - a VE 9.x cluster with at least 3 nodes, whose CPUs support x86-64-v3 (AVX2);
  - shared VM storage, e.g. Ceph RBD, so clones can be placed on any node;
  - ISO storage reachable from the template node, e.g. CephFS;
  - a Linux bridge onto the DB subnet;
  - an API token, plus root SSH to one node (only for building the template).
- **Network, per environment:**
  - 3 node IPs and 1 VIP in one subnet;
  - a free VRRP router ID;
  - VRRP and gratuitous ARP allowed on the bridge;
  - outbound HTTPS from the VMs to the AlmaLinux, PGDG and Fedora EPEL mirrors.
- **Workstation:**
  - Linux with Python 3.12+, `git`, `make`, `openssl`;
  - a route to the DB subnet;
  - an SSH key pair;
  - outbound HTTPS to GitHub, Ansible Galaxy and PyPI.
- **Optional:** a Prometheus server to scrape the exporters.

---

## 6. Repository layout

```
ansible.cfg                     # no default inventory (every run names its env); roles/collections paths
Makefile                        # deps, lint, vault-check, vault-edit, inventory, syntax, credentials
requirements.txt                # Python packages for the workstation venv
requirements.yml                # Ansible collections (installed into ./collections)
DEPLOYMENT.md                   # step-by-step deployment guide
.github/workflows/lint.yml      # CI: yamllint, ansible-lint, syntax check (never deploys)
inventories/
  <env>/                        # dev, prod
    hosts.yml                   # Proxmox nodes + DB VMs with their IPs
    group_vars/all/main.yml     # env name, VM sizing, OS LVM sizes, PostgreSQL disk sizes
    group_vars/all/network.yml  # prefix, gateway, DNS, bridge, VLAN, admin/app CIDRs, NTP, timezone
    group_vars/all/proxmox.yml  # API host, template, storage, pool, cloud-init user + SSH key
    group_vars/all/vault.yml    # secrets, ansible-vault encrypted, git-ignored (keys: vault.yml.example)
    group_vars/pg_nodes.yml     # SSH user/become for the DB VMs
    host_vars/<vm>.yml          # VM ID, Proxmox node, keepalived priority
    pki/                        # etcd CA: certificate + vault-encrypted key (playbooks/pki.yml), git-ignored
playbooks/
  group_vars/all/environments.yml  # registry of ALL envs: node IPs, VIP, VRID, VM IDs, reserved IPs, Prometheus IP
  group_vars/all/versions.yml      # component versions, AlmaLinux ISO URL + sha256
  preflight.yml                 # config sanity checks; runs first in every playbook, contacts no host
  provision.yml                 # --tags template (Proxmox template) / --tags vms (VMs via API)
  pki.yml                       # per-env etcd CA (workstation only)
  site.yml                      # OS baseline and all cluster components, one tag per component
  validate.yml                  # read-only checks; --tags disruptive for failover tests
  credentials.yml               # connection sheet with all credentials (make credentials), workstation only
roles/
  proxmox_template, proxmox_vm  # VM template (kickstart) and VM clones
  common, storage, pgdg_repo, firewall  # OS baseline
  pki_ca, etcd                  # CA, certificates, etcd
  epel_repo, patroni            # PostgreSQL + Patroni
  pgbouncer, haproxy, keepalived
  exporter_common, node_exporter, postgres_exporter, pgbouncer_exporter, prometheus_targets
docs/
  runbook.md                    # day-2 operations
  architecture.md               # architecture reference (ports, disks, isolation)
  autobase-notes.md             # what was taken from autobase and what differs
  prometheus/<cluster>.yml      # generated Prometheus scrape config per env
```

| Tag in `site.yml` | Roles |
|---|---|
| `baseline` | common, storage, pgdg_repo, firewall |
| `etcd` | etcd |
| `patroni` | epel_repo, patroni |
| `pgbouncer` | pgbouncer |
| `haproxy`, `keepalived` | haproxy, keepalived |
| `monitoring` | node_exporter, postgres_exporter, pgbouncer_exporter, prometheus_targets |

---

## 7. Environments

The reference values in this repository. To adapt them to your own infrastructure, see [DEPLOYMENT.md §3](DEPLOYMENT.md#3-configure-for-your-infrastructure).

| | dev | prod |
|---|---|---|
| node 1 | pgdb01-dev, 10.50.200.242, VM 242 on DC-A-PVE-11 | pgdb01-prod, 10.50.200.246, VM 246 on DC-A-PVE-11 |
| node 2 | pgdb02-dev, 10.50.200.243, VM 243 on DC-A-PVE-12 | pgdb02-prod, 10.50.200.247, VM 247 on DC-A-PVE-12 |
| node 3 | pgdb03-dev, 10.50.200.244, VM 244 on DC-A-PVE-13 | pgdb03-prod, 10.50.200.248, VM 248 on DC-A-PVE-13 |
| VIP / VRRP ID | 10.50.200.245 / 242 | 10.50.200.249 / 246 |
| Patroni scope | `pgc-dev` | `pgc-prod` |
| VM size | 2 vCPU, 4 GB RAM | 2 vCPU, 4 GB RAM |
| OS disk | 32 GB: root 16, var 8, home 2, swap 4 | same as dev |
| PostgreSQL disks | pgdata 20 GB, pgwal 10 GB, pgaudit 10 GB | same as dev (grow before large imports) |
| Replication | asynchronous | synchronous (1 sync replica, non-strict) |
| Patroni watchdog | `automatic` | `required` |

**Shared:**
- Proxmox nodes DC-A-PVE-11–13 at 10.50.200.11–13, API on DC-A-PVE-11;
- network 10.50.200.0/24, gateway 10.50.200.1, DNS 1.1.1.1, bridge `vmbr0`;
- VM storage Ceph RBD `RBD-Disk`, ISO storage CephFS `cephfs`;
- template VM 9000 (`tpl-alma10`) and Proxmox pool `postgresql-pool`;
- admin network 10.119.10.0/24, Prometheus at 10.45.66.120.

**PostgreSQL defaults** (`roles/patroni/defaults/main.yml`):
- `max_connections` 200;
- `shared_buffers` 25 % of VM RAM and `effective_cache_size` 75 %;
- `wal_level` replica, `wal_log_hints` on, replication slots on, `pg_rewind` on;
- `pg_stat_statements` and `pgaudit` (`ddl,role`) loaded;
- logging collector writing to `/pg_audit_logs`, one file per weekday;
- replication per environment: `patroni_synchronous_mode` (dev false, prod true) and `patroni_watchdog_mode` (dev automatic, prod required), set in `inventories/<env>/group_vars/all/main.yml`.

**pgbouncer defaults:** `pool_mode` transaction, `max_client_conn` 1000, `default_pool_size` 20, `max_db_connections` 150, `max_prepared_statements` 200.

---

## 8. Configuration standards

These rules keep the project reproducible. If a change breaks one, fix the change rather than working around the rule.

**Running Ansible**
- Run from the repository root with the venv active, so `./ansible.cfg`, `./roles` and `./collections` are used.
- Name the environment on every run: `-i inventories/<env> --vault-id <env>@~/.ansible/vault/pgc-<env>`. There's no default inventory, on purpose.
- Run every change with `--check --diff` first, read it, then apply. A second apply must report `changed=0`; anything else is a bug.
- Don't edit managed hosts by hand: no `firewall-cmd`, no edits in `/etc/patroni` or `/etc/pgbouncer`, no Proxmox config changes on the DB VMs. Change the role or the inventory instead. PostgreSQL parameters are the one exception: change them with `patronictl edit-config` (runbook §6) and mirror the change in the role defaults.
- Patroni owns PostgreSQL. The `postgresql-18` systemd unit is masked; use `patronictl` for restarts and switchovers.

**Configuration and secrets**
- **Where values live:**
  - IPs, VIPs, VRRP IDs and VM IDs of all environments: `playbooks/group_vars/all/environments.yml`;
  - per-environment values: `inventories/<env>/`;
  - roles hold only generic defaults.
- **The registry and `hosts.yml` must agree.** The preflight refuses to run otherwise.
- **Secrets:**
  - they live only in `inventories/<env>/group_vars/all/vault.yml`, encrypted and git-ignored;
  - each environment has its own vault password, kept outside the repo in `~/.ansible/vault/pgc-<env>`;
  - back up the vault files, the `pki/` folders and the vault passwords yourself (e.g. a password manager);
  - `make vault-check` (part of `make lint`) fails if a vault file or CA key is unencrypted.
- **Versions** are pinned and checked against upstream before an upgrade. Downloads carry a pinned sha256 and repositories a pinned GPG fingerprint.

**Proxmox safety.** The provisioning roles never delete anything. They only touch:
- VM IDs listed for the environment in the registry;
- an existing VM only if its name matches and it carries the `pgc` tag;
- the template VM only if it is the finished `tpl-alma10` template.

Any other conflict stops the play with nothing changed.

**Code**
- One role per component. Role variables are prefixed with the role name.
- `make lint` (yamllint + ansible-lint, `production` profile) must pass, and so must `make syntax ENV=<env>`. CI runs both on every push and pull request.
- Every command block in the docs says which host it runs on: workstation, a Proxmox node, or a DB VM.

**Git workflow**
- No `main` branch. Work happens on `feat/<topic>` branches, which are merged into `dev` after review.
- `dev` is deployed and validated on the dev cluster, then fast-forwarded into `prod` (`git merge --ff-only dev`). Never commit to `prod` directly.
- Commits are small and conventional (`feat:`, `fix:`, `chore:`, `docs:`).
- Both branches carry both inventories, because each environment's isolation rules need the other's IPs.
- On GitHub, `dev` is the default branch and `prod` is protected (no direct pushes; changes arrive only by fast-forward from `dev`).

---

## 9. Documentation index

| Document | For |
|---|---|
| [DEPLOYMENT.md](DEPLOYMENT.md) | Building an environment from scratch, step by step |
| [docs/runbook.md](docs/runbook.md) | Operating a running cluster |
| [docs/architecture.md](docs/architecture.md) | Architecture reference (ports, disks, isolation) |
| [docs/autobase-notes.md](docs/autobase-notes.md) | Design comparison with autobase |
| `docs/prometheus/<cluster>.yml` | Scrape jobs to add to Prometheus |
