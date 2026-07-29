# BOSH Director Stemcell Lifecycle Test - Explained

## Überblick

Dieser Test validiert den **kompletten BOSH CPI Stemcell Lifecycle** in DevStack:
- BOSH Director Deployment
- Echte Stemcell Download (~1.3GB)
- **Stemcell Upload via BOSH CPI** (HTTP API zu Glance)
- VM Erstellung aus Stemcell
- VM Lifecycle Management

**Kritisch:** Der BOSH CPI führt den Upload durch - genau wie in Production!

---

## Warum dieser Test?

### Das eigentliche Ziel

Wir wollen die **BATS (BOSH Acceptance Tests)** aus dem offiziellen BOSH OpenStack CPI Repository in GitHub Actions laufen lassen:
https://github.com/cloudfoundry/bosh-openstack-cpi-release/blob/master/ci/pipeline.yml

### Warum BATS?

BATS validieren:
- BOSH Director funktioniert mit OpenStack
- BOSH CPI kann Stemcells hochladen
- BOSH CPI kann VMs erstellen/updaten/löschen
- BOSH CPI kann Persistent Disks managen
- BOSH CPI kann Networking konfigurieren

### Voraussetzung für BATS

**BOSH Director muss laufen!**

Daher ist dieser Test der **erste Schritt**:
1. ✅ Dieser Test: BOSH Director + Stemcell Lifecycle (Basis)
2. ⏭️ Nächster Schritt: Vollständige BATS Tests hinzufügen

---

## Architektur

### Komponenten

```
GitHub Actions Runner (Ubuntu 24.04)
├─ DevStack (OpenStack)
│  ├─ Nova (Compute)
│  ├─ Glance (Image) - Filesystem Backend
│  ├─ Neutron (Network)
│  └─ Cinder (Volume)
├─ BOSH Director (deployed als VM in DevStack)
│  ├─ BOSH CPI (OpenStack)
│  └─ BOSH CLI
└─ Test VM (deployed via BOSH)
```

### Data Flow

```
bosh.io
  ↓ (download ~1.3GB)
BOSH CLI
  ↓ (bosh upload-stemcell)
BOSH Director
  ↓ (BOSH CPI)
OpenStack Glance API (PUT /v2/images/{id}/file)
  ↓ (HTTP Upload - KEIN Workaround!)
Glance Storage (filesystem backend)
  ↓
Nova creates VM
```

---

## Workflow Steps im Detail

### 1. DevStack Deployment

```yaml
uses: gophercloud/devstack-action@v0.19
with:
  branch: stable/2025.1
  conf_overrides: |
    ENABLED_SERVICES=mysql,rabbit,key,n-api,n-cpu,g-api,g-reg,c-api,c-vol
    # WICHTIG: Kein Swift! (502 Bad Gateway bei großen Uploads)
```

**Warum Filesystem Backend?**
- Swift in DevStack hat Probleme mit großen Uploads (>1GB)
- Apache Proxy gibt 502 Bad Gateway bei Swift Backend
- Filesystem Backend vermeidet diese DevStack-spezifischen Bugs
- **BOSH CPI nutzt trotzdem Standard Glance HTTP API** - kein Workaround!
- Production nutzt Swift/Ceph (hat das Problem nicht)

**Dokumentation:**
```
"Test mit DevStack Filesystem Backend"
"Production nutzt Swift/Ceph (kein Apache Proxy Problem)"
"Validiert: BOSH CPI Funktionalität, nicht Storage Backend Performance"
```

---

### 2. Glance Filesystem Path Fix (VOR BOSH Deployment!)

**KRITISCHER DevStack-Bugfix - MUSS VOR BOSH Director passieren!**

```bash
sudo sed -i 's|^\(filesystem_store_datadir\s*=\s*.*\)/$|\1|g' /etc/glance/glance-api.conf
sudo systemctl restart devstack@g-api.service
# Wait for Glance to reload config
sleep 15
```

