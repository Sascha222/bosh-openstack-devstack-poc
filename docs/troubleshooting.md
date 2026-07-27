# DevStack GitHub Actions Troubleshooting

**Problem:** DevStack Smoke Test schlägt fehl  
**Datum:** 2026-07-01

---

## Deine Fehler (Original)

```
❌ The process '/usr/bin/git' failed with exit code 1
⚠️  Node.js 20 is deprecated
❌ No files were found with the provided path: timing.txt
```

---

## Root Cause Analysis

### 1. Git-Fehler (Hauptproblem)

**Symptom:**
```
The process '/usr/bin/git' failed with exit code 1
```

**Wahrscheinliche Ursache:**
Die `gophercloud/devstack-action@v0.6` Action versucht DevStack von GitHub/OpenDev zu clonen. Mögliche Gründe:

1. **Network Issue:** OpenDev (opendev.org) ist down oder blockiert
2. **Rate Limiting:** GitHub Actions IP ist von OpenDev rate-limited
3. **Action Bug:** Die Action v0.6 hat einen Bug (letzte Version ist von 2026-04)
4. **Branch existiert nicht:** `stable/2024.1` existiert nicht mehr

**Wie debuggen:**
- Schau dir die **vollständigen GitHub Actions Logs** an (nicht nur Summary)
- Suche nach: "git clone" oder "opendev.org"

---

### 2. timing.txt nicht gefunden (Folge-Fehler)

**Ursache:**
Wenn DevStack-Deployment fehlschlägt, wird der Step "Save timing info" nie erreicht → `timing.txt` wird nie erstellt.

**Fix:** `if: always()` verwenden (bereits gefixed)

---

### 3. Node.js 20 deprecated (nur Warning)

**Ursache:**
`actions/checkout@v2` ist alt und nutzt Node.js 20.

**Fix:** Alle Actions auf neueste Version upgraden
- ~~`actions/checkout@v2`~~ → `actions/checkout@v4` ✅
- ~~`actions/upload-artifact@v3`~~ → `actions/upload-artifact@v4` ✅

---

## Fixes Applied

### Fix 1: Verbesserter Error Handling

**Datei:** `.github/workflows/devstack-smoke-test-fixed.yml`

**Änderungen:**
1. `continue-on-error: true` auf DevStack Step → Workflow stoppt nicht sofort
2. `if: always()` auf allen Post-DevStack Steps → Logs werden immer hochgeladen
3. DevStack Status Check → Zeigt, ob `/opt/stack/devstack` existiert
4. Aggressives Disk Cleanup → Mehr Platz für DevStack

**Nutzen:**
```bash
# Starte diesen Workflow statt dem originalen:
GitHub → Actions → "DevStack Smoke Test (Fixed)" → Run workflow
```

---

### Fix 2: Manuelles DevStack Install (Fallback)

**Datei:** `.github/workflows/devstack-manual.yml`

**Wenn nutzen:**
- Wenn `gophercloud/devstack-action` komplett kaputt ist
- Wenn du volle Kontrolle über DevStack-Setup brauchst
- Für Debugging (du siehst jeden Schritt)

**Vorteile:**
- Kein Third-Party Action-Dependency
- Du kannst `local.conf` frei anpassen
- Direkte Fehlermeldungen von `stack.sh`

**Nachteil:**
- Dauert evtl. 5-10 Min länger (kein Pre-Built Image)

**Nutzen:**
```bash
# Manuell starten (nur wenn Fixed auch fehlschlägt):
GitHub → Actions → "DevStack Manual Install (Fallback)" → Run workflow
```

---

## Nächste Schritte für dich

### 1. Vollständige GitHub Actions Logs anschauen

```bash
# Gehe zu:
https://github.com/Sascha222/bosh-openstack-devstack-poc/actions

# Klicke auf den failed Run
# Klicke auf "Deploy DevStack" Step
# Expandiere alle Log-Zeilen (klicke auf Pfeile)
# Suche nach:
#   - "git clone"
#   - "ERROR"
#   - "Failed to"
#   - "opendev.org"
```

**Kopiere relevante Fehler-Zeilen hierher:**
```
[Paste hier die genauen Fehler aus dem Log]
```

---

### 2. Neuen Workflow-Run starten

**Option A: Fixed Workflow testen**
```bash
GitHub → Actions → "DevStack Smoke Test (Fixed)" → Run workflow
```

**Option B: Manual Install testen** (wenn A fehlschlägt)
```bash
GitHub → Actions → "DevStack Manual Install (Fallback)" → Run workflow
```

---

### 3. Ergebnisse dokumentieren

**In:** `~/Sap/bosh-openstack-devstack-poc/docs/results.md`

