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
**Status:** In Entwicklung

**Ziele:**
- [x] DevStack Deployment
- [x] BOSH CLI Installation
- [x] BOSH Director Deployment
- [ ] Stemcell Upload via BOSH CPI testen
- [ ] VM Lifecycle testen
- [ ] Stabilität validieren

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

## 🚨 Für zukünftige AI-Assistenten

### Wenn du dieses Projekt übernimmst:

**Lies ZUERST:**
1. ✅ Dieses Dokument (PROJECT-OVERVIEW.md)
2. ✅ `docs/bosh-director-lifecycle-test-explained.md`

**Frage IMMER:**
- "Was ist das EIGENTLICHE Ziel?" (Nicht: "Was steht im Code?")
- "Wird das für BATS gebraucht?" (Nicht: "Funktioniert das?")
- "Nutzt das den BOSH CPI?" (Nicht: "Lädt es Stemcells hoch?")

**Vermeide:**
- ❌ Filesystem-Workarounds (nicht BATS-relevant!)
- ❌ Direkte OpenStack API Calls (BOSH CPI muss es machen!)
- ❌ Swift in DevStack fixen (akzeptiere Filesystem Backend!)

**Fokus:**
- ✅ BOSH Director muss laufen
- ✅ BOSH CPI muss Upload machen
- ✅ Standard Glance HTTP API nutzen
- ✅ Bereite BATS vor (nicht: "teste Stemcells")

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

---

## 🎯 TL;DR (Too Long, Didn't Read)

**Ziel:**
BATS Tests in GitHub Actions laufen lassen

**Aktueller Stand:**
Feature Branch mit BOSH Director + Stemcell Lifecycle (Phase 1)

**Nächster Schritt:**
Test laufen lassen, dann BATS hinzufügen (Phase 3)

**Wichtigste Regel:**
Der **BOSH CPI** muss den Upload machen, nicht wir direkt!

**DevStack Limitation:**
Filesystem Backend statt Swift (ist OK für BATS!)

---

**Letzte Aktualisierung:** 2026-07-28  
**Branch:** `feature/bats-with-bosh-director`  
**Status:** Phase 1 in Entwicklung