**Problem:**
DevStack's Glance Config hat standardmäßig einen **trailing slash**:
```ini
filesystem_store_datadir = /opt/stack/data/glance/images/
                                                        ↑ trailing slash
```

**Warum das ein Problem ist:**

Wenn BOSH CPI ein Stemcell hochlädt, baut Glance die `file://` URL:
```bash
FILE_URL = "file://" + filesystem_store_datadir + "/" + image_id
```

**Mit trailing slash:**
```
file:///opt/stack/data/glance/images/ + / + abc123
                                    ↑   ↑
                              trailing  separator
= file:///opt/stack/data/glance/images//abc123
                                      ↑↑ DOPPEL-SLASH!
```

**Was passiert:**
1. BOSH CPI schreibt malformed URL in `image_locations` Tabelle
2. Nova liest URL aus Datenbank
3. Glance kann Schema nicht aus malformed URL extrahieren
4. `glance_store.exceptions.UnknownScheme: Unknown scheme '' found in URI`
5. Nova bekommt Connection Reset → VM ERROR State

**Die Lösung:**
```ini
filesystem_store_datadir = /opt/stack/data/glance/images
                                                        ↑ KEIN trailing slash!
```

**Jetzt baut Glance:**
```
file:///opt/stack/data/glance/images + / + abc123
= file:///opt/stack/data/glance/images/abc123  ✅ Korrekt!
```

**WICHTIG: Timing ist kritisch!**

Der Fix muss **VOR** dem BOSH Director Deployment passieren UND Glance muss die neue Config vollständig geladen haben:

```
❌ FALSCH:
   Deploy BOSH Director → Upload Stemcell → Fix Glance Config
   (URL bereits falsch in DB geschrieben!)

❌ AUCH FALSCH:
   Fix Glance Config → Restart Glance (zu kurze Wait) → Deploy BOSH Director → Upload Stemcell
   (Glance hat Config noch nicht neu geladen!)

✅ RICHTIG:
   Fix Glance Config → Restart Glance → Wait 30s + Verify → Deploy BOSH Director → Upload Stemcell
   (URL wird korrekt geschrieben!)
```

**Warum?**
- Die malformed URL wird beim **CPI Upload** in die Datenbank geschrieben
- Nova liest die URL aus der **Datenbank**, nicht aus der Config
- Ein späterer Config-Fix ändert die bereits geschriebene URL nicht
- Glance braucht Zeit, um die neue Config vollständig zu laden (nicht sofort nach Restart!)

**Timing Details:**
- Config-Fix: sed command (~1s)
- Glance Restart: systemctl restart (~3-5s)
- **Config Reload**: Glance lädt Config neu (~10-20s nach Restart!)
- Verification: Multiple checks um sicherzustellen dass Glance stabil ist
- **Gesamt Wait**: 30s + 3x Checks à 5s = ~45s

**Referenz:**
- Dokumentiert in: `docs/bats-smoke-test-troubleshooting-journey.md` Problem 8
- Root Cause Analysis: Workflow Run vom 2026-07-28

**Wichtig:**
- Dies ist ein **DevStack Config-Bug**, kein Glance-Bug
- Production OpenStack hat dieses Problem nicht
- Der Fix ist eine Config-Korrektur, kein API-Bypass
- BOSH CPI nutzt weiterhin den echten HTTP Upload-Pfad!

---

### 3. BOSH CLI Installation

```bash
wget https://github.com/cloudfoundry/bosh-cli/releases/download/v7.8.2/bosh-cli-7.8.2-linux-amd64
chmod +x bosh
sudo mv bosh /usr/local/bin/
```

**BOSH CLI v2** ist das moderne Tool für:
- BOSH Director Deployment (`bosh create-env`)
- Stemcell Management (`bosh upload-stemcell`)
- Deployment Management (`bosh deploy`)

---

### 4. BOSH Deployment Manifests

```bash
git clone https://github.com/cloudfoundry/bosh-deployment.git
```

