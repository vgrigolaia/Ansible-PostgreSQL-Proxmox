#!/usr/bin/env bash
# Runs on: workstation, in the repository root (make vault-init ENV=<env>).
# Creates an environment's vault password file and its encrypted vault, with every password generated.
# Asks only for the Proxmox API token id and secret (the secret is not shown). Never overwrites anything,
# and no plaintext secret is written outside a 0600 temp file under ~/.ansible/vault (0700).
set -euo pipefail

env="${1:?usage: scripts/vault-init.sh <env>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
vault_dir="$HOME/.ansible/vault"
pwfile="$vault_dir/pgc-$env"
vault="$root/inventories/$env/group_vars/all/vault.yml"

[ -d "$root/inventories/$env" ] || { echo "No inventory inventories/$env." >&2; exit 1; }
if [ -e "$vault" ]; then
  echo "$vault already exists. Change it with: make vault-edit ENV=$env" >&2
  exit 1
fi

read -rp "Proxmox API token id for $env (<user>@<realm>!<token>, e.g. ansible@pve!ansible-auth): " token_id
[[ "$token_id" =~ ^[^@[:space:]]+@[A-Za-z][A-Za-z0-9._-]*![A-Za-z][A-Za-z0-9._-]*$ ]] \
  || { echo "Not a token id of the form <user>@<realm>!<token>." >&2; exit 1; }
read -rsp "Proxmox API token secret (not shown): " token_secret; echo
[ -n "$token_secret" ] || { echo "Empty token secret." >&2; exit 1; }

mkdir -p "$vault_dir" && chmod 700 "$vault_dir"
if [ -e "$pwfile" ]; then
  echo "Using the existing vault password file $pwfile."
else
  (umask 077; openssl rand -base64 32 > "$pwfile")
  echo "Created the vault password file $pwfile."
fi

# Letters and digits only: some passwords end up in pgbouncer's userlist and in connection URLs.
gen() { openssl rand -base64 96 | tr -dc 'A-Za-z0-9' | cut -c1-"$1"; }

tmp="$(mktemp "$vault_dir/new-vault.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<VAULT
vault_pve_api_token_id: "$token_id"
vault_pve_api_token_secret: "$token_secret"
vault_vm_ci_password: "$(gen 24)"
vault_postgres_superuser_password: "$(gen 32)"
vault_replication_password: "$(gen 32)"
vault_rewind_password: "$(gen 32)"
vault_patroni_restapi_password: "$(gen 32)"
vault_pgbouncer_auth_password: "$(gen 32)"
vault_monitoring_password: "$(gen 32)"
vault_keepalived_auth_pass: "$(gen 8)"
VAULT
"$root/.venv/bin/ansible-vault" encrypt --vault-id "$env@$pwfile" "$tmp" >/dev/null
mv "$tmp" "$vault"
trap - EXIT

echo "Created $vault (encrypted)."
echo "Back up both files, e.g. in your password manager: without them you can't manage the $env cluster."
