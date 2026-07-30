
# BOSH Director Stemcell Lifecycle Test - Code Walkthrough

## Was macht dieser Workflow?

`.github/workflows/bosh-director-lifecycle-test.yml` validiert den **kompletten BOSH CPI Stemcell Lifecycle** in DevStack:

1. Deploy DevStack (OpenStack)
2. Fix Glance Config (DevStack Bug)
3. Deploy BOSH Director
4. Download echte Stemcell (~1.3GB)
5. Upload via BOSH CPI zu Glance
6. VM erstellen aus Stemcell
7. VM verifizieren in OpenStack

**Kritisch:** BOSH CPI führt den Upload durch - genau wie in Production!

---

## Code Walkthrough - Step by Step

### Step 1: System vorbereiten

```yaml
- name: Free up disk space
  run: |
    sudo rm -rf /usr/share/dotnet
    sudo rm -rf /opt/ghc
    sudo rm -rf /usr/local/lib/android
```

**Warum:** GitHub Actions Runner haben ~14GB freien Speicher. Wir brauchen:
- DevStack: ~5GB
- BOSH Director VM: ~4GB
- Stemcell: ~1.3GB
- Headroom: ~3GB

→ **8+ GB müssen frei gemacht werden**

---

### Step 2: DevStack deployen

```yaml
- name: Deploy DevStack
  uses: gophercloud/devstack-action@v0.19
  with:
    branch: stable/2025.1
    conf_overrides: |
      ENABLED_SERVICES=mysql,rabbit,key,n-api,n-cpu,n-cond,n-sch,placement-api
      ENABLED_SERVICES+=,g-api,g-reg
      ENABLED_SERVICES+=,c-sch,c-api,c-vol
      ENABLED_SERVICES+=,q-svc,ovn-controller,ovn-northd,q-ovn-metadata-agent
```

**Was passiert:**
- `gophercloud/devstack-action` deployed OpenStack via DevStack
- `stable/2025.1` = OpenStack Epoxy Release (aktuell)
- Services:
  - `key` = Keystone (Auth)
  - `n-api,n-cpu,n-cond,n-sch` = Nova (Compute)
  - `g-api,g-reg` = Glance (Images)
  - `c-*` = Cinder (Volumes)
  - `q-svc,ovn-*` = Neutron/OVN (Networking)

**Wichtig:** **Kein Swift** (`s-proxy`, `s-object`...)!
- Swift in DevStack hat Bug: 502 Bad Gateway bei großen Uploads
- Glance nutzt Filesystem Backend stattdessen
- **BOSH CPI nutzt trotzdem Standard Glance HTTP API!**

---

### Step 3: OpenStack verifizieren

```yaml
- name: Verify OpenStack
  run: |
    # Try multiple possible locations for openrc
    if [ -f "./devstack/openrc" ]; then
      source ./devstack/openrc admin admin
    elif [ -f "/opt/stack/devstack/openrc" ]; then
      source /opt/stack/devstack/openrc admin admin
    fi
    
    openstack endpoint list
    openstack network list
```

**Was passiert:**
- `openrc` enthält OpenStack Credentials (OS_USERNAME, OS_PASSWORD, OS_AUTH_URL...)
- Pfad variiert je nach Runner: `./devstack/openrc` oder `/opt/stack/devstack/openrc`
- **Fallback-Logik** findet den korrekten Pfad

**Warum wichtig:** Ohne Credentials schlagen alle `openstack` Commands fehl

---

### Step 4: Glance Config Fix (KRITISCH!)

```yaml
- name: Fix Glance filesystem path (remove trailing slash) BEFORE BOSH
  run: |
    # Remove trailing slash from Glance config
    sudo sed -i 's|^\(filesystem_store_datadir\s*=\s*.*\)/$|\1|g' /etc/glance/glance-api.conf
    
    # Restart Glance to apply changes
    sudo systemctl restart devstack@g-api.service
    
    # Wait for Glance to fully reload config
    sleep 30
```

**Das Problem (DevStack Bug):**

DevStack's Glance Config:
```ini
filesystem_store_datadir = /opt/stack/data/glance/images/
                                                        ↑ trailing slash
```

