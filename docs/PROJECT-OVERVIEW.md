# Projekt-Übersicht: BOSH OpenStack CPI Testing in GitHub Actions

**Datum:** 2026-07-28  
**Ziel:** BATS (BOSH Acceptance Tests) aus https://github.com/cloudfoundry/bosh-openstack-cpi-release in GitHub Actions laufen lassen

---

## 🎯 HAUPT-ZIEL (Das eigentliche Ziel!)

### Was wir erreichen wollen:

Die **BATS Tests aus der offiziellen BOSH OpenStack CPI Pipeline** in GitHub Actions ausführen:
- Repository: https://github.com/cloudfoundry/bosh-openstack-cpi-release
- Pipeline: https://github.com/cloudfoundry/bosh-openstack-cpi-release/blob/master/ci/pipeline.yml
- BATS Repo: https://github.com/cloudfoundry/bosh-acceptance-tests

### Warum BATS?

BATS = **BOSH Acceptance Tests**

Diese Tests validieren:
- ✅ BOSH Director funktioniert mit OpenStack
- ✅ BOSH CPI kann Stemcells hochladen
- ✅ BOSH CPI kann VMs erstellen/updaten/löschen
- ✅ BOSH CPI kann Persistent Disks managen
- ✅ BOSH CPI kann Networking konfigurieren
- ✅ BOSH kann komplexe Deployments orchestrieren

**Das ist HIGH-LEVEL Integration Testing** - nicht nur Unit Tests!

---

## 📊 Repository Status

### Branch: `main`
**Status:** Funktioniert, aber **NICHT relevant für BATS**

**Inhalt:**
- Direkter Stemcell-Upload zu Glance
- **Filesystem-Workaround** (umgeht HTTP API)
- MySQL-Hack für Image-Aktivierung
- VM wird direkt via OpenStack CLI erstellt

**Warum nicht relevant?**
```
BATS brauchen: BOSH Director → BOSH CPI → OpenStack
Main Branch hat: Direkter OpenStack API Call (kein BOSH!)
```

**Behalten für:** Historische Referenz, zeigt dass Stemcells grundsätzlich funktionieren

---

### Branch: `feature/swift-backend`
**Status:** ❌ **GELÖSCHT** (2026-07-28)

**Was war das:**
- Versuch Swift Backend zu nutzen (production-like)
- Scheiterte mit 502 Bad Gateway bei großen Uploads
- DevStack Apache Proxy Problem

**Warum gelöscht:**
- War Sackgasse
- Swift in DevStack unzuverlässig für große Files
- Nicht notwendig für BATS Ziel

---

### Branch: `feature/bats-with-bosh-director` ⭐ **AKTUELL**
**Status:** ✅ In Entwicklung - **DER richtige Ansatz!**

**Inhalt:**
- Deploy DevStack (Filesystem Backend)
- Deploy BOSH Director via `bosh create-env`
- Download echte Stemcell (~1.3GB)
- **Upload via BOSH CPI** (nutzt Glance HTTP API!)
- VM Deployment via BOSH
- Lifecycle Testing

**Workflow:** `.github/workflows/bosh-director-lifecycle-test.yml`

**Warum richtig?**
```
✅ BOSH Director deployed (Basis für BATS!)
✅ BOSH CPI macht Upload (wie in Production!)
✅ Kein Workaround
✅ Standard Glance HTTP API
✅ Bereitet BATS vor
```

---

## 🚀 Roadmap

### Phase 1: BOSH Director + Stemcell Lifecycle ⬅️ **WIR SIND HIER**
**Branch:** `feature/bats-with-bosh-director` (KVM - nicht funktionsfähig)  
**Branch:** `feature/bosh-qemu-test` (QEMU Alternative - in Testing)  
**Status:** 🔧 **Blockiert - KVM funktioniert nicht auf GitHub Actions**