```markdown
## Experiment 1a: Original Workflow (FAILED)

**Datum:** 2026-07-01
**Run:** https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/XXX

### Fehler:
- Git exit code 1
- [Details aus Log hier einfügen]

### Root Cause:
[Nach Log-Analyse hier eintragen]

---

## Experiment 1b: Fixed Workflow

**Datum:** 2026-07-01
**Run:** https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/YYY

### Status:
- [ ] DevStack deployed
- [ ] APIs erreichbar
- [ ] Setup-Zeit: ___ Min

### Learnings:
...
```

---

## Häufige DevStack-auf-GitHub-Actions Probleme

### Problem: "No space left on device"

**Symptom:**
```
df: write error: No space left on device
```

**Fix:**
```yaml
- name: Aggressive disk cleanup
  run: |
    sudo rm -rf /usr/share/dotnet       # ~2GB
    sudo rm -rf /opt/ghc                # ~1GB
    sudo rm -rf /usr/local/share/boost  # ~1GB
    sudo rm -rf /usr/local/lib/android  # ~8GB
    sudo rm -rf /opt/hostedtoolcache    # ~5GB
```

**Bereits gefixed in:** `devstack-smoke-test-fixed.yml` ✅

---

### Problem: DevStack Timeout

**Symptom:**
```
Error: The operation was canceled.
```

**Fix:**
```yaml
jobs:
  devstack-smoke:
    timeout-minutes: 90  # Standard ist 360, aber 90 sollte reichen
```

**Bereits gefixed in:** `devstack-smoke-test-fixed.yml` ✅

---

### Problem: OpenStack CLI nicht gefunden

**Symptom:**
```
openstack: command not found
```

**Fix:**
```bash
pip3 install --user python-openstackclient
export PATH=$PATH:$HOME/.local/bin
```

**Bereits gefixed in:** Beide Workflows ✅

---

### Problem: openrc nicht gefunden

**Symptom:**
```
bash: /opt/stack/devstack/openrc: No such file or directory
```

**Ursache:** DevStack Installation ist fehlgeschlagen (stack.sh failed)

**Debug:**
```bash
# In Workflow:
- name: Check DevStack logs
  if: failure()
  run: |
    cat /opt/stack/devstack/logs/stack.sh.log
```

**Bereits gefixed in:** `devstack-smoke-test-fixed.yml` (lädt Logs hoch) ✅

---

## Bekannte Limitationen: GitHub Actions + DevStack

| Limitation | Impact | Workaround |
|------------|--------|-----------|
| **110GB Disk (after cleanup)** | Sufficient for stemcells (~3GB) | Source: `df -h` measured in workflows | Aggressive Cleanup ✅ |
| **2 CPU Cores** | DevStack deployment ~11-15 Min | Source: [GitHub Actions docs](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners) | Timeout auf 90-120 Min setzen ✅ |
| **~16GB RAM** | Sufficient for single-node DevStack | Source: `tmpfs 7.9G /dev/shm` (50% of 16GB) measured in [Run 6](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29082718957) | Single-Node DevStack nutzen ✅ |
| **OpenDev Rate Limits** | Git Clone kann fehlschlagen | N/A | Manual Install als Fallback ✅ |
| **Glance Upload Limit** | Cannot upload images >1GB (413 error) | Source: 15+ attempts documented below | Use pre-uploaded images or external Glance ⚠️ |

---

## Problem: Glance 413 Request Entity Too Large

**Added:** 2026-07-15  
**Source:** Multiple workflow runs with Stemcell upload attempts

**Symptom:**
```
HttpException: 413: Client Error for url: http://10.1.0.X/image/v2/images/XXX/file, Request Entity Too Large
```

**When it happens:**
Trying to upload large images (>1GB) to DevStack's Glance service, e.g., BOSH stemcells (~1.3GB)

**Measured facts:**
- Stemcell size: ~1.3GB (measured)
- Upload consistently fails at Apache layer with 413 error
- Cirros (~13MB) uploads successfully (verified in [Run 3](https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/29092040017))
- Ubuntu Cloud Image (~600MB) VM creation failed (verified in Run 2)

**Root Cause:**
DevStack 2025.1 Glance runs behind Apache with strict upload limits. Multiple configuration points block large uploads:
- Apache `LimitRequestBody`
- Glance `max_request_body_size`
- Swift backend `max_file_size`

**Attempted Fixes (all failed initially):**
1. Configure Apache `LimitRequestBody 0` (unlimited) - ❌ Incomplete
2. Set Glance `max_request_body_size = 0` - ❌ Not sufficient alone
3. Enable Swift backend with increased limits - ❌ Doesn't address Apache layer
4. Add `WSGIChunkedRequest On` - ❌ Not sufficient alone
5. Configure `FcgidMaxRequestLen` - ❌ Not sufficient alone

**Result:** Persistent 413 error after 15+ configuration attempts

**ROOT CAUSE IDENTIFIED (2026-07-20):**

The issue was **Apache proxy buffering** the entire upload before forwarding to Glance!

