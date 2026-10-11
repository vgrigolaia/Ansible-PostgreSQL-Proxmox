# Runbook

Operations for a running cluster. Deployment is in [DEPLOYMENT.md](../DEPLOYMENT.md).
Every block says where it runs. `<env>` is `dev` or `prod`, and `pgNN` is a node.

| | dev | prod |
|---|---|---|
| Nodes | pgdb01-dev..03 (10.50.200.231–233) | pgdb01-prod..03 (10.50.200.235–237) |
| VIP | 10.50.200.234 | 10.50.200.238 |
| Patroni scope | pgc-dev | pgc-prod |

Shortcut used below, on any node:
```bash
alias pctl='sudo patronictl -c /etc/patroni/patroni.yml'
```

---

## 0. Credentials and endpoints

All logins, passwords and connection commands for an environment, from the vault. Contacts no host. Also saved to `~/.ansible/vault/pgc-<env>-credentials.txt` (0600). Run on: **workstation**
```bash
make credentials ENV=prod
```

## 1. Health check

Full read-only check. Run on: **workstation**
```bash
ansible-playbook $INV $VAULT playbooks/validate.yml
```
It checks SELinux, the services, PostgreSQL settings, pg_hba/firewall isolation, pgbouncer, HAProxy backends, metrics endpoints, etcd, Patroni topology and lag, and logins through the VIP. It ends with `All checks passed` or lists the failed checks by name.

Quick look. Run on: **any node**
```bash
pctl list                                        # 1 Leader, the others "streaming", lag 0
sudo /usr/local/bin/etcdctl-pgc endpoint health --cluster -w table
ip -br addr | grep -E '172\.16\.67\.23[48]'      # which node holds the VIP
```

## 2. Planned switchover (maintenance on the leader)

Run on: **any node**
```bash
pctl switchover --leader <current-leader> --candidate <replica>   # asks for confirmation
pctl list
```
Clients on :5000 are disconnected (HAProxy cuts sessions to the old primary) and reconnect to the new one within a few seconds. Applications must retry on connection loss.

## 3. Unplanned failover: what happens and what to do

Patroni promotes the most up-to-date replica when the leader key in etcd expires (`ttl` 30 s). HAProxy follows Patroni's `/primary` check, so `VIP:5000` points to the new primary without any manual step.

Afterwards. Run on: **any node**
```bash
pctl list
pctl history
```
**Synchronous mode (prod).** Only the replica shown as `Sync Standby` may take over automatically, so no committed transaction is lost. If the leader fails while no replica holds that role (for example within one Patroni cycle, about 10 s, of a switchover, or while the sync standby is itself down), there is no automatic failover and the cluster stays read-only. Check that the remaining replicas are up to date (`pctl list`, lag 0) and promote one by hand. Run on: **any node**
```bash
pctl failover <scope> --candidate <replica>       # asks for confirmation
```

When the failed node comes back, Patroni rewinds it (`pg_rewind`) and it rejoins as a replica. If it can't (State `start failed` or `stopped`), rebuild it, see section 5.

## 4. Restart PostgreSQL or a node

Restart one member's PostgreSQL, through Patroni. Run on: **any node**
```bash
pctl restart <scope> <member>          # e.g. pctl restart pgc-dev pgdb02-dev
```
Never use `systemctl restart postgresql-18`: that unit is masked on purpose. Patroni owns PostgreSQL.

Reboot a node. Run on: **the node**
```bash
pctl list                              # if this node is the Leader, switch over first (section 2)
sudo systemctl reboot
```
All services start at boot. Patroni rejoins the node as a replica.

The softdog watchdog reboots a leader whose Patroni stops responding, so a hung leader can't keep accepting writes after another node has been promoted.

## 5. Rebuild a broken replica

Run on: **any node**
```bash
pctl reinit <scope> <member>           # wipes the member's data directory and re-clones it from the leader
```
The clone puts WAL on `/pgwal` (`basebackup: waldir` in `patroni.yml`). Check afterwards. Run on: **the rebuilt node**
```bash
sudo readlink /var/lib/pgsql/18/data/pg_wal     # expect /pgwal/18/pg_wal
```

## 6. Change PostgreSQL parameters

Cluster-wide parameters live in etcd (the `bootstrap.dcs` section in the role is used only at the first bootstrap).

Run on: **any node**
```bash
pctl edit-config                       # opens an editor; Patroni applies the change on all members
pctl list                              # "Pending restart" means the parameter needs a restart
pctl restart <scope>                   # restarts the members one after another (asks for confirmation)
```
Keep `roles/patroni/defaults/main.yml` in step with what you change here, so a rebuilt cluster gets the same settings.

## 7. Application users and databases

pgbouncer needs no change: it looks users up in PostgreSQL (`auth_query`). Superusers can't log in through pgbouncer.

Run on: **the leader** (`pctl list`)
```bash
sudo -u postgres psql -h /run/postgresql <<'SQL'
CREATE ROLE app_user LOGIN PASSWORD '...';
CREATE DATABASE app_db OWNER app_user;
SQL
```
Clients connect to `VIP:5000` (read/write) or `VIP:5001` (read-only), from a source in `admin_cidrs` or `app_cidrs` (`inventories/<env>/group_vars/all/network.yml`, then re-run `--tags baseline,pgbouncer`).