**Ziele:**
- [x] DevStack Deployment
- [x] BOSH CLI Installation
- [x] BOSH Director Deployment
- [x] Glance Filesystem Trailing Slash Fix (KRITISCH!)
- [x] Fix: Glance Config Reload Timing (45s wait)
- [x] Nova KVM Support Debugging (dutzende Versuche)
- [❌] Nova Hypervisor als KVM registriert → **GESCHEITERT**
- [🔄] QEMU Alternative: ImagePropertiesFilter deaktivieren → **IN TESTING**
- [ ] Stemcell Upload via BOSH CPI erfolgreich validieren
- [ ] VM Lifecycle erfolgreich testen
- [ ] Stabilität validieren

**Aktuelle Situation (2026-07-31):**

**KVM Approach (gescheitert):**
- ✅ KVM Module geladen (`kvm_amd`)
- ✅ `/dev/kvm` mit 0666 permissions
- ✅ runner kann `/dev/kvm` lesen/schreiben
- ✅ Nova config: `virt_type = kvm`
- ❌ **ABER: libvirt zeigt NUR `<domain type='qemu'/>`**
- ❌ **Nova registriert als `hypervisor_type='QEMU'`**
- ❌ **"No valid host was found" bei Stemcell Upload**

Alle Lösungsversuche (modprobe, udev, libvirtd restart, Placement Provider delete) haben NICHT funktioniert.

**QEMU Approach (aktueller Test):**
- 🔄 Neuer Workflow: `bosh-director-qemu-test.yml`
- 🎯 Strategie: ImagePropertiesFilter deaktivieren
- 💡 Idee: Nova checkt hypervisor_type nicht → akzeptiert KVM-Stemcells
- ⚠️ Risiko: Filter könnte trotzdem greifen oder hardcoded sein
- 🐌 Performance: 10-50x langsamer als KVM (Software Emulation)

**Dauer:** ~45-60 Min pro Run (KVM), ~90+ Min (QEMU erwartet)

---

### Phase 1b: Alternative Approaches (falls QEMU scheitert)
**Status:** Backup-Optionen

**Option A: Stemcell Metadata Manipulation**
- Nach BOSH CPI Upload: `openstack image set --property hypervisor_type=qemu`
- ⚠️ Hacky, nicht production-like
- ✅ Sollte funktionieren

**Option B: GitHub Actions Large Runners**
- 💰 Kostenpflichtig
- ❓ Unbekannt ob bessere nested virt support

**Option C: Actuated.dev oder Self-hosted Runners**
- ✅ Echtes KVM support
- 💰 Zusätzliche Kosten/Infrastruktur
- 🔧 Setup-Aufwand

**Option D: Lokale/Staging Tests nur**
- Akzeptieren dass BOSH CPI Tests nicht in GitHub Actions laufen
- Tests nur auf echter Hardware mit KVM

---

### Phase 2: CPI Lifecycle Tests (Optional)
**Status:** Noch nicht gestartet

**Was:**
- Direkte CPI Tests (ohne vollständigen Director)
- Aus pipeline.yml: `run-specs` Task
- Schneller als BATS (~10 Min)

**Wenn:**
- Falls BATS zu komplex/langsam sind
- Als Zwischenschritt

---

### Phase 3: Vollständige BATS Tests
**Status:** Noch nicht gestartet

**Was:**
- Clone `bosh-acceptance-tests` Repo
- Konfiguriere BATS für DevStack
- Run komplette Test Suite

**Erwartungen:**
- Dauer: ~60 Min
- Coverage: Alle BOSH Workflows
- Subset möglich (exclude slow tests)

**Abhängigkeiten:**
- ✅ Phase 1 muss funktionieren!
- BOSH Director muss stabil laufen
- Stemcell Upload muss klappen

---

## 🔍 Wichtige Erkenntnisse

### Filesystem vs. Swift Backend

**Problem:**
```
DevStack + Swift + Apache Proxy → 502 Bad Gateway (bei >1GB Uploads)
```

**Lösung:**
```
DevStack + Filesystem Backend → Funktioniert zuverlässig
```

**Ist das OK für BATS?**

✅ **JA!**

