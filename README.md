# BOSH-1754: DevStack PoC

**Ziel:** Testen, ob DevStack für OpenStack CPI CI geeignet ist.

## Status

- [x] Phase 1 Setup
- [ ] Smoke Test gelaufen
- [ ] CPI Lifecycle Test gelaufen
- [ ] Ergebnisse dokumentiert

## Quick Start

### Auf GitHub pushen:

```bash
# GitHub Repo erstellen (auf github.com)
# z.B. https://github.com/<USERNAME>/bosh-openstack-devstack-poc

# Remote hinzufügen
git remote add origin git@github.com:<USERNAME>/bosh-openstack-devstack-poc.git

# Pushen
git add .
git commit -m "Initial DevStack PoC setup"
git push -u origin main
```

### Workflow manuell starten:

1. Gehe zu: `https://github.com/<USERNAME>/bosh-openstack-devstack-poc/actions`
2. Wähle "DevStack Smoke Test"
3. Klicke "Run workflow"
4. Warte ~20-30 Minuten

## Ergebnisse dokumentieren

Siehe: `docs/results.md`

## Links

- [DevStack Action](https://github.com/gophercloud/devstack-action)
- [PoC Plan](../landscape-bosh-lod-01/BOSH-1754-POC-PLAN.md)
- [Phase 1 Details](../landscape-bosh-lod-01/docs/phase1-devstack-poc.md)
