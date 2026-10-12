# Runs on: workstation
ENV ?= dev
VENV := .venv
BIN := $(VENV)/bin
INV := inventories/$(ENV)
VAULT_ID := $(ENV)@$(HOME)/.ansible/vault/pgc-$(ENV)

.PHONY: deps lint vault-check vault-edit inventory syntax credentials docs docs-check

deps:
	python3 -m venv $(VENV)
	$(BIN)/pip install -q -r requirements.txt
	$(BIN)/ansible-galaxy collection install -r requirements.yml -p ./collections

lint: vault-check
	$(BIN)/yamllint .
	$(BIN)/ansible-lint

# Fails if any vault.yml or CA private key (tracked or not) is not encrypted.
vault-check:
	@for f in $$(find inventories -name vault.yml -o -path '*/pki/*.key'); do \
		head -c 14 $$f | grep -q '^$$ANSIBLE_VAULT' || { echo "NOT ENCRYPTED: $$f"; exit 1; }; done; \
	echo "vault files encrypted"

vault-edit:
	@echo ">> host: workstation, env: $(ENV)"
	@if [ -f $(INV)/group_vars/all/vault.yml ]; then \
		$(BIN)/ansible-vault edit --vault-id $(VAULT_ID) $(INV)/group_vars/all/vault.yml; \
	else \
		$(BIN)/ansible-vault create --vault-id $(VAULT_ID) $(INV)/group_vars/all/vault.yml; fi

inventory:
	@echo ">> host: workstation, env: $(ENV)"
	$(BIN)/ansible-inventory -i $(INV) --playbook-dir playbooks --vault-id $(VAULT_ID) --graph   # no --vars: it would print decrypted secrets

syntax:
	@echo ">> host: workstation, env: $(ENV)"
	for p in playbooks/provision.yml playbooks/site.yml playbooks/validate.yml; do \
		$(BIN)/ansible-playbook -i $(INV) --syntax-check $$p || exit 1; done

# Connection sheet with ALL credentials: written to ~/.ansible/vault/pgc-$(ENV)-credentials.txt (0600) and printed.
credentials:
	@echo ">> host: workstation, env: $(ENV). Output contains passwords."
	@$(BIN)/ansible-playbook -i $(INV) --vault-id $(VAULT_ID) playbooks/credentials.yml >/dev/null
	@cat $(HOME)/.ansible/vault/pgc-$(ENV)-credentials.txt

# Deployment guides DEPLOYMENT-<env>.md, generated from docs/templates/DEPLOYMENT.md.j2 and the configuration.
docs:
	$(BIN)/python scripts/render_deployment.py

docs-check:
	$(BIN)/python scripts/render_deployment.py --check
