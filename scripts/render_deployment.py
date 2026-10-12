#!/usr/bin/env python3
"""Render DEPLOYMENT-<env>.md for every environment from docs/templates/DEPLOYMENT.md.j2.

Values come from the same files the playbooks use (environment registry, inventories, role defaults),
so a guide always shows the environment's real addresses. Run from the repository root: `make docs`.
With --check, nothing is written and the exit code is 1 if a guide is out of date (used by CI).
"""
import argparse
import sys
from pathlib import Path

import jinja2
import yaml

ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs/templates/DEPLOYMENT.md.j2"


def load(path):
    with open(ROOT / path) as f:
        return yaml.safe_load(f) or {}


def env_values(env, registry, reserved, prometheus_ip):
    inv = f"inventories/{env}"
    main = load(f"{inv}/group_vars/all/main.yml")
    network = load(f"{inv}/group_vars/all/network.yml")
    proxmox = load(f"{inv}/group_vars/all/proxmox.yml")
    patroni_defaults = load("roles/patroni/defaults/main.yml")
    entry = registry[env]
    nodes = []
    for name, ip in entry["nodes"].items():
        host = load(f"{inv}/host_vars/{name}.yml")
        nodes.append({"name": name, "ip": ip, "vm_id": host["vm_id"], "pve_node": host["vm_pve_node"],
                      "priority": host.get("keepalived_priority")})
    others = [e for e in registry if e != env]
    return {
        "env": env,
        "others": others,
        "branch": env,
        "nodes": nodes,
        "vip": entry["vip"],
        "vrid": entry["keepalived_vrid"],
        "vm_ids": entry["vm_ids"],
        "scope": f"pgc-{env}",
        "registry": registry,
        "reserved_ips": reserved,
        "prometheus_ip": prometheus_ip,
        "sync_mode": main.get("patroni_synchronous_mode", patroni_defaults.get("patroni_synchronous_mode")),
        "watchdog": main.get("patroni_watchdog_mode", patroni_defaults.get("patroni_watchdog_mode")),
        "main": main,
        "net": network,
        "pve": proxmox,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if a rendered guide differs from the file on disk")
    args = parser.parse_args()

    group_vars = load("playbooks/group_vars/all/environments.yml")
    registry = group_vars["pgc_environments"]
    jenv = jinja2.Environment(
        loader=jinja2.FileSystemLoader(str(TEMPLATE.parent)),
        variable_start_string="[[", variable_end_string="]]",
        block_start_string="[%", block_end_string="%]",
        comment_start_string="[#", comment_end_string="#]",
        keep_trailing_newline=True, trim_blocks=True, lstrip_blocks=True, undefined=jinja2.StrictUndefined,
    )
    template = jenv.get_template(TEMPLATE.name)

    stale = []
    for env in registry:
        values = env_values(env, registry, group_vars.get("pgc_reserved_ips") or [], group_vars["prometheus_server_ip"])
        out = ROOT / f"DEPLOYMENT-{env}.md"
        text = template.render(**values)
        if args.check:
            if not out.exists() or out.read_text() != text:
                stale.append(out.name)
        else:
            out.write_text(text)
            print(f"wrote {out.name}")
    if stale:
        print(f"out of date: {', '.join(stale)}. Run `make docs` and commit the result.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