**bosh-deployment Repository:**
- Offizielle BOSH Director Deployment Manifests
- Ops-Files für verschiedene Infrastrukturen (AWS, Azure, OpenStack, etc.)
- Cloud Provider Interface Konfigurationen

**Für OpenStack:**
- `bosh.yml` - Base manifest
- `openstack/cpi.yml` - OpenStack CPI Configuration
- `jumpbox-user.yml` - SSH access
- `uaa.yml` - User authentication
- `credhub.yml` - Credential management

---

### 5. OpenStack Konfiguration sammeln

```bash
source ~/devstack/openrc admin admin

export OS_AUTH_URL=$(openstack catalog show keystone -f json | jq -r '.endpoints[] | select(.interface=="public") | .url')
export NETWORK_ID=$(openstack network list -f json | jq -r '.[] | select(.Name=="private") | .ID')
```

**Benötigte Informationen:**
- Keystone Auth URL
- Project/Tenant Name
- Credentials (Username/Password)
- Network IDs
- Region Name
- Domain Name

**Variablen File erstellen:**
```yaml
director_name: bosh-devstack
internal_cidr: 10.0.0.0/24
internal_gw: 10.0.0.1
internal_ip: 10.0.0.6

openstack_auth_url: http://10.1.0.X/identity
openstack_username: admin
openstack_password: secret
openstack_domain: Default
openstack_project: admin
openstack_region: RegionOne

net_id: <network-uuid>
az: nova
```

---

### 6. BOSH Director Deployment

```bash
bosh create-env ~/bosh-deployment/bosh.yml \
  --state ./state.json \
  --vars-store ./creds.yml \
  --vars-file ./director-vars.yml \
  -o ~/bosh-deployment/openstack/cpi.yml \
  -o ~/bosh-deployment/jumpbox-user.yml \
  -o ~/bosh-deployment/uaa.yml \
  -o ~/bosh-deployment/credhub.yml
```

**Was passiert:**
1. BOSH CLI liest Manifest + Ops-Files
2. Erstellt VM in OpenStack (m1.xlarge)
3. Installiert BOSH Director Software
4. Konfiguriert PostgreSQL (Director DB)
5. Konfiguriert Blobstore (für Releases/Stemcells)
6. Installiert BOSH CPI (OpenStack)
7. Startet Director Services

**Ergebnis:**
- BOSH Director läuft auf IP: 10.0.0.6
- Admin Credentials in `creds.yml`
- State File in `state.json` (für Updates/Deletes)

**Dauer:** ~10-15 Minuten

---

### 7. BOSH Environment konfigurieren

```bash
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$(bosh int ./creds.yml --path /admin_password)
export BOSH_ENVIRONMENT=10.0.0.6
export BOSH_CA_CERT=$(bosh int ./creds.yml --path /director_ssl/ca)

bosh alias-env devstack -e 10.0.0.6 --ca-cert <(bosh int ./creds.yml --path /director_ssl/ca)
bosh -e devstack login
```

**BOSH CLI Umgebung:**
- `BOSH_CLIENT` - Username für Director
- `BOSH_CLIENT_SECRET` - Password
- `BOSH_ENVIRONMENT` - Director IP/URL
- `BOSH_CA_CERT` - SSL Certificate für HTTPS

**Alias:**
- `devstack` = Shortcut für Director
- Gespeichert in `~/.bosh/config`

---

### 8. Stemcell Download

```bash
STEMCELL_VERSION=$(curl -s https://bosh.io/api/v1/stemcells/bosh-openstack-kvm-ubuntu-jammy-go_agent | jq -r '.[0].version')
STEMCELL_URL="https://storage.googleapis.com/bosh-core-stemcells/${STEMCELL_VERSION}/bosh-stemcell-${STEMCELL_VERSION}-openstack-kvm-ubuntu-jammy-go_agent.tgz"

wget -O stemcell.tgz "$STEMCELL_URL"
```

