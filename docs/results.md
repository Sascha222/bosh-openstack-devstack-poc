# DevStack PoC - Results & Learnings

**Projekt:** BOSH OpenStack CPI - DevStack GitHub Actions Integration  
**Ziel:** OpenStack DevStack in GitHub Actions zum Testen des BOSH OpenStack CPI  
**Status:** ✅ Phase 1 & 2 Complete

---

## Experiment 1: DevStack Smoke Test (Phase 1)

### Run 1 - Initial Failure (2026-07-09)
**Status:** ❌ FAILED  
**Fehler:** Python 3.11+ required, Ubuntu 22.04 only has Python 3.10.12

```
ERROR: Package 'openstack-requirements' requires a different Python: 3.10.12 not in '>=3.11'
```

**Fix:** Upgrade auf Ubuntu 24.04

---

### Run 2 - Database Connection Error (2026-07-09)
**Status:** ❌ FAILED  
**Fehler:** Missing database_connection_url_ function

```
/devstack/lib/database: line 135: database_connection_url_: command not found
```

**Root Cause:** Keine Database-Service (mysql/postgresql) in ENABLED_SERVICES  
**Fix:** mysql zu ENABLED_SERVICES hinzugefügt

---

### Run 3 - OVN Compatibility Issues (2026-07-09)
**Status:** ❌ FAILED  
**Fehler:** Legacy Neutron agents inkompatibel mit OVN

```
The q-agt/neutron-agt service must be disabled with OVN.
The q-l3/neutron-l3 service must be disabled with OVN.
```

**Root Cause:** stable/2025.1 nutzt OVN als Standard-Netzwerk-Backend  
**Fix:** Entfernt q-agt, q-l3, q-dhcp, q-meta; nur OVN-Services aktiviert

---

### Run 4 - Missing RabbitMQ (2026-07-09)
**Status:** ❌ FAILED  
**Fehler:** RPC backend does not support vhosts

```
is_service_enabled rabbit
return 1
```

**Root Cause:** Nova benötigt Message Queue (RabbitMQ) für RPC  
**Fix:** rabbit zu ENABLED_SERVICES hinzugefügt

---

### Run 5 - openrc File Not Found (2026-07-09)
**Status:** ❌ FAILED  
**Fehler:** openrc file nicht am erwarteten Ort

```
/opt/stack/devstack/openrc: No such file or directory
```

**Root Cause:** gophercloud/devstack-action legt DevStack an relativem Pfad ab  
**Fix:** Fallback-Logik für openrc-Datei-Suche implementiert

---

### Run 6 - SUCCESS! ✅ (2026-07-10)
**Status:** ✅ SUCCESS  
**Source:** [Run 6](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29082718957)  
**Duration:** 11m 20s  
**Datum:** 2026-07-10

#### Konfiguration (Final Working Setup):
```yaml
OS: ubuntu-24.04
DevStack Action: gophercloud/devstack-action@v0.19
DevStack Branch: stable/2025.1
Enabled Services:
  - mysql (Database)
  - rabbit (RabbitMQ)
  - key (Keystone - Identity)
  - n-api, n-cpu, n-cond, n-sch (Nova - Compute)
  - placement-api (Placement)
  - g-api, g-reg (Glance - Image)
  - c-sch, c-api, c-vol (Cinder - Block Storage)
  - q-svc (Neutron API)
  - ovn-controller, ovn-northd, q-ovn-metadata-agent (OVN Networking)
```

#### System Resources (Measured):
```
CPU: 2 cores (GitHub Actions standard)
RAM: ~16GB (tmpfs shows 7.9G = 50% of physical RAM)
Disk: 110GB available after cleanup (df -h output)
```

#### Verifizierte OpenStack Services:
```
✅ Keystone (Identity)      - http://10.1.0.74/identity
✅ Nova (Compute)            - http://10.1.0.74/compute/v2.1
✅ Glance (Image)            - http://10.1.0.74/image
✅ Cinder (Block Storage)    - http://10.1.0.74/volume/v3
✅ Neutron (Network)         - http://10.1.0.74:9696/networking
✅ Placement                 - http://10.1.0.74/placement
```