**Begründung:**
1. BATS testen **BOSH CPI Funktionalität**, nicht Storage Backend
2. Production nutzt Swift/Ceph **ohne Apache Proxy** (kein Problem dort!)
3. Der HTTP Upload-Pfad ist identisch (Glance API)
4. Nur die Storage-Implementierung unterscheidet sich

**Dokumentation:**
```
"Test mit DevStack Filesystem Backend (Production nutzt Swift/Ceph)"
"Validiert: BOSH CPI API Calls, nicht Storage Performance"
"DevStack Apache Proxy Limitation dokumentiert"
```

---

### BOSH CPI Upload = Production-like!

**Kritischer Unterschied:**

**❌ Alter Ansatz (main Branch):**
```bash
sudo cp image /opt/stack/data/glance/images/${IMAGE_ID}
sudo mysql glance -e "UPDATE images SET status='active'..."
```
→ Umgeht Glance API, umgeht BOSH CPI, nicht relevant!

**✅ Neuer Ansatz (feature Branch):**
```bash
bosh upload-stemcell stemcell.tgz
  ↓
BOSH Director
  ↓
BOSH CPI: glance.images.upload(image_id, file)
  ↓
Glance HTTP API: PUT /v2/images/{id}/file
  ↓
Glance Storage (filesystem)
```
→ Nutzt echten BOSH CPI Pfad, wie Production!

---

## 📁 Wichtige Dateien

### Workflows

```
.github/workflows/
├── bats-smoke-test.yml                    # ALT - main Branch (Filesystem-Workaround)
└── bosh-director-lifecycle-test.yml       # NEU - feature Branch (BOSH Director + CPI)
```

### Dokumentation

```
docs/
├── bats-smoke-test-explained.md                  # ALT - erklärt Filesystem-Workaround
├── bats-smoke-test-troubleshooting-journey.md    # ALT - History aller Versuche
├── bosh-director-lifecycle-test-explained.md     # NEU - erklärt BOSH Director Test
└── PROJECT-OVERVIEW.md                           # DIESES Dokument!
```

### Scripts

```
.github/scripts/
└── upload_to_glance.py   # Aus Swift-Versuch, nicht mehr relevant
```

---

## 🎓 Lessons Learned

### 1. Ziel-Missverständnis führte zu Umwegen

**Ursprüngliches Verständnis:**
"Teste ob Stemcell-Upload zu Glance funktioniert"

**Echtes Ziel:**
"Lasse BATS Tests in GitHub Actions laufen"

**Konsequenz:**
- Wochenlange Arbeit am Filesystem-Workaround
- Nicht relevant für echtes Ziel
- BATS brauchen BOSH Director, nicht direkte API Calls!

**Learning:**
✅ Ziel von Anfang an klar definieren  
✅ "Warum?" fragen bevor "Wie?"  
✅ End-to-End Use Case verstehen

---

### 2. DevStack != Production

**DevStack Limitation:**
- Swift Backend funktioniert nicht zuverlässig (502 Bad Gateway)
- Apache Proxy Problem bei großen Uploads
- Nur für Dev/Test, nicht Production-Grade

**Production OpenStack:**
- Swift/Ceph ohne Apache Proxy dazwischen
- Optimiert für große Objects
- Kein 502 Problem

**Wichtig:**
✅ DevStack Limitations dokumentieren  
✅ Akzeptieren wenn Test trotzdem wertvoll ist  
✅ Nicht versuchen DevStack "production-like" zu machen

---

### 3. BOSH CPI Path ist entscheidend

**Was zählt:**
Der Upload-Pfad muss den **BOSH CPI** nutzen, nicht direkten API Call!

**Filesystem vs. Swift Backend = weniger wichtig**
**BOSH CPI vs. direkter API Call = SEHR wichtig**

---

### 4. Timing und Config-Reload sind kritisch (2026-07-28)

**Das DevStack Glance Trailing Slash Problem:**

**Problem:**
```
DevStack Config: filesystem_store_datadir = /opt/stack/data/glance/images/
                                                                         ↑ trailing slash
Glance baut URL: file:/// + path + / + image_id
Ergebnis:        file:///opt/stack/data/glance/images//abc123
                                                      ↑↑ Doppel-Slash = malformed!
```

