# Deployment guide

This guide builds one environment (3 PostgreSQL VMs, etcd, Patroni, pgbouncer, HAProxy, keepalived VIP, exporters) from an empty Proxmox cluster to a validated cluster. Follow the sections in order. Each step says what it does, where it runs, the exact commands, what you should see, and how to check it.

Architecture and conventions are in [README.md](README.md). Day-2 operations are in [docs/runbook.md](docs/runbook.md).

## Contents
0. [How to read this guide](#0-how-to-read-this-guide)
1. [Prerequisites](#1-prerequisites)
2. [Workstation setup](#2-workstation-setup)
3. [Configure for your infrastructure](#3-configure-for-your-infrastructure)
4. [Proxmox preparation](#4-proxmox-preparation)
5. [Secrets](#5-secrets)
6. [Check the configuration](#6-check-the-configuration)
7. [Deploy](#7-deploy)
8. [Health checks](#8-health-checks)
9. [First use](#9-first-use)
10. [Deploying the second environment](#10-deploying-the-second-environment)
11. [Re-running and updating](#11-re-running-and-updating)
12. [Troubleshooting](#12-troubleshooting)
13. [Removing an environment](#13-removing-an-environment)

---

## 0. How to read this guide

**Where a command runs.** Every command block names its host:
- **workstation**: your machine, in the repository root (`ansible-postgres-proxmox/`), with the venv active;
- **Proxmox node**: a PVE node, as root;
- **DB VM**: one of the environment's PostgreSQL VMs, as the cloud-init user (`ansible`). Use `sudo` where shown.

**Example values.** Examples use environment `dev` and the reference values in this repository: Proxmox nodes `pve01..03`, DB VMs `10.50.200.231–233`, VIP `10.50.200.234`. Replace them with your own values from section 3.

**Check, then apply.** Every step that changes something is run twice:
1. with `--check --diff`, to see what would change;
2. without them, to apply it.

On freshly created VMs the dry run of a component step can only show the package installation; the rest is skipped until the packages exist. That's expected.

**Expected time** for one environment, first run: about 1–1.5 hours. Most of it is the one-time template build (a ~10 GB ISO download plus a 15–30 min unattended install).

---

## 1. Prerequisites

### 1.1 Proxmox

| Requirement | Why | How to verify (Proxmox node) |
|---|---|---|
| Proxmox VE 9.x cluster, at least 3 nodes, all quorate | One DB VM per node | `pveversion`; `pvecm status` |
| CPUs support x86-64-v3 (AVX2) on every node | AlmaLinux 10 requires it; VMs use CPU type `x86-64-v3` | `grep -c avx2 /proc/cpuinfo` (must be > 0) |
| Shared VM storage visible to all nodes (e.g. Ceph RBD) | Clones of the template land on any node | `pvesm status` (storage active on every node) |
| ISO storage on the template node, with content type `iso` and a known filesystem path | The AlmaLinux DVD ISO (~10.1 GB) and a small kickstart ISO are stored there | `pvesm status`; `ls <path>/template/iso` |
| `genisoimage` on the template node | Builds the kickstart ISO | `ls /usr/bin/genisoimage` (ships with qemu-server) |
| A Linux bridge on every node that reaches the DB subnet | VM networking | `ip -br link show <bridge>` |
| Root SSH from the workstation to the template node | The template is built with `qm` over SSH | `ssh root@<template-node> pveversion` (from the workstation) |
| Outbound HTTPS from the template node to `repo.almalinux.org` | ISO download | `curl -sI https://repo.almalinux.org/` |
| Free VM IDs: 1 for the template + 3 per environment | | `pvesh get /cluster/resources --type vm` |

**Proxmox HA** (`pve_ha_enabled: true`, the default). The playbook puts each DB VM under Proxmox HA with a non-strict node-affinity rule to its own node. The two layers do different jobs:
- **Patroni** fails the *database* over to a replica within seconds, as before.
- **Proxmox HA** restarts a crashed VM. If a Proxmox node dies, HA restarts that node's VM on another node after fencing (about 2 minutes), so etcd and Patroni get their third member back. When the node is online again, the VM moves back to it (failback).

While a node is down, two DB VMs of the same environment share one Proxmox node. Losing that node as well would cost etcd its quorum, so bring the failed node back first. HA needs Proxmox VE 9 (HA rules), shared VM storage (Ceph RBD) and the HA privileges in section 4. Set `pve_ha_enabled: false` to manage the VMs without Proxmox HA.

### 1.2 Network

Plan per environment:

| Item | Count | Reference (dev) |
|---|---|---|
| Node IPs, in one subnet | 3 | 10.50.200.231–233 |
| VIP, in the same subnet, unused | 1 | 10.50.200.234 |
| VRRP router ID, unique on that L2 segment (1–255) | 1 | 231 |
| Gateway, DNS servers | | 10.50.200.1; 1.1.1.1 |

Required network flows:

| From | To | Port / protocol | Purpose |
|---|---|---|---|
| Workstation | Proxmox API host | TCP 8006 | VM provisioning (API token) |
| Workstation | Template node | TCP 22 | Template build |
| Workstation | DB VMs | TCP 22 | Ansible (the workstation's source IP must be in `admin_cidrs`, as the VMs see it) |
| Workstation | GitHub, PyPI, Ansible Galaxy | TCP 443 | Tooling and exporter downloads |
| DB VMs | AlmaLinux mirrors, `download.postgresql.org`, `dl.fedoraproject.org` | TCP 443/80 | Packages |
| DB VMs | NTP servers | UDP 123 | Time (AlmaLinux default pool unless you set `ntp_servers`) |
| DB VMs ↔ DB VMs (same env) | each other | VRRP (IP proto 112), gratuitous ARP on the bridge | Moving the VIP |
| Clients | VIP | TCP 5000, 5001 | Database access |
| Prometheus (optional) | DB VMs | TCP 9100, 9187, 9127, 8008, 8404, 2381 | Metrics |

If the bridge is VLAN-tagged, set `net_vlan_tag` (section 3.6). If your switches or Proxmox firewall filter VRRP or gratuitous ARP, the VIP won't move between nodes.

### 1.3 Workstation

- Linux with Python 3.12 or newer, the `venv` module, `git`, `make`, `openssl`, `curl`.
  - Fedora / RHEL: `sudo dnf install -y python3 git make openssl curl`
  - Debian / Ubuntu: `sudo apt install -y python3 python3-venv git make openssl curl`
- A route to the DB subnet (direct, VPN or similar). Check it. Run on: **workstation**
  ```bash
  ip route get 10.50.200.231          # must not leave through your internet default route
  ```
- An SSH key pair. Its public key goes into the VMs (section 3.7), and its private key must be usable without a prompt, from `ssh-agent` or `~/.ssh/id_ed25519`.

### 1.4 Prometheus (optional)

The project does not install Prometheus. It writes a scrape configuration for an existing server (section 7.10), and only that server's IP may reach the metrics ports.

---

## 2. Workstation setup

Run on: **workstation**
```bash
git clone git@github.com:vgrigolaia/Ansible-PostgreSQL-Proxmox.git ansible-postgres-proxmox
cd ansible-postgres-proxmox          # every later command runs from here
git checkout dev                     # deploy from the branch that matches the environment (README §8)

make deps                            # creates .venv, installs Python packages and Ansible collections into ./collections
source .venv/bin/activate            # repeat in every new shell
ansible --version                    # expect: ansible-core 2.20.x, config file = <repo>/ansible.cfg
make lint                            # expect: vault files encrypted ... Passed ... profile 'production'
```

Always run Ansible from the repository root, so that `./ansible.cfg`, `./roles` and `./collections` are used.

---

## 3. Configure for your infrastructure

Everything site-specific is in the files below. The roles contain no site values.

### 3.1 Decide your values first

Fill this in before editing files:

| Value | Your value | Goes into |
|---|---|---|
| Proxmox node names (exactly as `pvecm nodes` shows them) and their IPs | | `hosts.yml`, `host_vars`, `proxmox.yml` |
| Proxmox API host | | `proxmox.yml` |
| Template VM ID, template node | | `proxmox.yml` |
| VM storage ID (exact case), ISO storage ID and its path | | `proxmox.yml` |
| Proxmox pool name | | `proxmox.yml`, section 4 |
| Bridge, VLAN tag (if any) | | `network.yml` |
| Per env: 3 VM names, 3 VM IDs, 3 IPs, VIP, VRRP ID | | `environments.yml`, `hosts.yml`, `host_vars` |
| Subnet prefix, gateway, DNS, search domain | | `network.yml` |
| Admin CIDRs (must contain the workstation) and app CIDRs | | `network.yml` |
| Prometheus server IP | | `environments.yml` |
| VM sizing: vCPU, RAM, OS disk + LV sizes, pgdata/pgwal/pgaudit sizes | | `main.yml` |
| SSH public key file | | `proxmox.yml` |

### 3.2 Environment registry: `playbooks/group_vars/all/environments.yml`

This registry is the single source of truth for addresses of **all** environments. Each environment's firewall and hba rules reject every other environment's IPs from here, so keep all environments in it, even ones not deployed yet.

```yaml
pgc_environments:
  dev:
    nodes:                                   # VM name: IP. Names must equal the inventory host names.
      pgdb01-dev: 10.50.200.231
      pgdb02-dev: 10.50.200.232
      pgdb03-dev: 10.50.200.233
    vip: 10.50.200.234
    keepalived_vrid: 231                     # unique per env on the L2 segment
    vm_ids: [231, 232, 233]                  # the only VM IDs provisioning may touch for this env
  prod:
    ...
pgc_reserved_ips: []                     # IPs that must never be assigned
prometheus_server_ip: 10.45.66.120                     # only this IP may scrape metrics
```

The environment keys (`dev`, `prod`) must equal `pgc_env` in each inventory's `main.yml`.

### 3.3 Hosts: `inventories/<env>/hosts.yml`

- `pve_nodes`: your Proxmox node names with their IPs, used for SSH to the template node.
- `pg_nodes`: the three VM names with `ansible_host` IPs, identical to the registry.

The group name `pgc_<env>` is free text.

### 3.4 Per VM: `inventories/<env>/host_vars/<vm-name>.yml`

```yaml
vm_id: 231                 # must be in the registry's vm_ids for this env
vm_pve_node: pve01     # Proxmox node that hosts this VM; the three VMs must be on three different nodes
keepalived_priority: 100   # 100 / 90 / 80: highest gets the VIP first
```

### 3.5 Sizing: `inventories/<env>/group_vars/all/main.yml`

| Variable | Reference (dev) | Rules |
|---|---|---|
| `pgc_env` | `dev` | Key in the registry |
| `vm_cores`, `vm_memory_mb` | 2, 4096 | RAM also sets `shared_buffers` (25 %) and `effective_cache_size` (75 %) |
| `vm_os_disk_gb` | 32 | At least 20 (template disk). Must hold 1 GB `/boot` plus the sum of `vm_os_lvm`. |
| `vm_os_lvm` | root 16, var 8, home 2, swap 4 | Sizes in GB. LVs are only grown, never shrunk. |
| `vm_pg_disks[].size_gb` | pgdata 20, pgwal 10, pgaudit 10 | Keep the names, slots, VG/LV names and mounts as they are |
| `patroni_synchronous_mode` | false (prod: true) | true: a commit waits for one replica, so no committed transaction is lost on failover. Non-strict: writes continue if no replica is up. Takes effect at the first bootstrap only; later use `patronictl edit-config`. |
| `patroni_watchdog_mode` | automatic (prod: required) | required: a node whose watchdog doesn't work never becomes leader |

Provisioning refuses to run while any of these is empty.

### 3.6 Network: `inventories/<env>/group_vars/all/network.yml`

| Variable | Reference (dev) | Notes |
|---|---|---|
| `net_prefix` | 24 | |
| `net_gateway` | 10.50.200.1 | |
| `net_dns_servers` | [1.1.1.1] | |
| `net_search_domain` | empty | optional |
| `net_bridge` | vmbr0 | |
| `net_vlan_tag` | empty | empty = untagged |
| `admin_cidrs` | [10.119.10.0/24] | SSH, 5000, 5001, 6432, 8404. **Must contain the workstation's IP as the VMs see it**, or the firewall step stops (lockout guard). |
| `app_cidrs` | [] | 5000, 5001, 6432 for application servers |
| `ntp_servers` | [] | empty = AlmaLinux default pool |
| `os_timezone` | UTC | |

### 3.7 Proxmox: `inventories/<env>/group_vars/all/proxmox.yml`

| Variable | Reference | Notes |
|---|---|---|
| `pve_api_host` | 10.50.200.11 | Any node's API address |
| `pve_api_validate_certs` | false | Set true if the API has a trusted certificate |
| `pve_template_vmid` | 9000 | Shared by all envs; built once |
| `vm_scsihw` / `vm_os_disk_slot` | virtio-scsi-single / scsi0 | Disk controller and OS disk slot, for the template and the VMs. PostgreSQL disk slots are `vm_pg_disks[].slot` (scsi1–3) in `main.yml` |
| `pve_template_node` | pve01 | Must be a host in `pve_nodes` |
| `pve_storage` | RBD-Disk | Exact storage ID, case-sensitive |
| `pve_iso_storage` / `pve_iso_dir` | cephfs / `/mnt/pve/cephfs/template/iso` | Storage ID and its filesystem path on the template node |
| `vm_cpu_type` | x86-64-v3 | Keep |
| `pve_pool` | postgresql-pool | Must exist (section 4) |
| `vm_ci_user` | ansible | Login user on the VMs; Ansible connects as this user |
| `pve_ha_enabled` | true | Put the VMs under Proxmox HA (section 1.1). Needs PVE 9 and the HA privileges (section 4) |
| `pve_ha_max_restart` / `pve_ha_max_relocate` | 1 / 1 | HA start retries on the same node, then on another node |
| `vm_ci_ssh_pubkey_file` | `~/.ssh/id_ed25519.pub` | Public key installed for `vm_ci_user`. For several keys, set `vm_ci_ssh_keys` to a list instead. |

If your private key is not the SSH default and not in an agent, add `ansible_ssh_private_key_file: ~/.ssh/<key>` to `inventories/<env>/group_vars/pg_nodes.yml`.

### 3.8 Versions: `playbooks/group_vars/all/versions.yml` (optional)

You only need to change this to move to newer upstream versions. Keep the AlmaLinux ISO URL and sha256 in step: take the sha256 from the `CHECKSUM` file next to the ISO on the mirror. Exporter versions and their sha256 sums are in each exporter role's `defaults/main.yml`.

### 3.9 What stays as is

`pgc` (PostgreSQL cluster) is a fixed prefix in names that need no adapting:
- the Patroni scope `pgc-<env>`;
- the vault password path `~/.ansible/vault/pgc-<env>`;
- the Proxmox tag `pgc`, used by the safety guards (the template is named `tpl-alma10`);
- the firewalld zone `pgc`, the tuned profile `pgc-postgres` and the `etcdctl-pgc` wrapper.

Renaming them is a code change, not configuration.

---

## 4. Proxmox preparation

Create a dedicated user, the pool and an API token. Run on: **Proxmox node** (any, as root)
```bash
pveum user add ansible@pve --comment "ansible-postgres-proxmox automation"
pveum pool add postgresql-pool --comment "PostgreSQL cluster VMs"
pveum user token add ansible@pve ansible-auth --privsep 0
#   prints the token id (ansible@pve!ansible-auth) and the secret ONCE: store the secret in your password manager now

pveum acl modify /pool/postgresql-pool         --users ansible@pve --roles PVEVMAdmin
pveum acl modify /vms/9000                     --users ansible@pve --roles PVETemplateUser
pveum acl modify /storage/RBD-Disk             --users ansible@pve --roles PVEDatastoreUser
pveum acl modify /sdn/zones/localnetwork/vmbr0 --users ansible@pve --roles PVESDNUser

# Proxmox HA (only with pve_ha_enabled: true). The HA API checks these on / and has no finer scope.
pveum role add PGC-HA --privs "Sys.Audit,Sys.Console"
pveum acl modify / --users ansible@pve --roles PGC-HA --propagate 0
```
Replace `9000`, `RBD-Disk` and `vmbr0` with your values.

`Sys.Console` on `/` is what the Proxmox API requires to create HA resources and rules (`Sys.Audit` to read them); it also allows console access to the nodes, so keep the token secret in the vault only. This permission set is a least-privilege starting point. This exact set hasn't been run end-to-end yet. If provisioning stops with `403 Permission check failed (<path>, <privilege>)`, grant that privilege on that path and re-run; nothing is half-created. Adding VMs to the pool may also need `Pool.Allocate` on `/pool/postgresql-pool`.

Test the token. Run on: **workstation**
```bash
curl -sk -H 'Authorization: PVEAPIToken=ansible@pve!ansible-auth=<SECRET>' \
  https://<pve_api_host>:8006/api2/json/version
```
Expected: JSON containing `"version":"9.`. A `401` means the token id or secret is wrong.

---

## 5. Secrets

Each environment has one encrypted vault file and one vault password file.

| Env | Vault file (encrypted, git-ignored) | Vault password file (outside the repo) |
|---|---|---|
| dev | `inventories/dev/group_vars/all/vault.yml` | `~/.ansible/vault/pgc-dev` |
| prod | `inventories/prod/group_vars/all/vault.yml` | `~/.ansible/vault/pgc-prod` |

**Neither file is ever committed.** The repository is public, so even the encrypted vault and the etcd CA key stay on the workstation (`.gitignore` excludes them). Back up `inventories/<env>/group_vars/all/vault.yml`, `inventories/<env>/pki/` and the vault password file yourself, e.g. in a password manager: without them you can't manage a deployed cluster.

**New environment:** create the password file and the vault. The script below generates every password without printing it. The plaintext only ever sits in a `0600` temporary file under `~/.ansible/vault` (`0700`) and is encrypted before it is moved into the inventory.

Run on: **workstation**
```bash
export ENV=dev
mkdir -p ~/.ansible/vault && chmod 700 ~/.ansible/vault
(umask 077; openssl rand -base64 32 > ~/.ansible/vault/pgc-$ENV)   # store this file in your password manager

gen() { openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
tmp=$(mktemp ~/.ansible/vault/new-vault.XXXXXX)
cat > "$tmp" <<EOF
vault_pve_api_token_id: "ansible@pve!ansible-auth"
vault_pve_api_token_secret: "REPLACE-ME"
vault_vm_ci_password: "$(gen 24)"
vault_postgres_superuser_password: "$(gen 32)"
vault_replication_password: "$(gen 32)"
vault_rewind_password: "$(gen 32)"
vault_patroni_restapi_password: "$(gen 32)"
vault_pgbouncer_auth_password: "$(gen 32)"
vault_monitoring_password: "$(gen 32)"
vault_keepalived_auth_pass: "$(gen 8)"
EOF
ansible-vault encrypt --vault-id $ENV@$HOME/.ansible/vault/pgc-$ENV "$tmp"
mv "$tmp" inventories/$ENV/group_vars/all/vault.yml

make vault-edit ENV=$ENV           # replace REPLACE-ME with the API token secret from section 4, save
make vault-check                   # expect: vault files encrypted
```

| Key | Used by | Rules |
|---|---|---|
| `vault_pve_api_token_id` / `vault_pve_api_token_secret` | VM provisioning | `user@realm!tokenname` |
| `vault_vm_ci_password` | console login of the cloud-init user | SSH stays key-only |
| `vault_postgres_superuser_password`, `vault_replication_password`, `vault_rewind_password` | Patroni / PostgreSQL | **letters and digits only** |
| `vault_patroni_restapi_password` | Patroni REST write endpoints | letters and digits only |
| `vault_pgbouncer_auth_password`, `vault_monitoring_password` | pgbouncer, exporters | letters and digits only (they end up in pgbouncer's user list and a connection URL) |
| `vault_keepalived_auth_pass` | VRRP | **at most 8 characters** |

Use different passwords in every environment. The full key list is in `inventories/<env>/group_vars/all/vault.yml.example`.

Check that a secret decrypts, without printing it. Run on: **workstation**
```bash
ansible -i inventories/$ENV --playbook-dir playbooks --vault-id $ENV@$HOME/.ansible/vault/pgc-$ENV \
  localhost -m debug -a "msg={{ vault_postgres_superuser_password | length }}"     # expect: 32
```

Confirm git ignores it. Run on: **workstation**
```bash
git check-ignore inventories/$ENV/group_vars/all/vault.yml     # prints the path = ignored
```

---

## 6. Check the configuration

Set these once per shell. Every later command uses them. Run on: **workstation**, in the repository root
```bash
source .venv/bin/activate
export ENV=dev
export INV="-i inventories/$ENV"
export VAULT="--vault-id $ENV@$HOME/.ansible/vault/pgc-$ENV"
ssh-add ~/.ssh/id_ed25519            # once per shell if your key has a passphrase
```

Run on: **workstation**. None of these contact any host.
```bash
make lint                                       # Passed, profile 'production'
make syntax ENV=$ENV                            # three "playbook:" lines, no error
make inventory ENV=$ENV                         # pve_nodes and pg_nodes with your host names
ansible-playbook $INV $VAULT playbooks/preflight.yml
```
Preflight expected result: `failed=0` for every DB VM.

It checks that each VM's IP and VM ID match the registry, aren't reserved, and don't belong to another environment, and that the three VMs sit on three different Proxmox nodes with distinct VM IDs. Fix any mismatch it reports in `hosts.yml`, `host_vars` or `environments.yml`.

---

## 7. Deploy

### 7.1 VM template (once per Proxmox cluster)

**What it does.** The steps run as root on the template node over SSH:
1. Download the AlmaLinux DVD ISO (sha256-verified) into the ISO storage. An existing file is reused only if its checksum matches.
2. Build a kickstart ISO labelled `OEMDRV`.
3. Create the template VM and run an unattended offline install. The OS disk gets `/boot` plus LVM, root is locked, SELinux is enforcing, and cloud-init is preconfigured with the `vm_ci_user`.
4. Swap the CDs for a cloud-init drive and convert the VM to a template.

**Safety.** If the template VM already exists as our finished template, nothing happens. If anything else is in the way, the play stops without changing it: the VM ID taken by another VM, an unfinished template, or a leftover kickstart directory or ISO.

**Duration.** The ISO download depends on bandwidth (~10.1 GB), then the install takes 15–30 min. The play waits up to 60 min.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/provision.yml --tags template --check --diff
ansible-playbook $INV $VAULT playbooks/provision.yml --tags template
```
Expected: `failed=0`. Check it. Run on: **Proxmox node** (the template node)
```bash
qm config 9000 | grep -E '^(name|template|tags|scsihw|scsi0|ide2|boot)'
# expect: name tpl-alma10, template: 1, tags include pgc, scsihw virtio-scsi-single,
#         scsi0 on <storage> with iothread=1, ide2 = <storage>:cloudinit, boot order=scsi0
```
Leftovers you may delete by hand once the template exists: `/root/pgc-ks-9000` on the template node and `pgc-ks-9000.iso` in the ISO storage. A later rebuild of the template refuses to run while they exist.

### 7.2 VMs

**What it does.** Through the Proxmox API:
1. Full-clone the template to the environment's three VM IDs, each on its own node.
2. Set CPU, RAM and cloud-init (static IP, gateway, DNS, user, password, SSH keys).
3. Grow the OS disk, add the three PostgreSQL disks with serials `pgdata`, `pgwal`, `pgaudit`, and put the VMs in the pool.
4. With `pve_ha_enabled`: add each VM as an HA resource (requested state `started`) plus a rule `pgc-<vm>-home` that prefers its own node; the HA manager starts the VMs. Without it, start the VMs directly.
5. Wait for SSH.

The dry run prints a plan per VM, including its HA resource and rule, and checks the safety guards, without changing anything. The HA resource task shows as `skipped` in `--check` (the module has no check mode).

Check HA afterwards. Run on: **Proxmox node** (any)
```bash
ha-manager status            # expect: service vm:<id> (<home node>, started) for each VM
ha-manager rules config      # expect: pgc-<vm>-home, node-affinity, one per VM
```

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/provision.yml --tags vms --check --diff
ansible-playbook $INV $VAULT playbooks/provision.yml --tags vms
ansible $INV $VAULT pg_nodes -m ansible.builtin.ping          # expect: 3 x "pong"
```
New VM host keys are accepted on first contact (`StrictHostKeyChecking=accept-new`).

### 7.3 OS baseline

**What it does.**
- **System:** checks it's AlmaLinux 10, installs base packages, sets the timezone and chrony, writes the env's nodes into `/etc/hosts`, and applies a tuned profile (THP off, low swappiness).
- **Storage:** grows the OS LVM to `vm_os_lvm`, and builds PV → VG → LV → xfs on each PostgreSQL disk, mounted with SELinux labels.
- **Packages:** adds the PGDG repository with its signing key pinned.
- **Firewall** (last): a default-DROP zone, other-environment rejects, the egress policy, and the SSH lockout guard.

Optional: add `-e common_os_upgrade=true` to apply all OS updates, rebooting one node at a time if needed.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/site.yml --tags baseline --check --diff
ansible-playbook $INV $VAULT playbooks/site.yml --tags baseline
```
Check it. Run on: **DB VM** (pg01)
```bash
df -hT | grep -E 'pgsql|pgwal|pg_audit'     # three xfs mounts
getenforce                                  # Enforcing
sudo firewall-cmd --get-default-zone        # pgc
```

### 7.4 etcd certificate authority (once per environment)

**What it does.** On the workstation only, it creates the environment's etcd CA:
- the certificate goes to `inventories/<env>/pki/etcd-ca.crt`;
- the private key goes to `etcd-ca.key`, **vault-encrypted**.

An existing CA is never overwritten.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/pki.yml
make vault-check                                                  # the .key must be encrypted
git check-ignore inventories/$ENV/pki/etcd-ca.key                 # git-ignored: back up inventories/$ENV/pki/ yourself
```

### 7.5 etcd

**What it does.**
1. Installs etcd from PGDG extras (RPM signature checked).
2. Generates each node's key on the node; only the signing request goes to the workstation, which signs it with the env CA.
3. Starts a 3-member cluster with client and peer TLS, and metrics on `:2381`.

It also installs `/usr/local/bin/etcdctl-pgc`, an `etcdctl` already set up with the node's certificates.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/site.yml --tags etcd --check --diff
ansible-playbook $INV $VAULT playbooks/site.yml --tags etcd
```
Check it. Run on: **DB VM** (any)
```bash
sudo /usr/local/bin/etcdctl-pgc endpoint health --cluster -w table   # 3 x healthy
```
Use the full path: sudo's `secure_path` doesn't include `/usr/local/bin`.

### 7.6 PostgreSQL and Patroni

**What it does.**
1. Installs PostgreSQL 18, contrib and pgaudit from PGDG, and Patroni from PGDG. EPEL is added, restricted to `python3-click`, with its key pinned.
2. Masks the stock PostgreSQL unit, sets up the softdog watchdog, and issues Patroni's etcd client certificate.
3. Writes `patroni.yml`, after Patroni has validated it on the node.
4. Bootstraps the cluster on pg01: initdb with data checksums, WAL on `/pgwal`, `C.UTF-8`.
5. Starts pg02 and pg03, which clone from pg01 with WAL on `/pgwal`. The play waits for 1 Leader and 2 streaming replicas.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/site.yml --tags patroni --check --diff
ansible-playbook $INV $VAULT playbooks/site.yml --tags patroni
```
Expected: the play ends by printing the cluster table, with 1 `Leader` and 2 `Replica` in state `streaming`, lag 0. Check it. Run on: **DB VM** (any)
```bash
sudo patronictl -c /etc/patroni/patroni.yml list
sudo readlink /var/lib/pgsql/18/data/pg_wal     # /pgwal/18/pg_wal on every node
```
The cluster-wide settings in `bootstrap.dcs` (TTL, PostgreSQL parameters) apply only at this first bootstrap. Change them later with `patronictl edit-config` (runbook §6).

### 7.7 pgbouncer

**What it does.**
1. Installs pgbouncer on every node, listening on the node IP and 127.0.0.1 port 6432, in front of the local PostgreSQL, in transaction mode.
2. Creates, on the current leader only, the `pgbouncer_auth` role and the locked-down `pgbouncer.get_auth()` lookup function. pgbouncer uses them to authenticate any PostgreSQL user, superusers excepted.
3. Writes the access rules: other-environment IPs rejected, and `postgres` limited to the admin console over the local socket.
4. Logs in through pgbouncer to prove it works.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/site.yml --tags pgbouncer --check --diff
ansible-playbook $INV $VAULT playbooks/site.yml --tags pgbouncer
```
Expected: `pgbouncer OK, local PostgreSQL is the primary` on the leader and `... a replica` on the others. Check it. Run on: **DB VM** (any)
```bash
sudo -u postgres psql -h /run/pgbouncer -p 6432 -U postgres pgbouncer -c "SHOW POOLS;"
```

### 7.8 HAProxy and keepalived (VIP)

**What it does.**
- **HAProxy** on every node routes:
  - `:5000` to the primary's pgbouncer;
  - `:5001` round-robin to replicas lagging less than 16 MB;
  - `:8404` to its stats, metrics and health page.

  It's allowed through SELinux with the `haproxy_connect_any` boolean.
- **keepalived** carries the VIP with unicast VRRP. A node whose HAProxy is unhealthy gives up the VIP.
- The play ends with a login through the VIP: `:5000` must reach the primary and `:5001` a replica.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/site.yml --tags haproxy,keepalived --check --diff
ansible-playbook $INV $VAULT playbooks/site.yml --tags haproxy,keepalived
```
Expected: `<VIP> is on <node>` (normally pg01, highest priority) and both VIP logins `ok`. Check it. Run on: **DB VM** (any)
```bash
ip -br addr | grep 10.50.200.234                                  # present on exactly one node
echo "show stat" | sudo socat stdio /var/lib/haproxy/stats | cut -d, -f1,2,18 | grep -vE 'FRONTEND|BACKEND'
# primary: one node UP; replicas: two nodes UP
```

### 7.9 Monitoring exporters

**What it does.**
1. Downloads node_exporter, postgres_exporter and pgbouncer_exporter on the workstation (pinned sha256) and installs them on every node. Each gets its own user and a hardened systemd unit, listening on the node IP.
2. Creates the `monitoring` role (`pg_monitor`) and the `pg_stat_statements` extension on the leader, and adds `monitoring` to pgbouncer's stats users.
3. Writes `docs/prometheus/pgc-<env>.yml`.

Run the `pgbouncer` tag with it, because the pgbouncer user list changes.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/site.yml --tags pgbouncer,monitoring --check --diff
ansible-playbook $INV $VAULT playbooks/site.yml --tags pgbouncer,monitoring
git add docs/prometheus/pgc-$ENV.yml && git commit -m "chore: add $ENV Prometheus scrape config"
```
Check it. Run on: **DB VM** (pg01)
```bash
systemctl is-active node_exporter postgres_exporter pgbouncer_exporter   # 3 x active
curl -s 10.50.200.231:9187/metrics | grep '^pg_up '                     # pg_up 1
curl -s 10.50.200.231:9127/metrics | grep '^pgbouncer_up '              # pgbouncer_up 1
```

### 7.10 Prometheus (optional)

On your Prometheus server, add the jobs from `docs/prometheus/pgc-<env>.yml` under `scrape_configs:` in `prometheus.yml`, then reload Prometheus. The file has 6 jobs (node, postgres, pgbouncer, patroni, haproxy, etcd), 3 targets each, labelled `env`, `cluster` and `node`.

Check reachability. Run on: **the Prometheus server**
```bash
for p in 9100 9187 9127 8008 8404 2381; do echo -n "$p "; curl -s -o /dev/null -w "%{http_code}\n" http://10.50.200.231:$p/metrics; done
# expect 200 for every port
```

### 7.11 Validate

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/validate.yml
```
Expected: the final task `All checks passed` is `ok` on every node. Otherwise it lists the failed checks by name, and the `Report` task shows each check's value per node. See section 8 for what each check means.

**Optional failover test.** This interrupts connections for a few seconds per step:
1. a switchover;
2. Patroni stopped on the new leader, so another node takes over, then it rejoins;
3. HAProxy stopped on the VIP holder, so the VIP moves.

Each step is verified and then restored.

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/validate.yml --tags disruptive
```

The environment is deployed.

---

## 8. Health checks

`playbooks/validate.yml` runs all of these. You can run them by hand where shown.

| Check | Where | Command | Healthy |
|---|---|---|---|
| etcd | DB VM | `sudo /usr/local/bin/etcdctl-pgc endpoint health --cluster -w table` | 3 × healthy |
| Patroni topology | DB VM | `sudo patronictl -c /etc/patroni/patroni.yml list` | 1 Leader, 2 `streaming`, same TL, lag 0 |
| WAL location | DB VM | `sudo readlink /var/lib/pgsql/18/data/pg_wal` | `/pgwal/18/pg_wal` |
| PostgreSQL settings | DB VM | `sudo -u postgres psql -h /run/postgresql -Atc "show data_checksums"` | `on` |
| pgbouncer | DB VM | `sudo -u postgres psql -h /run/pgbouncer -p 6432 -U postgres pgbouncer -c "SHOW POOLS"` | rows, no error |
| HAProxy backends | DB VM | `echo "show stat" \| sudo socat stdio /var/lib/haproxy/stats \| cut -d, -f1,2,18` | primary: 1 UP; replicas: 2 UP |
| VIP | DB VM | `ip -br addr \| grep <VIP>` | on exactly one node |
| Client path | host in `admin_cidrs` | `psql "host=<VIP> port=5000 dbname=postgres user=<user>" -c "select pg_is_in_recovery()"` | `f` (5001 gives `t`) |
| Services | DB VM | `systemctl is-active etcd patroni pgbouncer haproxy keepalived node_exporter postgres_exporter pgbouncer_exporter` | all `active` |
| SELinux | DB VM | `getenforce`; `sudo ausearch -m avc -ts today` | `Enforcing`; no denials for cluster services |
| Isolation | DB VM | `sudo firewall-cmd --policy=pgc-egress --list-rich-rules` | rejects for every other-env IP |

---

## 9. First use

**Connection sheet.** This prints every endpoint, login and password of the environment, with ready-to-use `psql`, SSH-tunnel and pgAdmin settings. It contacts no host. The sheet is also saved to `~/.ansible/vault/pgc-<env>-credentials.txt` (mode `0600`, outside the repository; the playbook refuses a path inside it). It contains passwords, so don't commit, mail or paste it.

Run on: **workstation**
```bash
make credentials ENV=$ENV
```

**Create application users and databases.** pgbouncer needs no change, because it looks users up in PostgreSQL. Run on: **the leader** (see `patronictl list`)
```bash
sudo -u postgres psql -h /run/postgresql <<'SQL'
CREATE ROLE app_user LOGIN PASSWORD 'change-me';
CREATE DATABASE app_db OWNER app_user;
SQL
```

**Allow the application servers.** Add their CIDRs to `app_cidrs` in `inventories/<env>/group_vars/all/network.yml`, then re-apply the firewall and pgbouncer access rules. Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/site.yml --tags baseline,pgbouncer --check --diff
ansible-playbook $INV $VAULT playbooks/site.yml --tags baseline,pgbouncer
```

**Connect.** Use `VIP:5000` for read/write and `VIP:5001` for read-only. Applications must reconnect and retry after a dropped connection: a failover or switchover cuts open sessions.

---

## 10. Deploying the second environment

The steps are the same, with `ENV=prod`. What differs:

1. **Configuration (section 3):** `inventories/prod/` with its own sizes, IPs, VM IDs and VRRP ID, all entered in the registry.
2. **API token:** a separate one (section 4), e.g. `ansible@pve!ansible-auth`, or the same token if your policy allows.
3. **Vault:** its own vault password file and its own generated secrets (section 5). Never copy dev's.
4. **CA:** its own etcd CA (section 7.4).
5. **Template:** skip 7.1. The template is shared and already built.
6. **Git:** deploy from the `prod` branch, after fast-forwarding it to the validated `dev`. Run on: **workstation**
   ```bash
   git checkout prod
   git merge --ff-only dev
   ```

If the second environment was **not** in the registry when the first one was deployed, re-apply the first environment's firewall and access rules, so it rejects the new IPs too. They are taken from the registry. In this repository both environments are in the registry from the start, so this isn't needed. Run on: **workstation**, with `ENV` set to the first environment
```bash
ansible-playbook $INV $VAULT playbooks/site.yml --tags baseline,patroni,pgbouncer --check --diff
ansible-playbook $INV $VAULT playbooks/site.yml --tags baseline,patroni,pgbouncer
```

---

## 11. Re-running and updating

- **The whole configuration is idempotent.** On a deployed environment, this should end with `changed=0`. Run on: **workstation**
  ```bash
  ansible-playbook $INV $VAULT playbooks/site.yml --check --diff
  ansible-playbook $INV $VAULT playbooks/site.yml
  ```
- **OS updates:** add `-e common_os_upgrade=true` to the `baseline` tag. Nodes that need a reboot are rebooted one at a time; switch over first if the leader would reboot (runbook §2).
- **Component upgrades:** change the version in `versions.yml` or the exporter role defaults, with its sha256 where applicable. Deploy to dev, run `validate.yml`, then promote to prod.
- **Always validate after a change:** `ansible-playbook $INV $VAULT playbooks/validate.yml`.

---

## 12. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Attempting to decrypt but no vault secrets found` | `$VAULT` missing | Add `--vault-id <env>@~/.ansible/vault/pgc-<env>` |
| `Decryption failed` | Wrong vault password file for this env | Get the right one from the password manager |
| Preflight: `... does not match pgc_environments.<env>` | `hosts.yml`, `host_vars` and `environments.yml` disagree | Make all three match |
| Proxmox `401` | Token id or secret wrong | `make vault-edit ENV=<env>` |
| Proxmox `403 Permission check failed (<path>, <priv>)` | Missing privilege | Grant it on that path (section 4). On PVE 9, cloning needs `SDN.Use` on the bridge's zone. |
| `Permission denied (publickey)` / `ssh_askpass` errors on the VMs | Key not in the agent, or a `Host *` block in `~/.ssh/config` forces another agent | `ssh-add`. Check `ssh -G ansible@<vm-ip> \| grep identityagent`; add a `Host <vm-ips>` block with `IdentityAgent SSH_AUTH_SOCK` above `Host *` |
| `UNREACHABLE` on the VMs | No route from the workstation, or VMs still booting | `ip route get <vm-ip>`; wait for 7.2 to finish |
| `Host key verification failed` after re-creating a VM | Old key in `known_hosts` | `ssh-keygen -R <vm-ip>` |
| Baseline stops: SSH source would be locked out | The workstation's IP, as the VMs see it, isn't in `admin_cidrs` | Add it to `admin_cidrs`. If NAT is involved, use the NAT address. |
| `etcdctl-pgc: command not found` with sudo | sudo `secure_path` lacks `/usr/local/bin` | Call `/usr/local/bin/etcdctl-pgc` |
| Patroni install: `nothing provides python3-click` | EPEL repo not set up | Re-run `--tags patroni`; the role adds the restricted EPEL repo |
| A replica's `pg_wal` is a plain directory | It was cloned without `--waldir` | On any node: `sudo patronictl -c /etc/patroni/patroni.yml reinit <scope> <member>` (runbook §5) |
| VIP doesn't move / clients can't reach it after a move | VRRP or gratuitous ARP filtered on the bridge or switch | Allow IP protocol 112 between the nodes and GARP on the segment |
| `assert ... Proxmox VE 9 or newer for HA rules` | Cluster on PVE 8 | Upgrade, or set `pve_ha_enabled: false` |
| `403 ... (/, Sys.Console)` or `(/, Sys.Audit)` | HA privileges missing | Section 4, Proxmox HA lines |
| validate: `<vm> ha_on_home_node` failed | The VM runs on another node: its home node is down, in maintenance, or failback is still running | `ha-manager status`; bring the home node back (runbook §14) |
| `ERROR: Ansible requires blocking IO on stdin/stdout/stderr` | Output redirected in some shells | Run in a normal terminal without redirecting stderr |

---

## 13. Removing an environment

The project never deletes anything in Proxmox. Removing an environment is a manual, irreversible operation. Do it only when you mean to destroy its data.

Run on: **Proxmox node**, as root, for each of the environment's VM IDs (dev: 231, 232, 233)
```bash
qm config 231 | grep -E '^(name|tags)'      # confirm it's the right VM before destroying it
ha-manager remove vm:231                    # if HA-managed: also removes rule pgc-<vm>-home (it only references this VM)
qm stop 231
qm destroy 231 --purge                      # deletes the VM and its disks; --purge also drops it from pool and job configs
```
Then, on the **workstation**, remove the VMs' old host keys (`ssh-keygen -R <vm-ip>`). To redeploy, start again at section 7.2. The template and the CA can be reused.