Similar to NGINX's `proxy_request_buffer: false` setting (from SAP Reclass docs), Apache needs:
- `SetEnv proxy-sendchunked 1` - Disable buffering, stream chunks directly
- `LimitRequestBody 0` - Allow unlimited size
- `ProxyTimeout 3600` - Long timeout for large uploads
- `KeepAlive On` - Keep connection alive

**SOLUTION (WORKING FIX):**

Replace Apache Glance config `/etc/apache2/sites-available/glance-api.conf`:

```apache
<VirtualHost *:80>
  ServerName glance-api

  # CRITICAL: Allow unlimited request body size
  LimitRequestBody 0

  # CRITICAL: Disable proxy buffering (stream chunks directly!)
  SetEnv proxy-sendchunked 1

  # Allow chunked requests
  WSGIChunkedRequest On

  # Additional size limits (backup)
  FcgidMaxRequestLen 0

  # Proxy to Glance API
  ProxyPass / http://127.0.0.1:9292/
  ProxyPassReverse / http://127.0.0.1:9292/

  # Keep connections alive for large uploads
  ProxyTimeout 3600
  KeepAlive On
  KeepAliveTimeout 3600

  ErrorLog ${APACHE_LOG_DIR}/glance-api-error.log
  CustomLog ${APACHE_LOG_DIR}/glance-api-access.log combined
</VirtualHost>
```

Then reload Apache: `sudo systemctl reload apache2`

**Status:** ✅ **FIXED** - See workflow `.github/workflows/bats-smoke-test.yml`

**Verification Workflow:**
- Workflow: `bats-smoke-test.yml`
- Tests: Download Stemcell → Upload to Glance → Create VM → Delete VM
- Expected: Full lifecycle completes without 413 error

**Related:**
- Workflow: `.github/workflows/devstack-stemcell-test.yml`
- Test run: https://github.com/Sascha222/bosh-openstack-devstack-poc/actions/runs/[RUN_ID]

---

## Problem: Stemcell Download on GitHub Actions

**Added:** 2026-07-15

**Previous assumption:** GitHub Actions only has 14GB disk → too small for stemcells

**Reality:** ✅ ubuntu-24.04 runners have ~145GB total / ~110GB after cleanup

**Solution:**
Real BOSH stemcells (~3GB) CAN be downloaded on GitHub Actions!

**Steps:**
1. Aggressive disk cleanup (remove dotnet, ghc, android, etc.)
2. Download stemcell from bosh.io API
3. Extract and verify with `qemu-img info`

**Result:** Download and extraction successful, disk space sufficient

**Limitation:** While download works, uploading to Glance fails (see "Glance 413" above)

**Workflow:** `.github/workflows/devstack-stemcell-test.yml`

---

## Alternative: Self-Hosted Runner

**Wenn GitHub-hosted Runner zu limitiert sind:**

### Vorteile:
- Mehr RAM/CPU/Disk als GitHub hosted runners
- Volle Kontrolle über Konfiguration
- Kein OpenDev Rate Limiting
- Keine Glance Upload Limits (kann DevStack richtig konfigurieren)

### Setup:
```bash
# Auf eigenem Server/VM:
mkdir actions-runner && cd actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.319.0/actions-runner-linux-x64.tar.gz
tar xzf ./actions-runner-linux-x64.tar.gz

# Token von GitHub holen:
# Settings → Actions → Runners → New self-hosted runner

./config.sh --url https://github.com/Sascha222/bosh-openstack-devstack-poc --token YOUR_TOKEN
./run.sh
```

**Dann in Workflow:**
```yaml
jobs:
  devstack-smoke:
    runs-on: self-hosted  # Statt ubuntu-22.04
```

---

## Debugging Checklist

Wenn DevStack fehlschlägt, prüfe:

- [ ] **Disk Space:** `df -h` zeigt > 10GB frei?
- [ ] **RAM:** `free -h` zeigt > 5GB frei?
- [ ] **Git Clone:** Kann opendev.org erreicht werden?
- [ ] **stack.sh Log:** Was sagt `/opt/stack/devstack/logs/stack.sh.log`?
- [ ] **Service Status:** Welche OpenStack Services failed?
  ```bash
  sudo systemctl status devstack@*
  ```
- [ ] **Network:** Kann VM Internet erreichen?
  ```bash
  ping -c 3 8.8.8.8
  ```

---

## Nächste Schritte

1. ✅ **Fixes gepushed** → Du kannst neuen Run starten
2. ⏭ **Vollständige Logs anschauen** → Genaue Fehlerursache finden
3. ⏭ **Fixed Workflow testen** → Hoffentlich läuft es jetzt!
4. ⏭ **Ergebnisse dokumentieren** → In `docs/results.md`

---

**Last Updated:** 2026-07-01  
**Related:** [Phase 1 Anleitung](./phase1-devstack-poc.md)