**Lösung:**
```bash
# 1. Config fixen (trailing slash entfernen)
sudo sed -i 's|^\(filesystem_store_datadir\s*=\s*.*\)/$|\1|g' /etc/glance/glance-api.conf

# 2. Glance neu starten
sudo systemctl restart devstack@g-api.service

# 3. WICHTIG: Lang genug warten bis Config vollständig geladen ist!
sleep 30
# + 3x Verifikation mit 5s Intervallen = Gesamt ~45s
```

**Warum Timing kritisch ist:**
1. Config-Fix muss VOR BOSH Director Deployment passieren
2. Glance braucht 10-20s um Config NACH Restart vollständig zu laden
3. Wenn BOSH deployed wird während Glance lädt → alte Config wird gelesen
4. BOSH CPI schreibt falsche URL in Datenbank
5. Nova kann Image nicht downloaden → VM ERROR

**Learning:**
✅ Services brauchen Zeit zum Config-Reload (nicht nur zum Restart!)  
✅ Verify nach Config-Changes (nicht nur Apply)  
✅ Timing von Fixes ist genauso wichtig wie die Fixes selbst  
✅ URLs in Datenbank können nicht nachträglich gefixed werden

**Referenz:**
- `docs/bats-smoke-test-troubleshooting-journey.md` Problem 8
- `docs/bosh-director-lifecycle-test-explained.md` Step 2
- Commit: "Fix: Increase Glance config reload wait time from 15s to 45s"

---

### 5. Nova Hypervisor Registration und KVM Support (2026-07-30)

**Das Nova Hypervisor-Type Problem:**

GitHub Actions Runner unterstützen **nested virtualization** (KVM), aber Nova muss das auch nutzen können!

**Problem #1: KVM Permissions**
```bash
# Problem:
ls -la /dev/kvm
# crw-rw---- 1 root kvm ... /dev/kvm

groups runner
# runner : runner adm dialout cdrom floppy sudo audio dip video plugdev netdev docker

# runner ist NICHT in kvm Gruppe!
```

**Konsequenz:**
- Nova läuft als `runner` User
- `runner` hat keine Permission für `/dev/kvm`
- Libvirt fällt zurück auf QEMU Software-Emulation
- Nova registriert sich als `hypervisor_type='QEMU'` bei Placement

**Problem #2: Stemcell erwartet KVM**
```bash
# BOSH OpenStack Stemcells sind für KVM gebaut:
bosh-stemcell-xxx-openstack-kvm-ubuntu-jammy-go_agent.tgz
                              ↑↑↑
```

**Konsequenz:**
- Nova Scheduler filter: `ImagePropertiesFilter`
- Stemcell Properties: `hypervisor_type='kvm'` (aus Glance Metadata)
- Nova berichtet: `hypervisor_type='QEMU'`
- KVM ≠ QEMU → **"No valid host was found"**

**Problem #3: Hypervisor Type Registration Timing**

Nova registriert `hypervisor_type` beim **ERSTEN Start** bei Placement:
```python
# Nova Compute startup:
if placement.has_provider(my_hostname):
    # Provider exists → UPDATE inventory only
    update_inventory()  # ← Ändert NICHT hypervisor_type!
else:
    # New provider → CREATE with all properties
    create_provider()   # ← Setzt hypervisor_type!
```

**Konsequenz:**
Wenn Nova ohne KVM-Zugriff startet und sich als QEMU registriert:
- Späteres Hinzufügen zur kvm-Gruppe hilft nicht
- Nova Restart macht nur UPDATE (nicht CREATE)
- `hypervisor_type` bleibt QEMU

**Die Lösung (3-stufig):**

**Schritt 1: KVM Permissions FIX**
```bash
# User zur kvm-Gruppe hinzufügen
sudo usermod -aG kvm runner
```