**Stemcell Info:**
- OS: Ubuntu 22.04 (Jammy Jellyfish)
- Agent: Go Agent (modern BOSH agent)
- Format: QCOW2 (für OpenStack KVM)
- Größe: ~1.3GB compressed

**bosh.io API:**
- Liste aller verfügbaren Stemcells
- Automatisch neueste Version ermitteln
- Fallback zu Google Storage Direct URL

---

### 9. Stemcell Upload via BOSH CPI

```bash
bosh -e devstack upload-stemcell ~/stemcells/stemcell.tgz
```

**DAS IST DER KRITISCHE SCHRITT!**

**Was passiert intern:**

1. **BOSH CLI** liest Stemcell Tarball
2. **Extrahiert** image file (qcow2)
3. **Ruft BOSH Director API** auf
4. **BOSH Director** nutzt **BOSH CPI**
5. **BOSH CPI** ruft **Glance API** auf:
   ```
   POST /v2/images (create metadata)
   PUT /v2/images/{id}/file (upload image data)
   ```
6. **Glance** speichert in Filesystem Backend
7. **BOSH Director** speichert Stemcell Metadata

**Das ist EXAKT der Weg den Production nutzt!**

- ✅ Kein Filesystem-Workaround
- ✅ Kein MySQL-Hack
- ✅ Standard Glance HTTP API
- ✅ Via BOSH CPI (wie in Production)
- ✅ Trailing slash fix verhindert URL-Fehler

**Dauer:** ~5-10 Minuten (Upload 1.3GB)

---

### 10. Cloud Config erstellen

```yaml
azs:
- name: z1
  cloud_properties:
    availability_zone: nova

vm_types:
- name: default
  cloud_properties:
    instance_type: m1.small

networks:
- name: default
  type: manual
  subnets:
  - range: 10.0.0.0/24
    gateway: 10.0.0.1
    az: z1
    cloud_properties:
      net_id: <network-uuid>
```

**Cloud Config:**
- Definiert IaaS-spezifische Resourcen
- Abstrahiert Infrastructure Details
- Deployment Manifests bleiben portabel

**Komponenten:**
- **AZs (Availability Zones)** - OpenStack Availability Zones
- **VM Types** - OpenStack Flavors (m1.small, m1.medium, etc.)
- **Networks** - OpenStack Networks + Subnets
- **Compilation** - Workers für Package Compilation

---

### 11. Test VM Deployment

```yaml
name: test-vm

stemcells:
- alias: default
  os: ubuntu-jammy
  version: latest

instance_groups:
- name: test-instance
  instances: 1
  azs: [z1]
  jobs: []
  vm_type: default
  stemcell: default
  networks:
  - name: default
```

**Minimales Deployment:**
- 1 VM Instance
- Nutzt uploaded Stemcell
- Keine Jobs/Releases (nur VM Test)
- Nutzt Cloud Config für Infrastructure

```bash
bosh -e devstack -d test-vm deploy test-deployment.yml
```

**Was passiert:**

1. **BOSH Director** plant Deployment
2. **BOSH CPI** wird aufgerufen:
   ```ruby
   create_vm(agent_id, stemcell_id, cloud_properties, networks, disk_cids, env)
   ```
3. **CPI** ruft OpenStack Nova API auf:
   ```
   POST /servers (create VM)
   ```
4. **Nova** zieht Image von **Glance**
5. **VM** bootet mit **BOSH Agent**
6. **Agent** registriert sich bei **Director**
7. **Director** marked VM als "running"

**Ergebnis:**
- VM läuft in OpenStack
- BOSH Director managed VM
- Kann via `bosh vms` gesehen werden

---

### 12. Verification

```bash
# Via BOSH
bosh -e devstack -d test-vm vms

# Via OpenStack
openstack server list --all-projects
openstack server show <vm-id>
```