BOSH CPI uploaded Stemcell → Glance baut URL:
```
file:// + /opt/stack/data/glance/images/ + / + image-id
                                       ↑   ↑
                                    config  separator
= file:///opt/stack/data/glance/images//image-id
                                      ↑↑ DOPPEL-SLASH!
```

**Was dann passiert:**
1. Malformed URL in DB gespeichert
2. Nova versucht Image zu downloaden
3. Glance kann Schema nicht parsen: `Unknown scheme '' found in URI`
4. Nova Error: `No valid host was found` → VM ERROR

**Die Fix:**
```bash
sed -i 's|...|/$|\1|g'  # Entfernt trailing slash
```

**Nach Fix:**
```ini
filesystem_store_datadir = /opt/stack/data/glance/images
```

URL wird korrekt gebaut:
```
file:///opt/stack/data/glance/images/image-id  ✅
```

**Timing ist kritisch:**
- `systemctl restart` startet Service neu (~3-5s)
- **Aber:** Glance lädt Config erst ~10-20s NACH Restart!
- `sleep 30` + 3 Checks = ~45s Wartezeit
- Erst dann ist Glance wirklich bereit

**Warum VOR BOSH Director?**
- URL wird beim **Upload** in DB geschrieben
- Späterer Config-Fix ändert alte DB-Einträge nicht
- → Fix MUSS vor erstem Upload passieren!

---

### Step 5: BOSH CLI installieren

```yaml
- name: Install BOSH CLI
  run: |
    wget -O bosh https://github.com/cloudfoundry/bosh-cli/releases/download/v7.8.2/bosh-cli-7.8.2-linux-amd64
    chmod +x bosh
    sudo mv bosh /usr/local/bin/
    bosh --version
```

**Was ist BOSH CLI:**
- `bosh create-env` = Deploy BOSH Director
- `bosh upload-stemcell` = Upload Stemcell
- `bosh deploy` = Deploy VMs

---

### Step 6: BOSH Deployment Manifests laden

```yaml
- name: Download BOSH deployment manifests
  run: |
    git clone https://github.com/cloudfoundry/bosh-deployment.git ~/bosh-deployment
```

**Repo enthält:**
- `bosh.yml` = BOSH Director base manifest
- `openstack/cpi.yml` = OpenStack CPI config
- `uaa.yml` = User authentication
- `credhub.yml` = Credential management

---

### Step 7: OpenStack Variablen sammeln

```yaml
- name: Prepare BOSH Director deployment
  run: |
    source ./devstack/openrc admin admin
    
    # Get OpenStack configuration
    export OS_AUTH_URL=$(openstack catalog show keystone -f json | jq -r '.endpoints[] | select(.interface=="public") | .url')
    export NETWORK_ID=$(openstack network list -f json | jq -r '.[] | select(.Name=="private") | .ID')
```

**Was passiert:**
- `openstack catalog show keystone` = Findet Keystone Auth URL
- `openstack network list` = Findet `private` Network ID
- Diese Werte braucht BOSH CPI um mit OpenStack zu sprechen

**Variables File erstellen:**
```yaml
cat > director-vars.yml <<EOF
auth_url: $OS_AUTH_URL
username: $OS_USERNAME
password: $OS_PASSWORD
net_id: $NETWORK_ID
EOF
```

**Beide Naming Conventions:**
```yaml
auth_url: ...           # Für ältere CPI Versionen
openstack_auth_url: ... # Für neuere CPI Versionen
```

→ Kompatibilität mit allen BOSH CPI Versionen

---

### Step 8: SSH Key hochladen

```yaml
- name: Upload SSH key to OpenStack
  run: |
    ssh-keygen -t rsa -b 4096 -f ~/bosh-director/bosh-ssh-key -N ""
    openstack keypair create --public-key ~/bosh-director/bosh-ssh-key.pub bosh-key
```

**Warum:** BOSH Director VM braucht SSH Key für:
- Jumpbox User (SSH access)
- BOSH Agent Communication

---

### Step 9: BOSH Director deployen