**Schritt 2: Placement Provider DELETE**
```bash
# Beide Registrierungen löschen:
# 1. Compute Service (Nova DB)
openstack compute service delete $COMPUTE_UUID

# 2. Resource Provider (Placement DB)
curl -X DELETE \
  -H "X-Auth-Token: $AUTH_TOKEN" \
  "$PLACEMENT_ENDPOINT/resource_providers/$PROVIDER_UUID"
```

**Schritt 3: Nova Restart → Fresh Registration**
```bash
# Nova Compute stoppen
sudo systemctl stop devstack@n-cpu.service

# Nova Compute starten (mit KVM Zugriff!)
sudo systemctl start devstack@n-cpu.service

# Nova findet KEINEN Provider bei Placement
# → CREATE mit allen Properties
# → hypervisor_type='KVM' wird gesetzt! ✅
```

**Warum beide Löschen kritisch ist:**

Nur Compute Service löschen:
```
Nova startet → Checkt Placement → Findet alten Provider
→ UPDATE (nur Inventory)
→ hypervisor_type bleibt QEMU ❌
```

Beide löschen:
```
Nova startet → Checkt Placement → Findet KEINEN Provider
→ CREATE (alles neu!)
→ hypervisor_type='KVM' wird gesetzt ✅
```

**Verifikation:**
```bash
# 1. Nova detects KVM
sudo journalctl -u devstack@n-cpu.service | grep -i kvm
# Sollte zeigen: <domain>kvm</domain>

# 2. Hypervisor erscheint in API
openstack hypervisor list
# Sollte einen Hypervisor zeigen

# 3. Hypervisor type ist KVM
HYPERVISOR_ID=$(openstack hypervisor list -f value -c ID)
openstack hypervisor show "$HYPERVISOR_ID" -f value -c hypervisor_type
# Sollte zeigen: KVM (NICHT QEMU!)
```

**Learning:**
✅ GitHub Actions Runner UNTERSTÜTZEN nested virt - nutze es!  
✅ User Permissions sind kritisch - `/dev/kvm` Zugriff prüfen!  
✅ Hypervisor Type wird bei CREATION gesetzt, nicht bei UPDATE  
✅ Placement Provider muss gelöscht werden, nicht nur Compute Service  
✅ Match Stemcell Anforderungen mit Hypervisor Capabilities

**Referenz:**
- Commits: 
  - "Fix: Configure Nova QEMU mode AFTER DevStack deploys" (falsche Annahme)
  - "Fix: Force QEMU emulation mode for GitHub Actions" (falsche Annahme)
  - "Fix: Delete Placement provider to force complete re-registration with KVM" (richtig!)
- `docs/bosh-director-lifecycle-test-explained.md` Step 2A (wird ergänzt)

---

### 6. KVM Detection Problem und QEMU Alternative (2026-07-31)

**Das fundamentale Problem:**

Trotz aller Versuche KVM zum Laufen zu bringen, blieb das Problem bestehen:

```bash
✅ KVM Module geladen (kvm_amd)
✅ /dev/kvm existiert mit permissions 0666
✅ runner user kann /dev/kvm lesen/schreiben
✅ Nova config: virt_type = kvm

❌ ABER: libvirt zeigt NUR <domain type='qemu'/>
❌ Nova registriert als hypervisor_type='QEMU'
```

**Alle Lösungsversuche gescheitert:**

1. ✅ `modprobe kvm kvm-amd` → Module geladen
2. ✅ udev rule MODE=0666 → Permissions OK
3. ✅ Stop libvirtd vor DevStack → Half nicht
4. ✅ Restart libvirtd nach udev rule → Immer noch QEMU
5. ✅ Delete Placement Provider + Compute Service → QEMU bleibt

**Warum libvirt KVM nicht erkennt - Hypothesen:**

1. **GitHub Actions Runner Limitation:** Vielleicht unterstützen die Runner doch kein nested virtualization für KVM (trotz `/dev/kvm`)
2. **Libvirt Configuration:** Tiefere Config-Probleme die wir nicht ändern können
3. **QEMU binary:** Compiled ohne KVM support (unwahrscheinlich)
4. **Security Layer:** AppArmor/SELinux blockiert (nicht installiert laut Checks)