## 8. pgbouncer

Run on: **any node**
```bash
sudo -u postgres psql -h /run/pgbouncer -p 6432 -U postgres pgbouncer -c "SHOW POOLS;"
sudo -u postgres psql -h /run/pgbouncer -p 6432 -U postgres pgbouncer -c "SHOW CLIENTS;"
sudo systemctl reload pgbouncer        # after editing config; listen_addr/port changes need a restart
```

## 9. VIP and HAProxy

Run on: **any node**
```bash
ip -br addr | grep -E '172\.16\.67\.23[48]'
echo "show stat" | sudo socat stdio /var/lib/haproxy/stats | cut -d, -f1,2,18 | grep -vE 'FRONTEND|BACKEND'
```
Stats page from an admin workstation: `http://<node-ip>:8404/stats`.
The VIP moves when HAProxy stops answering on the holder. It does not move back by itself (`nopreempt`). To move it on purpose, stop keepalived on the holder for a moment:

Run on: **the VIP holder**
```bash
sudo systemctl restart keepalived
```

## 10. etcd

Run on: **any node**
```bash
sudo /usr/local/bin/etcdctl-pgc endpoint health --cluster -w table
sudo /usr/local/bin/etcdctl-pgc endpoint status --cluster -w table
sudo /usr/local/bin/etcdctl-pgc member list -w table
```
The cluster needs 2 of 3 members. With only one member left, Patroni can't hold the leader key and the primary goes read-only on purpose (it demotes itself). Bring a second member back first.

## 11. Certificates

Each environment has its own CA (`inventories/<env>/pki/etcd-ca.crt`, key vault-encrypted; both git-ignored, keep a backup). Node certificates for etcd and the Patroni etcd client are valid for 5 years. To renew, delete the node's `.crt` and re-run the role (`--tags etcd` or `--tags patroni`); keys stay on the node. Check expiry:

Run on: **any node**
```bash
sudo openssl x509 -noout -enddate -in /etc/etcd/tls/node.crt
sudo openssl x509 -noout -enddate -in /etc/patroni/tls/client.crt
```

## 12. Logs

| What | Where (on the node) |
|---|---|
| PostgreSQL + pgaudit | `/pg_audit_logs/postgresql-<Day>.log` (rotated weekly by name) |
| Patroni | `journalctl -u patroni` |
| etcd | `journalctl -u etcd` |
| pgbouncer | `/var/log/pgbouncer/pgbouncer.log` |
| HAProxy, keepalived, exporters | `journalctl -u haproxy` / `-u keepalived` / `-u <name>_exporter` |
| SELinux denials | `sudo ausearch -m avc -ts today` |

## 13. Disruptive validation

Run on: **workstation**, only when interruptions are acceptable
```bash
ansible-playbook $INV $VAULT playbooks/validate.yml --tags disruptive
```
It does a switchover, stops Patroni on the new leader (another node must take over, then it rejoins), and stops HAProxy on the VIP holder (the VIP must move). Each step checks that `VIP:5000` still reaches a primary and restores the cluster. The leader may end up on another node.

## 14. Proxmox HA and Proxmox node maintenance

Each DB VM is an HA resource (`vm:<id>`, requested state `started`) with a non-strict node-affinity rule `pgc-<vm>-home` to its own node. Patroni still does the database failover; Proxmox HA only (re)starts VMs. Background, requirements and failure scenarios: [proxmox-ha.md](proxmox-ha.md).

Show HA state. Run on: **any Proxmox node**
```bash
ha-manager status                 # each vm:<id> should be "started" on its home node
ha-manager rules config
```

**A Proxmox node fails.** Patroni promotes a replica within seconds (section 3). After fencing (about 2 minutes) HA restarts the failed node's VM on another node, and Patroni rejoins it as a replica. Two VMs of the same environment now share one node, so a second failure of that node would cost etcd its quorum: repair the failed node first. When it is back online, HA moves the VM home again (failback). `validate.yml` fails `ha_on_home_node` until then.

**Planned maintenance on a Proxmox node** (updates, reboot). Do one node at a time. Run the Patroni part on **any DB VM** and the HA part on **any Proxmox node**:
```bash
pctl list                                             # DB VM: if the VM on this node is Leader, switch over first (section 2)
ha-manager crm-command node-maintenance enable pve02  # Proxmox: HA live-migrates the node's HA VMs to other nodes
ha-manager status                                     # Proxmox: wait until no pgc VM runs on pve02
#   ... maintenance, reboot ...
ha-manager crm-command node-maintenance disable pve02 # Proxmox: the VMs migrate back to pve02
```
Maintenance mode survives a reboot of the node; it stays on until you disable it. Without maintenance mode, a node *reboot* freezes its HA VMs, which come back up on the same node after the reboot (default shutdown policy `conditional`).

**Stop a DB VM on purpose.** HA keeps VMs running: a VM shut down from inside the guest is started again. Ask HA instead. Run on: **any Proxmox node**
```bash
ha-manager set vm:232 --state stopped      # stop and keep stopped
ha-manager set vm:232 --state started      # start again
```
Re-running `provision.yml --tags vms` also sets every VM back to `started`.

## 15. Not covered yet

- Backups / point-in-time recovery (planned: pgBackRest).
- Alert rules for Prometheus.
- TLS for client connections.
