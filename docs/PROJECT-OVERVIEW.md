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
**Branch:** `feature/bats-with-bosh-director`  
**Status:** 🔧 **Debugging - Glance Config Timing Issue**

**Ziele:**
- [x] DevStack Deployment
- [x] BOSH CLI Installation
- [x] BOSH Director Deployment
- [x] Glance Filesystem Trailing Slash Fix (KRITISCH!)
- [x] Fix: Glance Config Reload Timing (45s wait)
- [ ] Stemcell Upload via BOSH CPI erfolgreich validieren
- [ ] VM Lifecycle erfolgreich testen
- [ ] Stabilität validieren

**Aktuelle Herausforderung (2026-07-28):**
- ✅ Trailing Slash Bug identifiziert und gefixed
- ✅ Timing-Problem erkannt: Glance braucht ~45s für vollständiges Config-Reload
- ⏳ Nächster Test-Run sollte funktionieren

**Dauer:** ~45-60 Min pro Run

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

### 4. Timing und Config-Reload sind kritisch (NEU - 2026-07-28)

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

2. **Swift Backend Issues:**
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

**Aktueller Stand (2026-07-28):**
Feature Branch mit BOSH Director + Stemcell Lifecycle (Phase 1)  
🔧 Debugging: Glance Config Timing Issue - Fix implementiert, nächster Test-Run läuft

**Nächster Schritt:**
Workflow-Run validieren, dann BATS hinzufügen (Phase 3)

**Wichtigste Regeln:**
1. Der **BOSH CPI** muss den Upload machen, nicht wir direkt!
2. Config-Fixes müssen **VOR** BOSH Director Deployment passieren!
3. Services brauchen Zeit für Config-Reload (~45s für Glance)!

**DevStack Limitations:**
- Filesystem Backend statt Swift (ist OK für BATS!)
- Glance trailing slash Bug (wird gefixed mit 45s reload time)

**Kritische Timing-Sequenz:**
```
Fix Glance Config → Restart → Wait 45s (Config-Reload!) → Deploy BOSH → Upload Stemcell
```

---

**Letzte Aktualisierung:** 2026-07-28 (Timing-Fix implementiert)  
**Branch:** `feature/bats-with-bosh-director`  
**Status:** Phase 1 - Debugging Glance Config Timing (Fix committed, testing pending)
