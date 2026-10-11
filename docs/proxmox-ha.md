# Proxmox HA for the DB VMs

How this project uses Proxmox VE High Availability, what it needs, how to set it up and check it, and how it behaves when something fails. Day-to-day commands are in [runbook §14](runbook.md#14-proxmox-ha-and-proxmox-node-maintenance).

## 1. Two layers, two jobs

| Layer | Protects against | Reaction time | What it does |
|---|---|---|---|
| **Patroni** (inside the VMs) | Primary PostgreSQL or its VM fails | Seconds | Promotes a replica; HAProxy and the VIP send clients to the new primary |
| **Proxmox HA** (on the Proxmox nodes) | A VM crashes, or a Proxmox node fails | About 2 minutes (fencing first) | Starts the VM again: on its own node if that node is fine, otherwise on another node |

Patroni keeps the database writable; Proxmox HA brings the lost VM back so the cluster has three members (etcd quorum, a replica for the next failover) without anyone stepping in. Proxmox HA never decides which node is the PostgreSQL primary.

## 2. What the playbook creates

With `pve_ha_enabled: true` (default), `provision.yml --tags vms` creates, per DB VM:

| Object | Name | Settings |
|---|---|---|
| HA resource | `vm:<vm_id>` | requested state `started`, `max_restart` 1, `max_relocate` 1, failback on (Proxmox default) |
| HA rule | `pgc-<vm name>-home` | type `node-affinity`, node = the VM's `vm_pve_node`, **non-strict** |

For the reference setup:

| VM | Home node | HA rule |
|---|---|---|
| pgdb01-dev (231) / pgdb01-prod (235) | pve01 | pgc-pgdb01-dev-home / pgc-pgdb01-prod-home |
| pgdb02-dev (232) / pgdb02-prod (236) | pve02 | pgc-pgdb02-dev-home / pgc-pgdb02-prod-home |
| pgdb03-dev (233) / pgdb03-prod (237) | pve03 | pgc-pgdb03-dev-home / pgc-pgdb03-prod-home |

**Why non-strict node affinity and not "keep apart" (anti-affinity)?** A negative resource-affinity rule is always strict in Proxmox VE: if a node fails, its VM would not be restarted anywhere, because the other two nodes already run a VM of the same rule. Non-strict node affinity lets HA restart the VM on a surviving node and move it back when its home node returns. The price: while a node is down, two DB VMs of one environment share a Proxmox node (section 6).

## 3. Requirements

| Requirement | Why | Check (where) |
|---|---|---|
| Proxmox VE **9.0 or newer** | HA rules exist since 9.0 (HA groups are deprecated). The playbook stops otherwise | `pveversion` (Proxmox node) |
| At least 3 nodes, cluster quorate | HA only acts with quorum | `pvecm status` (Proxmox node): `Quorate: Yes` |
| **All VM disks on shared storage** | A VM can only start on another node if every disk is reachable there | `qm config <vmid>` (Proxmox node): every disk, including the cloud-init drive, on `RBD-Disk`; no local ISO attached |
| Inventory node names = Proxmox node names | `vm_pve_node` and `pve_template_node` go straight into the API and into the HA rules | `pvecm nodes` (Proxmox node): use the names in the `Name` column, exactly (case-sensitive) |
| Fencing | A failed node must be reset before its VMs start elsewhere | Nothing to do: Proxmox uses the `softdog` watchdog by default. A hardware watchdog is optional |
| API token privileges | Create/read HA resources and rules | `Sys.Console` + `Sys.Audit` on `/`, see [DEPLOYMENT.md §4](../DEPLOYMENT.md#4-proxmox-preparation) |

The template built by this project meets the storage requirement: the install ISOs are detached and the cloud-init drive is created on `pve_storage`.

## 4. Setup

1. **Node names.** Run `pvecm nodes` on any Proxmox node and use those names for the hosts in `pve_nodes` (`inventories/<env>/hosts.yml`), `pve_template_node` and `vm_pve_node` (`inventories/<env>/host_vars/*.yml`). If your nodes are called e.g. `DC-A-PVE-11`, the inventory must say `DC-A-PVE-11`, not `pve01`.
2. **Privileges.** [DEPLOYMENT.md §4.2](../DEPLOYMENT.md#4-proxmox-preparation), the "Proxmox HA" lines. Use the user that owns your token.
3. **Variables** in `inventories/<env>/group_vars/all/proxmox.yml`:
   ```yaml
   pve_ha_enabled: true        # false: VMs are started directly, no HA objects are created
   pve_ha_max_restart: 1       # restart attempts on the same node after a failed start
   pve_ha_max_relocate: 1      # then attempts on another node
   ```
4. **Provision.** Run on: **workstation**
   ```bash
   ansible-playbook $INV $VAULT playbooks/provision.yml --tags vms --check --diff   # plan, incl. "ha: resource vm:<id> ..." per VM
   ansible-playbook $INV $VAULT playbooks/provision.yml --tags vms
   ```
   In `--check` the task "HA resource" shows `skipped`: that Ansible module has no check mode. The plan line shows what it will do. Re-running is safe: existing resources and rules are updated in place, nothing is deleted.

Existing VMs (provisioned before HA was enabled) are put under HA by the same command; they keep running.

## 5. Verify

Run on: **any Proxmox node**
```bash
ha-manager status            # expect: "service vm:231 (pve01, started)" and so on for each VM
ha-manager rules config      # expect: one pgc-<vm>-home node-affinity rule per VM
```

Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/validate.yml
```
The play "Validate Proxmox HA" checks per VM: `ha_managed`, `ha_started`, `ha_on_home_node`, `ha_rule_home_node`. `ha_on_home_node` fails while a VM runs away from its home node (its node is down or in maintenance, or failback hasn't finished).

## 6. What happens when ...

| Event | Patroni | Proxmox HA | Your action |
|---|---|---|---|
| A DB VM crashes or is killed | Fails over if it was the primary | Restarts the VM on its own node | None; check `pctl list` |
| A Proxmox node fails | Fails over within seconds if needed | Fences the node, then (about 2 min) starts its VM on another node; it rejoins as a replica | Repair the node. When it is back, HA moves the VM home (failback) |
| A Proxmox node loses the cluster network only | Like a node failure | The isolated node resets itself (watchdog), its VM starts elsewhere | Fix the network |
| Planned maintenance / reboot of a Proxmox node | Switch over first if the leader is there | Maintenance mode live-migrates the VM away and back | [Runbook §14](runbook.md#14-proxmox-ha-and-proxmox-node-maintenance) |
| Shutdown from inside a VM | | Starts it again (requested state is `started`) | Use `ha-manager set vm:<id> --state stopped` to keep a VM off |
| Two Proxmox nodes fail | etcd loses quorum, cluster read-only | The last node has no Proxmox quorum and resets itself, so all VMs of both environments go down | Restore a second node; everything starts again |

Trade-offs to know:
- **While one node is down,** two VMs of each environment share a node. If that node also fails, etcd loses quorum. Repair the failed node first.
- **Two node failures** cost the remaining DB VM too: a node without Proxmox quorum that runs HA resources resets itself. Without Proxmox HA the last VM would stay up, but read-only, because etcd has no quorum either. So the database is unavailable in both cases.

## 7. Turning HA off

`pve_ha_enabled: false` only stops the playbook from creating HA objects; it never deletes anything. To take the VMs out of HA, run on: **any Proxmox node**, per VM
```bash
ha-manager remove vm:231     # also deletes rule pgc-pgdb01-dev-home (it only references this VM); the VM keeps running
```

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Assert Proxmox VE 9 or newer for HA rules` fails | Cluster on PVE 8 | Upgrade, or `pve_ha_enabled: false` |
| `403 Permission check failed (/, Sys.Console)` or `(/, Sys.Audit)` | HA privileges missing on the user or, for a privsep token, on the token | [DEPLOYMENT.md §4.2](../DEPLOYMENT.md#4-proxmox-preparation); check with `pveum user token permissions <user> <token> --path /` |
| `ACL update failed: user '...' does not exist` | Section 4 commands run with the example user `ansible@pve` | Set `PVE_USER` to the user that owns your token |
| Clone or HA rule fails with an unknown node | Inventory node names differ from `pvecm nodes` | Section 4, step 1 |
| `ha-manager status` shows a VM in `error` | Start failed on all allowed nodes | Find the cause in the task log on the node (`journalctl -u pve-ha-lrm`), then `ha-manager set vm:<id> --state disabled` and `--state started` |
| A rule is shown as disabled / in conflict | A manually added rule contradicts the pgc rules | `ha-manager rules config`; remove or fix the manual rule |
| A VM moves back and forth | Home node keeps failing | Fix the node, or put it in maintenance mode until fixed |
