# Deployment guide

There is one ready-to-use guide per environment. Every address, VM ID and command in it is already filled in for that environment, so you can copy and paste the commands as they are:

| Environment | Guide | Deployed from branch |
|---|---|---|
| dev | [DEPLOYMENT-dev.md](DEPLOYMENT-dev.md) | `dev` |
| prod | [DEPLOYMENT-prod.md](DEPLOYMENT-prod.md) | `prod` |

Both guides have the same sections, so a reference like "section 4.2" means the same section in either guide.

**Deploying with your own values?** Change the configuration first (section 3 of the guide: the environment registry, `inventories/<env>/` and `host_vars`), then regenerate the guides. Run on: **workstation**, in the repository root
```bash
make docs          # rewrites DEPLOYMENT-dev.md and DEPLOYMENT-prod.md from the configuration
```

The guides are generated from [docs/templates/DEPLOYMENT.md.j2](docs/templates/DEPLOYMENT.md.j2) by `scripts/render_deployment.py`. Edit the template, never the generated files: CI (`make docs-check`) fails if a guide doesn't match the template and the configuration.