#### OpenStack CLI Tests:
```bash
✅ openstack endpoint list     - 7 endpoints gefunden
✅ openstack service list      - 7 services aktiv
✅ openstack network list      - Funktioniert
✅ openstack flavor list       - Funktioniert
✅ openstack image list        - Funktioniert
```

---

## Experiment 2: BOSH CPI Integration (Phase 2)

### Run 1 - Stemcell Download Failed (2026-07-10)
**Status:** ❌ FAILED  
**Fehler:** BOSH Stemcell download fehlgeschlagen

```
Failed to download stemcell from bosh.io
```

**Root Cause:** Stemcells sind sehr groß (~3GB), URLs nicht erreichbar  
**Fix:** Auf Ubuntu Cloud Image gewechselt (~600MB)

---

### Run 2 - VM Creation Failed with Ubuntu Image (2026-07-10)
**Status:** ❌ FAILED  
**Source:** [Run 2 logs](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions) (specific run ID not documented)  
**Fehler:** VM geht in ERROR Status

```
VM Status: BUILD → BUILD → ERROR
```

**Root Cause:** Unknown - VM went to ERROR state with 600MB Ubuntu Cloud Image  
**Observation:** Cirros (~13MB) succeeded, Ubuntu Cloud Image (~600MB) failed  
**Possible causes:** Image size, timeout, resource constraints, or Glance-related issue  
**Fix:** Switched to Cirros test image (~13MB)

---

### Run 3 - SUCCESS! ✅ (2026-07-10)
**Status:** ✅ SUCCESS  
**Source:** [Run 3](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29092040017)  
**Duration:** ~12 minutes  

#### Tests Completed:
```
✅ DevStack Deployment         - 11 min
✅ BOSH CLI Installation       - bosh v7.5.6
✅ OpenStack CLI Installation  - python-openstackclient
✅ Cirros Test Image           - 13MB, uploaded to Glance
✅ BOSH Cloud Config Creation  - DevStack credentials configured
✅ Test VM Creation            - Via OpenStack CLI (CPI simulation)
✅ VM Lifecycle Test           - Create → ACTIVE → Delete
```

#### VM Creation Details:
```
Image:   Cirros 0.6.2 (~13MB)
Flavor:  m1.tiny (512MB RAM, 1GB disk, 1 vCPU)
Network: private (OVN)
Time:    ~30 seconds to ACTIVE
```

---

### Run 4 - Extended CPI Operations Test ✅ (2026-07-13)
**Status:** ✅ SUCCESS  
**Source:** [Run 4](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29254127235)  
**Duration:** ~14 minutes  
**Datum:** 2026-07-13

#### Purpose:
Validate remaining CPI operations that were not tested in Run 3:
- Security Groups (create, add rules)
- Network Configuration (custom networks, subnets)
- Volume Operations (create, attach, detach)

#### Tests Completed:
```
✅ TEST 1: Security Groups
   - Create security group
   - Add SSH rule (port 22)
   - Add ICMP rule (ping)
   - Verify rule configuration

✅ TEST 2: Network Configuration
   - Create custom network
   - Create subnet (192.168.100.0/24)
   - Configure DNS (8.8.8.8)
   - Verify network/subnet details

✅ TEST 3: VM with Network & Security Group
   - Create VM on custom network
   - Apply security group to VM
   - Wait for ACTIVE status (~30s)
   - Verify network attachment

✅ TEST 4: Volume (Disk) Operations
   - 4a: Create 1GB Cinder volume
   - 4b: Attach volume to VM (status: in-use)
   - 4c: Detach volume from VM (status: available)
   - All operations successful
```

#### Test Results Summary:
```
Test 1 - Security Groups:      ✅ SUCCESS
Test 2 - Network Config:       ✅ SUCCESS
Test 3 - VM Creation:          ✅ SUCCESS
Test 4a - Volume Create:       ✅ SUCCESS
Test 4b - Volume Attach:       ✅ SUCCESS
Test 4c - Volume Detach:       ✅ SUCCESS

ALL TESTS PASSED!
```