```yaml
- name: Deploy BOSH Director
  run: |
    bosh create-env ~/bosh-deployment/bosh.yml \
      --state ./state.json \
      --vars-store ./creds.yml \
      --vars-file ./director-vars.yml \
      -o ~/bosh-deployment/openstack/cpi.yml \
      -o ~/bosh-deployment/jumpbox-user.yml \
      -o ~/bosh-deployment/uaa.yml \
      -o ~/bosh-deployment/credhub.yml \
      -v director_vm_type=m1.large \
      -v network_name=private
```

**Was macht `bosh create-env`:**
1. Erstellt VM in OpenStack (m1.large: 2 vCPUs, 4GB RAM)
2. Installiert BOSH Director auf der VM
3. Installiert BOSH CPI (OpenStack)
4. Konfiguriert UAA (User Auth)
5. Konfiguriert CredHub (Credentials)

**Ops-Files (`-o`):**
- `openstack/cpi.yml` = OpenStack CPI Konfiguration
- `jumpbox-user.yml` = SSH Zugang einrichten
- `uaa.yml` = User Authentication & Authorization
- `credhub.yml` = Credential Management

**Variables (`-v`):**
- `director_vm_type=m1.large` = Flavor für Director VM (war m1.xlarge, jetzt kleiner!)
- `network_name=private` = Neutron Network

**Output Files:**
- `state.json` = VM State (für späteres `delete-env`)
- `creds.yml` = Generated Credentials (admin_password, SSL certs...)

---

### Step 10: BOSH Director konfigurieren

```yaml
- name: Alias BOSH Director
  run: |
    export BOSH_CLIENT=admin
    export BOSH_CLIENT_SECRET=$(bosh int ./creds.yml --path /admin_password)
    export BOSH_ENVIRONMENT=10.0.0.6
    
    bosh alias-env devstack -e 10.0.0.6 --ca-cert <(bosh int ./creds.yml --path /director_ssl/ca)
    echo "$BOSH_CLIENT_SECRET" | bosh -e devstack login
```

**Was passiert:**
- `bosh int ./creds.yml --path /admin_password` = Liest admin Passwort aus generierten Credentials
- `bosh alias-env devstack` = Erstellt Alias `devstack` für Director IP `10.0.0.6`
- `bosh login` = Authentifiziert als admin User

**Environment für spätere Steps speichern:**
```bash
cat > ~/bosh-env.sh <<EOF
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=$BOSH_CLIENT_SECRET
export BOSH_ENVIRONMENT=10.0.0.6
EOF
```

→ Jeder folgende Step macht `source ~/bosh-env.sh`

---

### Step 11: Stemcell downloaden

```yaml
- name: Download BOSH Stemcell
  run: |
    STEMCELL_VERSION=$(curl -s https://bosh.io/api/v1/stemcells/bosh-openstack-kvm-ubuntu-jammy-go_agent | jq -r '.[0].version')
    STEMCELL_URL="https://storage.googleapis.com/bosh-core-stemcells/${STEMCELL_VERSION}/bosh-stemcell-${STEMCELL_VERSION}-openstack-kvm-ubuntu-jammy-go_agent.tgz"
    wget -O ~/stemcells/stemcell.tgz "$STEMCELL_URL"
```

**Was ist eine Stemcell:**
- Base OS Image (Ubuntu Jammy)
- BOSH Agent vorinstalliert
- ~1.3GB komprimiert
- Wird zu Glance Image

**API Call:**
- `https://bosh.io/api/v1/stemcells/...` = Latest version Info
- `https://storage.googleapis.com/bosh-core-stemcells/...` = Download URL

---

### Step 12: Stemcell Upload via BOSH CPI

```yaml
- name: Upload Stemcell to BOSH Director
  run: |
    source ~/bosh-env.sh
    bosh -e devstack upload-stemcell ~/stemcells/stemcell.tgz
    bosh -e devstack stemcells
```

**DAS ist der kritische Schritt!**

**Was `bosh upload-stemcell` macht:**
1. BOSH CLI sendet Stemcell zu BOSH Director
2. BOSH Director ruft BOSH CPI auf: `create_stemcell()`
3. **BOSH CPI macht HTTP Upload zu Glance:**
   ```
   PUT /v2/images/{id}/file
   Content-Type: application/octet-stream
   Body: <1.3GB Stemcell data>
   ```
4. Glance speichert Image im Filesystem Backend
5. Glance schreibt `file://` URL in `image_locations` Tabelle
6. BOSH CPI returned Glance Image ID