**Bestätigt:**
- ✅ VM existiert in OpenStack
- ✅ VM hat korrekte Metadata (BOSH labels)
- ✅ VM nutzt Stemcell Image
- ✅ VM ist in korrektem Netzwerk
- ✅ BOSH Agent läuft (Status: running)

---

### 13. Cleanup

```bash
bosh -e devstack -d test-vm delete-deployment --force
```

**BOSH Cleanup:**
- Stoppt VM
- Löscht VM via CPI
- Löscht Persistent Disks (falls vorhanden)
- Entfernt Deployment Metadata

**WICHTIG:** Stemcell bleibt im Director (für weitere Deployments)

---

## Unterschied zu vorherigem Test

### Alter Test (main Branch):

```
Stemcell Download
  ↓
Extract image
  ↓
FILESYSTEM WORKAROUND:
  - sudo cp image /opt/stack/data/glance/images/${IMAGE_ID}
  - sudo mysql glance -e "UPDATE images SET status='active'..."
  ↓
Nova creates VM
```

**Problem:**
- Umgeht Glance HTTP API
- Umgeht BOSH CPI
- Nicht relevant für BATS Tests
- Nur DevStack-spezifisch

### Neuer Test (feature Branch):

```
Stemcell Download
  ↓
FIX: Remove trailing slash from Glance config
  ↓
BOSH CLI upload-stemcell
  ↓
BOSH Director
  ↓
BOSH CPI
  ↓
GLANCE HTTP API (PUT /v2/images/{id}/file)
  ↓
Glance Storage (file:// URL korrekt!)
  ↓
Nova creates VM
```

**Vorteile:**
- ✅ Nutzt echten BOSH CPI Upload-Pfad
- ✅ Standard Glance HTTP API
- ✅ Nur Config-Fix (kein API-Bypass!)
- ✅ Relevant für BATS
- ✅ Wie in Production

**Der einzige "Workaround":**
- DevStack Config-Bug (trailing slash) wird gefixed
- Dies ist eine **Korrektur**, kein Workaround des Upload-Pfads
- Production OpenStack hat diesen Config-Bug nicht

---

## Warum Filesystem Backend OK ist

### Das Problem mit Swift in DevStack:

```
Client → Apache Proxy → Glance → Swift
                ↑
           502 Bad Gateway
        (bei großen Uploads >1GB)
```

**Root Cause:**
- Apache Proxy in DevStack hat Timeout/Buffer Issues
- Nur bei großen Files (>1GB)
- DevStack-spezifisches Problem

**Außerdem:**
- Glance's filesystem backend hatte trailing slash Bug
- Dieser Bug verhinderte erfolgreichen HTTP Upload
- Bug ist jetzt gefixed (siehe Step 2)

### Production hat diese Probleme NICHT:

```
BOSH CPI → Glance (direkter Port) → Swift/Ceph
```

- Kein Apache Proxy dazwischen
- Swift/Ceph optimiert für große Objects
- Production-Grade Load Balancer
- Kein trailing slash Config-Bug

### Daher: Filesystem Backend akzeptabel

**Was wir testen:**
- ✅ BOSH CPI kann Glance API aufrufen
- ✅ Glance kann große Images verarbeiten (nach trailing slash Fix!)
- ✅ Nova kann VMs von großen Images booten
- ✅ BOSH Lifecycle funktioniert

**Was wir NICHT testen:**
- ❌ Swift/Ceph Backend Performance
- ❌ Object Storage Replication
- ❌ S3-kompatible API

**Das ist OK für BATS!**

BATS validieren **BOSH CPI Funktionalität**, nicht **Storage Backend Performance**.

**Wichtig:**
Der trailing slash Fix stellt sicher, dass der BOSH CPI Upload-Pfad funktioniert!
Dies ist kein Workaround, sondern eine DevStack Config-Korrektur.

---

## Nächste Schritte: Vollständige BATS

### Dieser Test = Basis

```
✅ DevStack läuft
✅ BOSH Director läuft
✅ Stemcell Upload funktioniert
✅ VM Lifecycle funktioniert
```