#### Key Findings:
```
✅ Volume attachment works correctly
   - Attach operation successful
   - Volume status changes: available → in-use
   - Device path assigned: /dev/vdb
   - Detach operation successful
   - Volume status returns: in-use → available

✅ Custom networking works
   - Can create custom networks and subnets
   - VMs can be attached to custom networks
   - OVN networking fully functional

✅ Security groups functional
   - Can create and manage security groups
   - Can add rules (TCP, ICMP)
   - Can apply to VMs
```

---

## Key Learnings

### Phase 1: DevStack Setup

### 1. Ubuntu 24.04 ist erforderlich
- **Warum:** DevStack master/stable/2025.1 benötigt Python >= 3.11
- **Ubuntu 22.04:** Python 3.10.12 ❌
- **Ubuntu 24.04:** Python 3.12 ✅

### 2. OVN ist der neue Standard
- **Legacy Neutron agents (q-agt, q-l3, q-dhcp, q-meta):** Nicht mehr kompatibel
- **OVN Services:** ovn-controller, ovn-northd, q-ovn-metadata-agent
- **Vorteil:** Moderne, performantere Netzwerk-Implementation

### 3. Minimale Service-Anforderungen
Für funktionierendes DevStack benötigt:
- **Database:** mysql oder postgresql
- **Message Queue:** rabbit (RabbitMQ)
- **Core Services:** keystone, nova, neutron, glance
- **Optional:** cinder, placement (empfohlen)

### 4. gophercloud/devstack-action Quirks
- **DevStack Pfad:** Relative path `./devstack` statt `/opt/stack/devstack`
- **openrc Location:** `./devstack/openrc`
- **Logs:** Nicht im Standard-Verzeichnis (möglicherweise systemd journal)
- **Version:** v0.19 ist stabiler als v0.6

### 5. GitHub Actions Constraints
- **Disk Space:** ~14GB verfügbar, DevStack braucht ~10GB
  - **Solution:** Aggressive Cleanup vor Installation
- **Runtime:** ~11 Minuten für komplettes DevStack Deployment
- **Timeout:** 90 Minuten sollten ausreichen (vorher 60)

### Phase 2: BOSH CPI Integration

1. **Stemcell Alternativen**
   - BOSH Stemcells: ~3GB (measured), passen auf Disk (110GB measured via `df -h`)
   - BOSH Stemcells: Upload zu Glance schlägt fehl (413 error, 15+ attempts documented in troubleshooting.md)
   - Ubuntu Cloud Image: ~600MB, VM creation failed (ERROR state) - root cause unknown
   - **Cirros Test Image: ~13MB, funktioniert perfekt** ✅ (verified in [Run 3](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29092040017))

2. **VM Creation funktioniert**
   - Cirros (~13MB) boots successfully in ~30 seconds (measured in Run 3)
   - Ubuntu Cloud Image (~600MB) failed - root cause unknown (Run 2)
   - Stemcells not tested with actual VMs (blocked by Glance 413 upload error)

3. **CPI Operations validiert**
   - VM Create/Delete Cycle funktioniert ✅ (verified in [Run 3](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29092040017))
   - Volume Attach/Detach funktioniert ✅ (verified in [Run 4](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29254127235))
   - Custom Networks/Subnets funktionieren ✅ (verified in Run 4)
   - Security Groups funktionieren ✅ (verified in Run 4)
   - OpenStack APIs vollständig nutzbar (all core services operational in [Run 6](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29082718957))
   
4. **Nicht getestete Operationen**
   - Floating IPs (external connectivity)
   - VM Snapshots
   - Multiple NICs per VM
   - Volume snapshots
   - Load balancers

---

## Nächste Schritte (Optional)

### Phase 3: Echter BOSH CPI Test

**Ziel:** Echten BOSH Director deployen und CPI Release verwenden

#### Tasks:
1. **BOSH Director Setup**
   - bosh-deployment Manifest anpassen
   - Director mit OpenStack CPI deployen
   - Director-Credentials konfigurieren

2. **CPI Release Tests**
   - cloud-foundry/bosh-openstack-cpi-release clonen
   - CPI Lifecycle Tests anpassen
   - Tests gegen DevStack laufen lassen