**Die QEMU Alternative:**

Da KVM nicht funktioniert, haben wir einen parallelen Ansatz entwickelt:

**Branch: `feature/bosh-qemu-test`**  
**Workflow: `bosh-director-qemu-test.yml`**

**Strategie:**
```
Statt KVM zu erzwingen → QEMU akzeptieren und Scheduler anpassen!
```

**Ansatz 1: ImagePropertiesFilter deaktivieren**
```bash
# Nova Scheduler Filter der hypervisor_type checkt
# Wenn wir ihn aus der Filter-Liste nehmen:
[filter_scheduler]
enabled_filters = AvailabilityZoneFilter,ComputeFilter,ComputeCapabilitiesFilter
# ImagePropertiesFilter FEHLT!

# Dann sollte Nova den hypervisor_type NICHT mehr checken
# und KVM-Stemcells auf QEMU-Compute akzeptieren
```

**Problem mit diesem Ansatz:**
- ⚠️ Könnte trotzdem fehlschlagen wenn Filter hardcoded ist
- ⚠️ Stemcell sagt immer noch "ich will KVM" in metadata
- ⚠️ Nova Scheduler könnte das TROTZDEM checken

**Ansatz 2: Stemcell Metadata überschreiben (falls nötig)**
```bash
# Nach BOSH CPI Upload:
openstack image set --property hypervisor_type=qemu <stemcell-id>

# Damit sagt das Stemcell "ich akzeptiere QEMU"
# Aber: Das untergräbt die BOSH CPI Logik!
```

**Der QEMU Workflow beinhaltet:**

1. DevStack deployment (QEMU by default)
2. **ImagePropertiesFilter deaktivieren** (Haupttrick!)
3. Glance trailing slash fix
4. BOSH CLI installation
5. BOSH Director deployment (m1.small, QEMU)
6. Stemcell download (~1.3GB)
7. **Stemcell upload via BOSH CPI** (normale KVM Stemcell!)
8. Verifikation

**Erwartetes Ergebnis:**

✅ **Best Case:** Nova akzeptiert KVM-Stemcell auf QEMU-Compute  
⚠️ **Likely Case:** "No valid host was found" - Filter greift trotzdem  
❌ **Worst Case:** Muss Stemcell Metadata manipulieren (nicht production-like!)

**Geschwindigkeit:**

QEMU = Software Emulation → **10-50x langsamer** als KVM!
- DevStack: ~25 Min (normal)
- BOSH Director: ~30-60 Min (statt 15-20 Min)
- VM Creation: Sehr langsam

**Learning:**

✅ Nicht jede Virtualisierung ist gleich verfügbar  
✅ `/dev/kvm` existiert ≠ KVM funktioniert  
✅ Libvirt caching ist komplex und schwer zu umgehen  
✅ GitHub Actions Runner könnten Nested Virt Einschränkungen haben  
✅ QEMU ist ein Fallback aber mit großen Performance-Nachteilen  
⚠️ ImagePropertiesFilter zu umgehen ist hacky - nicht production-like  
❌ KVM auf GitHub Actions Free Runners bleibt ungelöst (2026-07-31)

**Alternative Lösungen (nicht getestet):**

1. **GitHub Actions Large Runners:** Vielleicht bessere nested virt support
2. **Actuated.dev:** Third-party CI mit echtem KVM support
3. **Self-hosted Runners:** Auf eigener Hardware mit KVM
4. **Akzeptieren:** BOSH Tests nur lokal/staging, nicht in GitHub Actions

**Status (2026-07-31):**
- KVM Workflow: ❌ Funktioniert nicht (Nova = QEMU trotz allem)
- QEMU Workflow: 🔄 Erstellt, noch nicht getestet
- Nächster Test: QEMU Workflow ausführen und schauen ob Scheduler-Trick funktioniert