**Kein Workaround:**
- ✅ Standard Glance HTTP API
- ✅ Wie in Production
- ✅ Keine MySQL Manipulation
- ✅ Kein Filesystem Copy

---

### Step 13: Test VM deployen

```yaml
- name: Deploy test VM from Stemcell
  run: |
    # Create cloud config
    cat > ~/cloud-config.yml <<EOF
    vm_types:
    - name: default
      cloud_properties:
        instance_type: m1.small
    EOF
    
    bosh -e devstack update-cloud-config ~/cloud-config.yml
    bosh -e devstack -d test-vm deploy ~/test-deployment.yml
```

**Was passiert:**
1. Cloud Config = OpenStack Flavor Mapping (`m1.small`)
2. Deployment Manifest = VM Specification
3. `bosh deploy`:
   - Ruft BOSH CPI auf: `create_vm(stemcell_id, ...)`
   - CPI erstellt Nova VM aus Glance Image
   - VM bootet mit BOSH Agent

**Das testet den kompletten Lifecycle:**
- ✅ Stemcell Upload funktioniert
- ✅ Glance Image ist nutzbar
- ✅ Nova kann VM erstellen
- ✅ BOSH Agent startet

---

### Step 14: VM verifizieren

```yaml
- name: Verify VM via OpenStack
  run: |
    source ./devstack/openrc admin admin
    openstack server list --all-projects
    VM_ID=$(openstack server list -f json | jq -r '.[] | select(.Name | contains("test-vm")) | .ID' | head -1)
    openstack server show "$VM_ID"
```

**Verifiziert:**
- VM existiert in OpenStack
- VM ist ACTIVE
- Von BOSH erstellt
- Aus uploaded Stemcell

---

## Zusammenfassung

**Was der Workflow NICHT macht:**
- ❌ Keine MySQL Manipulation
- ❌ Kein direktes Filesystem Copy
- ❌ Keine Glance API Umgehung

**Was der Workflow macht:**
- ✅ Standard BOSH CPI Upload
- ✅ Standard Glance HTTP API
- ✅ Production-Ready Approach
- ✅ Nur DevStack Config-Bugs gefixed

**Der einzige "Workaround":**
Filesystem Backend statt Swift - aber das ist eine **Backend-Wahl**, kein API-Bypass!

---

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
DevStack Deployment
  ↓
FIX: Configure Nova for QEMU (cpu_mode=none, virt_type=qemu)
FIX: Configure Nova scheduler (minimal filters)
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
Nova creates VM (via QEMU)
```

**Vorteile:**
- ✅ Nutzt echten BOSH CPI Upload-Pfad
- ✅ Standard Glance HTTP API
- ✅ Nur Config-Fixes (kein API-Bypass!)
- ✅ Nova korrekt für GitHub Actions konfiguriert (QEMU statt KVM)
- ✅ Scheduler-Filter minimiert (verhindert Host-Rejection)
- ✅ Relevant für BATS
- ✅ Wie in Production (nur Virtualisierung unterschiedlich)

**Die Config-Fixes:**
1. **Nova Libvirt:** cpu_mode=none, virt_type=qemu (QEMU statt KVM)
2. **Nova Scheduler:** Minimal filter set (verhindert "No valid host")
3. **Glance:** trailing slash entfernt (verhindert malformed URLs)

---

## GitHub Actions Limitations

### Keine Nested Virtualization

**Problem:**
GitHub Actions Runner unterstützen keine Hardware-Virtualisierung:
```
Host (GitHub Runner) → VM (GitHub Actions) → OpenStack Nova → BOSH VMs
                      ↑ Keine nested virt!
```

**Lösung:**
- Nova nutzt QEMU Emulation statt KVM
- cpu_mode=none (keine CPU-Feature-Passthrough)
- virt_type=qemu (Software-Emulation)
- Minimal scheduler filters (weniger strikte Checks)

**Performance:**
- VMs laufen langsamer (Emulation)
- Aber: Funktional identisch zu KVM
- Ausreichend für BATS Tests

**Production:**
- Nutzt echte Hardware-Virtualisierung (KVM/ESXi)
- Bessere Performance
- Gleiche BOSH CPI API Calls!

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