3. **Full Integration**
   - BOSH-managed VM deployment
   - Persistent Disk attach/detach
   - Snapshot operations
   - Security Groups

---

## Bekannte Einschränkungen

### DevStack in GitHub Actions
- ❌ **Glance 413 Error:** Cannot upload images >1GB (Stemcells blocked). Source: 15+ attempts documented in `troubleshooting.md`
- ⚠️ **Limitierte CPU:** 2 cores. Source: [GitHub Actions docs](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners)
- ✅ **RAM:** ~16GB available. Source: Measured via `tmpfs 7.9G /dev/shm` (50% of physical RAM) in [Run 6](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29082718957)
- ✅ **Disk Space:** 110GB ausreichend für Stemcells (~3GB). Source: `df -h` after cleanup in [Run 6](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29082718957)
- ⚠️ **Logs nicht persistent:** Nach Workflow-Ende verloren (außer als Artifacts)
- ✅ **Für funktionale CPI Tests:** Alle benötigten APIs verfügbar (mit Cirros)

### Workarounds für Production Tests
- **Self-hosted Runner:** Mehr Ressourcen, keine Glance Limits
- **Dedicated VM:** z.B. auf SAP Converged Cloud
- **Real BOSH Stemcells:** Benötigen Glance-Upload-Fix oder externe Glance

---

## Ressourcen

### Dokumentation
- [DevStack Stable/2025.1 Docs](https://docs.openstack.org/devstack/stable-2025.1/)
- [OVN Networking Guide](https://docs.openstack.org/neutron/latest/admin/ovn/index.html)
- [BOSH OpenStack CPI](https://bosh.io/docs/openstack-cpi/)
- [Cirros Test Image](https://github.com/cirros-dev/cirros)

### GitHub Actions Workflows
- [Phase 1: DevStack Smoke Test](.github/workflows/devstack-smoke-test-fixed.yml)
- [Phase 2: BOSH CPI Test](.github/workflows/bosh-cpi-test.yml)
- [Troubleshooting Guide](./troubleshooting.md)

### Successful Runs
- [Phase 1 Success](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29082718957)
- [Phase 2 Success](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29092040017)

---

## Fazit

### Ist DevStack geeignet für BOSH CPI CI?

✅ **JA, mit Einschränkungen**

**Vorteile:**
- Schnelles Setup (~11 Min, measured in [Run 6](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29082718957))
- Alle benötigten OpenStack APIs verfügbar (verified in Run 6)
- Kostenlos in GitHub Actions
- VM Lifecycle funktioniert mit Cirros (Create/Delete in ~30s, verified in Run 3)
- Reproduzierbar und automatisierbar

**Einschränkungen:**
- Glance 413 error blockiert Stemcell uploads (>1GB). Source: 15+ attempts documented in `troubleshooting.md`
- Cirros (~13MB) funktioniert, aber nicht repräsentativ für echte Stemcells
- Nur kleine Images getestet (Cirros 13MB works, Ubuntu 600MB failed)
- Ubuntu Cloud Image (~600MB) fehlgeschlagen - Ursache unklar (no error logs captured)

**Empfehlung:**
- ✅ **Geeignet für:** Funktionale CPI Tests mit Cirros, API-Validierung, Smoke Tests
- ❌ **Nicht geeignet für:** Tests mit echten Stemcells (Glance 413 error - documented in troubleshooting.md)
- ⚠️ **Ungetestet:** Resource constraints for BOSH Director (16GB RAM should be sufficient, 2 CPU impact unknown)
- 🎯 **Use Case:** Ideal für Pull Request Validation mit Cirros (~13MB images)

**Sources:**
- System specs: [Run 6](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29082718957) - `df -h` and `tmpfs` measurements
- VM lifecycle tests: [Run 3](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29092040017) and [Run 4](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29254127235)
- Glance 413 error: Documented in `docs/troubleshooting.md` with 15+ failed configuration attempts

---

**Last Updated:** 2026-07-10  
**Status:** ✅ Phase 1 & 2 Complete - DevStack + CPI Simulation erfolgreich