**Referenz:**
- Branch: `feature/bosh-qemu-test`
- Workflow: `bosh-director-qemu-test.yml`
- Commits: Dutzende KVM-Fix-Versuche auf `feature/bats-with-bosh-director`
- Community Discussion: https://github.com/orgs/community/discussions/160591

---

## 🚨 Für zukünftige AI-Assistenten

### Wenn du dieses Projekt übernimmst:

**Lies ZUERST:**
1. ✅ Dieses Dokument (PROJECT-OVERVIEW.md)
2. ✅ `docs/bosh-director-lifecycle-test-explained.md`
3. ✅ `docs/bats-smoke-test-troubleshooting-journey.md` Problem 8 (Trailing Slash)

**Frage IMMER:**
- "Was ist das EIGENTLICHE Ziel?" (Nicht: "Was steht im Code?")
- "Wird das für BATS gebraucht?" (Nicht: "Funktioniert das?")
- "Nutzt das den BOSH CPI?" (Nicht: "Lädt es Stemcells hoch?")
- "Hat der Service genug Zeit für Config-Reload?" (Nicht: "Ist der Service gestartet?")

**Vermeide:**
- ❌ Filesystem-Workarounds (nicht BATS-relevant!)
- ❌ Direkte OpenStack API Calls (BOSH CPI muss es machen!)
- ❌ Swift in DevStack fixen (akzeptiere Filesystem Backend!)
- ❌ Zu kurze Wait-Times nach Config-Changes (Services brauchen Zeit zum Laden!)

**Fokus:**
- ✅ BOSH Director muss laufen
- ✅ BOSH CPI muss Upload machen
- ✅ Standard Glance HTTP API nutzen
- ✅ Bereite BATS vor (nicht: "teste Stemcells")
- ✅ Config-Fixes müssen VOR dem BOSH Deployment passieren
- ✅ Gib Services ausreichend Zeit für Config-Reload (~45s für Glance)

**Wichtige DevStack-Quirks:**
1. **Glance Trailing Slash Bug:**
   - DevStack Config hat trailing slash in `filesystem_store_datadir`
   - Führt zu malformed `file://` URLs (Doppel-Slash)
   - Muss gefixed werden BEVOR BOSH Director deployed wird
   - Glance braucht ~45s für vollständiges Config-Reload nach Restart

2. **Nova KVM Permissions:**
   - GitHub Actions Runner HABEN nested virtualization support!
   - DevStack startet Nova als `runner` User
   - `runner` User ist standardmäßig NICHT in `kvm` Gruppe
   - Ohne KVM-Zugriff fällt Libvirt auf QEMU zurück
   - Nova registriert sich als QEMU statt KVM bei Placement
   - BOSH Stemcells erwarten KVM → "No valid host was found"

3. **Placement Provider Registration:**
   - Hypervisor Type wird bei CREATION gesetzt, nicht bei UPDATE
   - Nur Compute Service löschen reicht nicht (Provider bleibt)
   - BEIDE löschen (Compute Service + Placement Provider)
   - Dann macht Nova CREATE statt UPDATE → KVM wird korrekt registriert

4. **Swift Backend Issues:**
   - Apache Proxy in DevStack hat Probleme mit >1GB Uploads
   - 502 Bad Gateway Errors
   - Filesystem Backend ist die zuverlässige Alternative für Tests

---

## 📞 Kontakt & Ressourcen

### Offizielle Repos

- **BOSH Deployment:** https://github.com/cloudfoundry/bosh-deployment
- **BOSH OpenStack CPI:** https://github.com/cloudfoundry/bosh-openstack-cpi-release
- **BATS:** https://github.com/cloudfoundry/bosh-acceptance-tests
- **BOSH CLI:** https://github.com/cloudfoundry/bosh-cli

### Dokumentation

- **BOSH Docs:** https://bosh.io/docs/
- **OpenStack Glance API:** https://docs.openstack.org/api-ref/image/v2/
- **DevStack:** https://docs.openstack.org/devstack/latest/

### Community

- **CF Slack:** https://slack.cloudfoundry.org/ (#openstack channel)
- **Mailing List:** https://lists.cloudfoundry.org/pipermail/cf-bosh

