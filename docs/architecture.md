# Architecture

## Environments
| Host | Dev | Prod |
|---|---|---|
| pg01 (pve01) | pgdb01-dev 10.50.200.231 (VM 231) | pgdb01-prod 10.50.200.235 (VM 235) |
| pg02 (pve02) | pgdb02-dev 10.50.200.232 (VM 232) | pgdb02-prod 10.50.200.236 (VM 236) |
| pg03 (pve03) | pgdb03-dev 10.50.200.233 (VM 233) | pgdb03-prod 10.50.200.237 (VM 237) |
| VIP | 10.50.200.234 (VRID 231) | 10.50.200.238 (VRID 235) |

Each environment is a fully separate cluster with its own etcd, Patroni scope, vault, etcd CA and keepalived VRID. VMs are cloned from template 9000 (`tpl-alma10`) onto Ceph RBD storage `RBD-Disk`, bridge `vmbr0`, Proxmox pool `postgresql-pool`. There is no PVE HA on DB VMs: Patroni handles failover.

| | dev | prod |
|---|---|---|
| Replication | asynchronous | synchronous (one Sync Standby, non-strict) |
| Patroni watchdog (softdog) | `automatic` | `required` |
| keepalived priority pg01/pg02/pg03 | 100 / 90 / 80 | 100 / 90 / 80 |

## Per-node stack
| Component | Port | Notes |
|---|---|---|
| PostgreSQL 18 | 5432 | Managed by Patroni |
| Patroni REST | 8008 | `/primary`, `/replica`, `/metrics` |
| etcd | 2379 / 2380 / 2381 | client+peer TLS; plain-HTTP metrics on 2381 |
| pgbouncer | 6432 | auth_query via `pgbouncer_auth` |
| HAProxy | 5000 / 5001 / 8404 | 5000 → primary, 5001 → replicas (via pgbouncer); 8404 stats + `/metrics` |
| keepalived | VRRP | unicast to env peers only |
| node_exporter | 9100 | |
| postgres_exporter | 9187 | |
| pgbouncer_exporter | 9127 | |

Client path: `VIP:5000|5001 → HAProxy → pgbouncer:6432 (selected node) → PostgreSQL:5432`.

## High availability
- **Leader election.** Patroni holds a leader key in etcd (TTL 30 s, loop 10 s). When the leader fails, the key expires and the healthiest replica is promoted; returning nodes are rewound with `pg_rewind` and rejoin as replicas.
- **Synchronous mode (prod).** Only the replica shown as `Sync Standby` may be promoted automatically, so a failover loses no committed transaction. If the leader fails while no Sync Standby is named (for example within one cycle of a switchover, or while that replica is down), Patroni does not fail over by itself; an operator promotes a replica with `patronictl failover` (runbook §3). Non-strict: if no replica is up, the primary keeps accepting writes.
- **Fencing.** The softdog watchdog reboots a leader whose Patroni stops responding, so a hung primary can't keep accepting writes.
- **Routing.** HAProxy checks Patroni `GET /primary` and `GET /replica?lag=16MB` on every node every 3 s and cuts sessions to a node that loses its role.
- **VIP.** keepalived (unicast VRRP, all nodes BACKUP with `nopreempt`) releases the VIP on a node whose HAProxy stops answering `/health`; the VIP does not move back by itself.
- **Quorum.** etcd needs 2 of 3 members. With one member left, the primary demotes itself (read-only) on purpose.

## Storage layout
All disks are SCSI on one VirtIO SCSI single controller, each with its own I/O thread and `discard=on`. The OS disk (scsi0) has a `/boot` partition plus VG `almalinux`.

| LV | Mount | Size (dev and prod) |
|---|---|---|
| root | `/` | 16G |
| var | `/var` | 8G |
| home | `/home` | 2G |
| swap | swap | 4G |

Template 9000 (`tpl-alma10`) is installed offline from the AlmaLinux 10.2 DVD ISO with a kickstart (attached as a second CD labelled OEMDRV), because cloud images have no LVM. It ships small LVs, and the OS baseline grows them to the per-env sizes.

Each VM also has three dedicated PostgreSQL disks (SCSI on `RBD-Disk`). Each PostgreSQL disk carries one VG with a single LV formatted as xfs.

| Disk | VG / LV | Mount | Contents | Size (dev and prod) |
|---|---|---|---|---|
| scsi1 (sdb) | vg_pgdata / lv_pgdata | `/var/lib/pgsql` | PGDATA `/var/lib/pgsql/18/data` | 20G |
| scsi2 (sdc) | vg_pgwal / lv_pgwal | `/pgwal` | WAL `/pgwal/18/pg_wal` (initdb and pg_basebackup `--waldir`) | 10G |
| scsi3 (sdd) | vg_pgaudit / lv_pgaudit | `/pg_audit_logs` | PostgreSQL server log incl. pgaudit entries (`log_directory`) | 10G |

Disks are identified in the guest by their Proxmox `serial` (`/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_pgdata` etc.), never by device order.


## Isolation (dev ↔ prod)
Both environments share one subnet, so isolation is enforced on each host:
- firewalld default-DROP zone, so cluster ports are reachable only from the env's own node IPs;
- explicit reject rules (ingress and egress) for the other env's node IPs and VIP;
- `reject` lines in pg_hba and pgbouncer hba for the other env;
- etcd TLS with a per-env CA.

The deny lists come from `playbooks/group_vars/all/environments.yml`.