### Nächster Schritt: BATS hinzufügen

```bash
# Clone BATS Repository
git clone https://github.com/cloudfoundry/bosh-acceptance-tests.git

# Configure BATS
export BAT_STEMCELL=~/stemcells/stemcell.tgz
export BAT_DEPLOYMENT_SPEC=~/bat.yml
export BAT_INFRASTRUCTURE=openstack

# Run BATS
cd bosh-acceptance-tests
bundle exec rspec spec
```

**BATS Coverage:**
- VM Lifecycle (create, recreate, delete)
- Persistent Disks (create, attach, detach, snapshot)
- Networking (multiple networks, reconfigure)
- SSH access
- Agent communication
- Resurrection (auto-heal failed VMs)

**Dauer:** ~60 Minuten

---

## Troubleshooting

### BOSH Director Deployment fehlschlägt

**Symptom:**
```
Error: Failed to create VM
```

**Checks:**
1. OpenStack Quota ausreichend? (`openstack quota show`)
2. Flavor `m1.xlarge` existiert? (`openstack flavor list`)
3. Network korrekt konfiguriert? (`openstack network show private`)
4. SSH Key hochgeladen? (`openstack keypair list`)

**Lösung:**
```bash
# Create m1.xlarge if missing
openstack flavor create m1.xlarge --ram 8192 --disk 80 --vcpus 4
```

---

### Stemcell Upload timeout

**Symptom:**
```
Error: Upload failed after 30 minutes
```

**Ursache:**
- Netzwerk zu langsam
- Glance überlastet

**Lösung:**
```bash
# Increase timeout in CPI config
# Oder: Retry manually
bosh -e devstack upload-stemcell stemcell.tgz
```

---

### VM Deployment fehlschlägt

**Symptom:**
```
Error: VM failed to start
```

**Checks:**
1. Stemcell korrekt hochgeladen? (`bosh stemcells`)
2. Cloud Config korrekt? (`bosh cloud-config`)
3. OpenStack Quota? (`openstack quota show`)
4. Nova Logs: `sudo journalctl -u devstack@n-cpu`

---

## Performance Erwartungen

### Timing Breakdown:

```
DevStack Deployment:     ~10 Min
Glance Config Fix:       ~1 Min   (NEU!)
BOSH CLI Installation:   ~1 Min
BOSH Director Deploy:    ~15 Min
Stemcell Download:       ~3 Min (abhängig von Netzwerk)
Stemcell Upload:         ~10 Min (1.3GB Upload)
VM Deployment:           ~5 Min
Total:                   ~45 Min
```

### Ressourcen:

```
RAM:  ~8GB für BOSH Director + Test VMs
Disk: ~30GB für Stemcells + VMs
CPU:  ~4 Cores
```

GitHub Actions Runner: ✅ Ausreichend!

---

## Zusammenfassung

**Dieser Test validiert:**
1. ✅ BOSH Director kann in DevStack deployed werden
2. ✅ DevStack Glance Config-Bug kann gefixed werden (trailing slash)
3. ✅ BOSH CPI kann Stemcells hochladen (via HTTP API!)
4. ✅ BOSH CPI kann VMs erstellen
5. ✅ Stemcells können zu bootfähigen VMs werden
6. ✅ BOSH kann VM Lifecycle managen

**Das ist die Basis für:**
- Vollständige BATS Tests
- CPI Lifecycle Tests
- Production-ähnliche Validierung

**DevStack Limitations dokumentiert:**
- Filesystem Backend (statt Swift/Ceph)
- Trailing slash Config-Bug (wird gefixed)
- Für BATS Tests akzeptabel
- Production nutzt Swift/Ceph ohne diese Issues

**Wichtig:**
Der trailing slash Fix ist eine **Config-Korrektur**, kein Workaround!
BOSH CPI nutzt weiterhin den echten HTTP API Upload-Pfad.