---

## ✅ Checkliste für neue Features

### Bevor du Code schreibst:

- [ ] Ist das für **BATS Tests** relevant?
- [ ] Nutzt es den **BOSH CPI** (nicht direkten API Call)?
- [ ] Ist **BOSH Director** involviert?
- [ ] Brauchst du **echte Stemcells** (~1.3GB)?
- [ ] Ist der Upload-Pfad **production-like** (HTTP API)?

### Wenn NEIN bei irgendwas:
→ Überdenke den Ansatz!
→ Frage: "Bringt mich das zu BATS?"

### Red Flags:

- 🚩 "Filesystem-Workaround" → Nicht für BATS!
- 🚩 "MySQL-Hack" → Nicht für BOSH CPI!
- 🚩 "Swift fixen in DevStack" → Akzeptiere Filesystem!
- 🚩 "Direkter OpenStack API Call" → BOSH CPI muss es machen!
- 🚩 "Service-Restart ohne ausreichende Wait-Time" → Config-Reload braucht Zeit!
- 🚩 "Config-Fix NACH dem Deployment" → Zu spät, URL bereits in DB!

---

## 🎯 TL;DR (Too Long, Didn't Read)

**Ziel:**
BATS Tests in GitHub Actions laufen lassen

**Aktueller Stand (2026-07-31):**
- ❌ **KVM Approach gescheitert** - libvirt erkennt KVM nicht trotz aller Fixes
- 🔄 **QEMU Alternative** in Testing - ImagePropertiesFilter deaktiviert
- 🎯 Branch: `feature/bosh-qemu-test` 
- ⏳ Warten auf Test-Ergebnis

**Das KVM Problem:**
```
✅ KVM Module geladen, /dev/kvm OK, Permissions OK
❌ ABER: libvirt zeigt nur QEMU, nicht KVM
❌ Nova = hypervisor_type='QEMU'
❌ Stemcells wollen 'KVM' → "No valid host was found"
```

**QEMU Workaround:**
1. ImagePropertiesFilter aus Nova Scheduler entfernen
2. Hoffen dass Nova KVM-Stemcells auf QEMU akzeptiert
3. Falls nicht: Stemcell metadata manipulieren (hacky!)

**Wichtigste Regeln:**
1. Der **BOSH CPI** muss den Upload machen, nicht wir direkt!
2. Config-Fixes müssen **VOR** BOSH Director Deployment passieren!
3. Services brauchen Zeit für Config-Reload (~45s für Glance)!
4. ⚠️ **KVM funktioniert NICHT auf GitHub Actions Free Runners** (Stand 2026-07-31)
5. **QEMU = 10-50x langsamer** aber könnte funktionieren

**DevStack Limitations:**
- Filesystem Backend statt Swift (ist OK für BATS!)
- Glance trailing slash Bug (wird gefixed mit 45s reload time)
- **KVM nested virtualization nicht nutzbar** (trotz /dev/kvm)
- QEMU Software Emulation als Fallback (sehr langsam)

**Kritische Sequenz (QEMU):**
```
Deploy DevStack → Disable ImagePropertiesFilter → Fix Glance → Deploy BOSH → Upload Stemcell (KVM) → Hope Nova accepts it
```

**Alternative Lösungen:**
- GitHub Actions Large Runners (kostenpflichtig, vielleicht besseres KVM)
- Actuated.dev / Self-hosted Runners (echtes KVM)
- Stemcell Metadata manipulation (funktioniert aber hacky)
- Akzeptieren: BOSH Tests nur lokal, nicht in CI

---

**Letzte Aktualisierung:** 2026-07-31 (KVM gescheitert, QEMU Alternative erstellt)  
**Branch (KVM):** `feature/bats-with-bosh-director` - ❌ Nicht funktionsfähig  
**Branch (QEMU):** `feature/bosh-qemu-test` - 🔄 In Testing  
**Status:** Phase 1 - Blockiert durch KVM Problem, QEMU Workaround wird getestet
