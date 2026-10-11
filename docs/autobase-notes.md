# autobase as a reference

[autobase](https://github.com/autobase-tech/autobase) (formerly vitabaks/postgresql_cluster) was used as a design reference: release 2.11.0, `automation/roles/common/defaults/main.yml`, read 2026-10-07. No code is vendored.

## Adopted patterns
- Topology: etcd + Patroni + pgbouncer + HAProxy + keepalived VIP.
- HAProxy 5000 → primary, 5001 → replicas, with health checks against Patroni `/primary` and `/replica` on 8008.
- pgbouncer `auth_user` + `auth_query` instead of a static userlist.
- etcd TLS enabled by default.
- `postgresql_version` + `postgresql_version_minor: latest` variables.
- One role per component.

## Deviations
| autobase | this project | Reason |
|---|---|---|
| No Proxmox provisioning in these roles | `proxmox_template` / `proxmox_vm` roles (community.proxmox) | VMs are cloned from one AlmaLinux 10 template per Proxmox cluster |
| iptables firewall, disabled at boot by default | firewalld, enforced, explicit dev↔prod deny | Environments share one subnet |
| Expects SELinux permissive/disabled | SELinux enforcing with port and file-context labels | Security posture on EL10 |
| etcd 3.6.13 from GitHub tarball | etcd 3.7.2 from PGDG extras RPM | Single trusted repo, RPM lifecycle |
| netdata, no Prometheus exporters | node/postgres/pgbouncer exporters + scrape config | Existing central Prometheus |
| Single data directory | Separate disks/VGs for data, WAL and audit logs | Data, WAL and logs can't fill each other's disk |
| Large generic vars file | Small roles; per-env vars and vault | Readability and env isolation |
| keepalived VIP optional | Always on, distinct VRID and auth per env | Requirement |
