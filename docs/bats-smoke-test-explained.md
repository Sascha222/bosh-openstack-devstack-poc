# BATS Smoke Test - Code Walkthrough

**Ziel:** Verstehen wie der BATS Smoke Test funktioniert, insbesondere der Stemcell-Upload und die VM-Erstellung.

**Kontext:** Dieser Test versucht ein 1.3GB BOSH Stemcell in DevStack Glance hochzuladen und eine VM daraus zu erstellen. Das ist komplex wegen der Größe und DevStack-Limitierungen.

---

## Übersicht: Test-Flow

```
1. DevStack Installation
   ↓
2. Apache Glance Config Fix (für große Uploads)
   ↓
3. Stemcell Download (~1.3GB von bosh.io)
   ↓
4. Stemcell Upload zu Glance (FILESYSTEM-WORKAROUND!)
   ↓
5. Nova Config Fix (direkter Port, kein Apache)
   ↓
6. VM Creation vom Stemcell
   ↓
7. VM Cleanup
```

---

## Step-by-Step Erklärung

### 1. DevStack Installation

```yaml
- name: Deploy DevStack
  uses: gophercloud/devstack-action@v0.19
  with:
    branch: stable/2025.1
    conf_overrides: |
      [[local|localrc]]
      ENABLED_SERVICES=mysql,rabbit,key,n-api,n-cpu,n-cond,n-sch,placement-api,g-api,g-reg,c-sch,c-api,c-vol,q-svc,ovn-controller,ovn-northd,q-ovn-metadata-agent
      GLANCE_LIMIT_IMAGE_SIZE_TOTAL=0
      enable_plugin neutron https://opendev.org/openstack/neutron stable/2025.1
```

**Was passiert:**
- DevStack wird installiert (OpenStack Development Environment)
- Wichtige Services:
  - `g-api` = Glance API (Image Service)
  - `n-api`, `n-cpu`, `n-cond`, `n-sch` = Nova (Compute)
  - `key` = Keystone (Identity/Auth)
  - `placement-api` = Placement (Resource Tracking)
- `GLANCE_LIMIT_IMAGE_SIZE_TOTAL=0` = Keine Größenbeschränkung für Images

**Wichtig:** DevStack läuft Apache als Reverse Proxy vor Glance auf Port 80.

---

### 2. Apache Glance Config Fix

```yaml
- name: Fix Apache Glance Config for Large Uploads (THE FIX!)
  run: |
    APACHE_GLANCE_CONF="/etc/apache2/sites-available/glance-api.conf"
    
    # Check if config exists
    if [ ! -f "$APACHE_GLANCE_CONF" ]; then
      echo "ERROR: Apache Glance config not found!"
      exit 1
    fi
    
    # Create the FIXED config
    sudo tee "$APACHE_GLANCE_CONF" > /dev/null <<'EOF'
<VirtualHost *:80>
  ServerName glance-api

  # CRITICAL: Allow unlimited request body size
  LimitRequestBody 0

  # CRITICAL: Disable proxy buffering - stream chunks directly!
  SetEnv proxy-sendchunked 1

  # Allow chunked transfer encoding
  WSGIChunkedRequest On

  # Proxy to Glance (dynamic port detection later)
  ProxyPass / http://127.0.0.1:9292/
  ProxyPassReverse / http://127.0.0.1:9292/

  # Long timeout for large uploads
  ProxyTimeout 3600
  KeepAlive On
  KeepAliveTimeout 3600

  ErrorLog ${APACHE_LOG_DIR}/glance-api-error.log
  CustomLog ${APACHE_LOG_DIR}/glance-api-access.log combined
</VirtualHost>
EOF
    
    # Reload Apache
    sudo apache2ctl configtest
    sudo systemctl reload apache2
```

**Warum ist das wichtig?**

Apache buffert standardmäßig den **gesamten Upload** bevor er zu Glance weitergeleitet wird. Bei 1.3GB führt das zu:
- Memory-Problemen
- Disk-Space-Problemen
- HTTP 413 "Request Entity Too Large" Errors

**Die kritischen Settings:**

1. **`LimitRequestBody 0`**
   - Erlaubt unbegrenzte Upload-Größe
   - Standard: oft 100MB-1GB

2. **`SetEnv proxy-sendchunked 1`** ⭐ **MOST IMPORTANT!**
   - Deaktiviert Apache's Request-Buffering
   - Streamt Chunks direkt zu Glance
   - Äquivalent zu NGINX's `proxy_request_buffering off`

3. **`WSGIChunkedRequest On`**
   - Erlaubt chunked transfer encoding
   - Notwendig für Streaming

4. **`ProxyTimeout 3600`**
   - 1-Stunden Timeout für lange Uploads

**Ohne diese Config:** Apache buffert 1.3GB → Out of Memory → Upload scheitert

**Mit dieser Config:** Apache streamt Chunks → kein Buffering → Upload funktioniert

---

### 3. Stemcell Download

```yaml
- name: Download BOSH Stemcell
  run: |
    echo "Downloading BOSH Ubuntu Jammy Stemcell..."
    STEMCELL_VERSION="1.1298"
    
    # Try bosh.io API first
    STEMCELL_URL=$(curl -s "https://bosh.io/api/v1/stemcells/bosh-openstack-kvm-ubuntu-jammy-go_agent" | \
      jq -r ".[0].regular.url" || echo "")
    
    # Fallback to direct Google Storage URL
    if [ -z "$STEMCELL_URL" ] || [ "$STEMCELL_URL" = "null" ]; then
      STEMCELL_URL="https://storage.googleapis.com/bosh-core-stemcells/${STEMCELL_VERSION}/bosh-stemcell-${STEMCELL_VERSION}-openstack-kvm-ubuntu-jammy-go_agent.tgz"
    fi
    
    curl -L -o stemcell.tgz "$STEMCELL_URL"
    tar -xzf stemcell.tgz image
    
    IMAGE_SIZE=$(stat -c%s image)
    echo "Downloaded stemcell: ${IMAGE_SIZE} bytes (~$((IMAGE_SIZE / 1024 / 1024))MB)"
```

**Was passiert:**
1. Versucht von bosh.io API die URL zu holen
2. Fallback zu direkter Google Storage URL
3. Download der `.tgz` Datei
4. Extrahiert `image` (qcow2 disk image) aus dem Tarball

**Dateigröße:** ~1.3GB (1,290MB)

---

### 4. Stemcell Upload zu Glance (FILESYSTEM-WORKAROUND!)

**DAS IST DER KOMPLEXESTE TEIL!** ⭐

```yaml
- name: Upload Stemcell to Glance
  run: |
    echo "=========================================="
    echo "  STEP 3: Upload Stemcell to Glance"
    echo "=========================================="
    
    # Get Glance endpoint and auth token
    source ./devstack/openrc admin admin
    GLANCE_ENDPOINT=$(openstack catalog show glance -f value -c endpoints | grep public | awk '{print $2}')
    AUTH_TOKEN=$(openstack token issue -f value -c id)
    
    # Detect actual Glance port (NOT the Apache port!)
    GLANCE_PORT=$(sudo ss -tlnp | grep -E "glance|uwsgi" | grep -oP '127\.0\.0\.1:\K[0-9]+' | head -1)
    DIRECT_GLANCE_URL="http://127.0.0.1:${GLANCE_PORT}"
    
    echo "Direct Glance URL: $DIRECT_GLANCE_URL"
    
    # Step 1: Create image metadata
    IMAGE_ID=$(curl -s -X POST "$DIRECT_GLANCE_URL/v2/images" \
      -H "X-Auth-Token: $AUTH_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{
        "name": "bosh-stemcell-1.1298-test",
        "disk_format": "qcow2",
        "container_format": "bare",
        "visibility": "public"
      }' | jq -r '.id')
    
    echo "✅ Image created with ID: $IMAGE_ID"
    
    # Step 2: Copy to filesystem (WORKAROUND!)
    echo "Step 2: Importing image via filesystem (bypass upload entirely)..."
    
    GLANCE_STORE="/opt/stack/data/glance/images/"
    TARGET_FILE="${GLANCE_STORE}${IMAGE_ID}"
    
    sudo cp image "$TARGET_FILE"
    sudo chown stack:stack "$TARGET_FILE"
    
    IMAGE_SIZE=$(stat -c%s "$TARGET_FILE")
    IMAGE_CHECKSUM=$(md5sum "$TARGET_FILE" | cut -d' ' -f1)
    
    echo "✅ File copied to Glance store"
    echo "Image size: $IMAGE_SIZE bytes"
    echo "Image checksum: $IMAGE_CHECKSUM"
    
    # Step 3: Update database directly
    echo "Forcing image activation via database update..."
    
    sudo mysql --defaults-file=/etc/mysql/debian.cnf glance <<SQL
      UPDATE images 
      SET status='active', size=${IMAGE_SIZE}, checksum='${IMAGE_CHECKSUM}' 
      WHERE id='${IMAGE_ID}';
      
      INSERT INTO image_locations (image_id, value, meta_data, status, deleted, created_at, updated_at)
      VALUES (
        '${IMAGE_ID}',
        '{"url": "file://${TARGET_FILE}", "metadata": {}}',
        '{}',
        'active',
        0,
        NOW(),
        NOW()
      );
SQL
    
    echo "✅ Database updated successfully"
```

**Warum dieser komplexe Workaround?**

**Problem:** Glance hat Probleme mit HTTP-Uploads von großen Images (~1GB+):
- Connection Reset
- Timeouts
- Memory-Probleme

**Lösung:** Filesystem-Import
1. Erstelle Image-Metadata via API → erhält Image-ID
2. Kopiere Datei **direkt** in Glance's Filesystem (`/opt/stack/data/glance/images/`)
3. Update Datenbank mit:
   - `status = 'active'`
   - `size` und `checksum`
   - `image_locations` mit `file://` URL

**Wichtig:** Das funktioniert nur in DevStack (Development)! Production nutzt Swift/Ceph.

---

### ❌ Wo `upload_stemcell.py` NICHT verwendet wird

**Wichtig:** Das Python-Script `upload_stemcell.py` wird **NICHT** im aktuellen Workflow verwendet!

Schauen wir uns trotzdem an was es tut (für Verständnis):

```python
#!/usr/bin/env python3
"""
Upload BOSH stemcell to Glance with chunked streaming.
Avoids curl's out-of-memory issues with large files.
"""
import sys
import os
import requests

def upload_stemcell(glance_endpoint, auth_token, image_id, image_path):
    """Upload stemcell image to Glance with streaming."""
    
    url = f"{glance_endpoint}/v2/images/{image_id}/file"
    
    file_size = os.path.getsize(image_path)
    file_size_mb = file_size / (1024 * 1024)
    
    # CRITICAL: Glance REQUIRES Content-Length for large uploads!
    # Without it, chunked transfer causes "Connection reset by peer"
    headers = {
        'X-Auth-Token': auth_token,
        'Content-Length': str(file_size),  # MUST be set!
        # No Content-Type - let Glance auto-detect
    }
    
    print(f"Uploading {image_path}")
    print(f"File size: {file_size_mb:.2f} MB")
    print(f"Upload URL: {url}")
    print(f"Headers: {headers}")
    print("")
    
    # Open file in binary read mode
    with open(image_path, 'rb') as f:
        # Read entire file into memory (GitHub Actions has enough RAM)
        print("Reading file into memory...")
        file_data = f.read()
        print(f"File loaded: {len(file_data)} bytes")
        
        # Upload with Content-Length (no streaming, no chunking)
        print("Starting direct upload with Content-Length header...")
        
        try:
            response = requests.put(
                url,
                headers=headers,
                data=file_data,  # Send entire file at once
                timeout=1800  # 30 minute timeout for 1.3GB
            )
            
            print(f"\nHTTP Response Code: {response.status_code}")
            
            if response.status_code in [200, 204]:
                print("✅ Upload successful!")
                return 0
            else:
                print(f"❌ Upload failed!")
                print(f"Response Headers: {dict(response.headers)}")
                print(f"Response Body: {response.text}")
                
                # If still 415, try WITH Content-Type as last resort
                if response.status_code == 415:
                    print("\n⚠️ Got 415 without Content-Type header")
                    print("Retrying WITH Content-Type: application/octet-stream...")
                    
                    f.seek(0)  # Reset file pointer
                    headers['Content-Type'] = 'application/octet-stream'
                    
                    response2 = requests.put(
                        url,
                        headers=headers,
                        data=f,
                        timeout=600
                    )
                    
                    print(f"Retry HTTP Response Code: {response2.status_code}")
                    
                    if response2.status_code in [200, 204]:
                        print("✅ Upload successful on retry!")
                        return 0
                    else:
                        print(f"❌ Retry also failed: {response2.text}")
                
                return 1
                
        except requests.exceptions.Timeout:
            print("❌ Upload timed out after 30 minutes")
            return 1
        except requests.exceptions.ConnectionError as e:
            print(f"❌ Connection error: {e}")
            return 1
        except Exception as e:
            print(f"❌ Unexpected error: {e}")
            return 1
```

**Was macht dieses Script:**

1. **Lädt die gesamte Datei in den Speicher**
   ```python
   file_data = f.read()  # ~1.3GB RAM!
   ```
   - GitHub Actions Runner haben genug RAM (7GB)
   - Vermeidet chunked transfer encoding

2. **Setzt Content-Length Header explizit**
   ```python
   headers = {
       'X-Auth-Token': auth_token,
       'Content-Length': str(file_size),  # Kritisch!
   }
   ```
   - Ohne diesen Header würde requests chunked encoding nutzen
   - Chunked encoding → Connection Reset bei Glance

3. **Sendet einen einzigen PUT Request**
   ```python
   response = requests.put(url, headers=headers, data=file_data, timeout=1800)
   ```
   - Kein Streaming
   - Eine große Payload

**Warum wird es NICHT verwendet?**

Es hatte **trotzdem** Connection-Reset-Probleme! Glance/Eventlet kann anscheinend große HTTP-Body-Daten nicht zuverlässig verarbeiten, selbst mit Content-Length.

**Daher:** Filesystem-Workaround ist die einzige zuverlässige Methode.

---

### 5. Nova Config Fix (Bypass Apache)

```yaml
- name: Configure Nova to bypass Apache proxy
  run: |
    NOVA_CONF="/etc/nova/nova.conf"
    
    # Get actual Glance port (not Apache port 80!)
    GLANCE_PORT=$(sudo ss -tlnp | grep -E "glance|uwsgi" | grep -oP '127\.0\.0\.1:\K[0-9]+' | head -1)
    
    echo "Glance API Port (actual): $GLANCE_PORT"
    
    # STEP 1: Update Keystone endpoint FIRST
    source ./devstack/openrc admin admin
    
    PUBLIC_ENDPOINT_ID=$(openstack endpoint list --service glance --interface public -f value -c ID)
    openstack endpoint set --url "http://127.0.0.1:${GLANCE_PORT}" "$PUBLIC_ENDPOINT_ID"
    
    echo "✅ Keystone public endpoint updated to http://127.0.0.1:${GLANCE_PORT}"
    
    # STEP 2: Configure Glance timeouts for large downloads
    sudo crudini --set "$GLANCE_CONF" DEFAULT client_socket_timeout 3600
    sudo crudini --set "$GLANCE_CONF" DEFAULT send_timeout 3600
    
    sudo systemctl restart devstack@g-api.service
    sleep 5
    
    echo "✅ Glance restarted with 1-hour timeouts"
    
    # STEP 3: Update nova.conf
    sudo crudini --set "$NOVA_CONF" glance api_servers "http://127.0.0.1:${GLANCE_PORT}"
    sudo crudini --set "$NOVA_CONF" glance endpoint_override "http://127.0.0.1:${GLANCE_PORT}"
    sudo crudini --set "$NOVA_CONF" glance valid_interfaces "internal,public"
    
    # STEP 4: Verify Glance is accessible
    if ! curl -s -f -o /dev/null "http://127.0.0.1:${GLANCE_PORT}/"; then
      echo "❌ Glance is NOT accessible!"
      exit 1
    fi
    
    echo "✅ Glance is accessible"
    
    # STEP 5: Restart Nova services
    for service in n-api n-cpu n-cond n-sch; do
      sudo systemctl restart "devstack@${service}.service"
    done
    
    sleep 10
    
    echo "✅ Nova restarted with direct Glance endpoint"
```

**Warum ist das nötig?**

**Problem:** Nova würde standardmäßig über Apache (Port 80) zu Glance gehen:
- `openstack endpoint list --service glance` zeigt: `http://10.1.0.112/image`
- Das ist Apache auf Port 80
- Apache → Glance Proxy

**Für Downloads:** Apache hat auch Probleme mit großen Downloads (wie beim Upload):
- HTTP 502 Proxy Error
- Connection aborted

**Lösung:** Nova soll **direkt** zu Glance gehen:

1. **Keystone Endpoint ändern:**
   ```bash
   http://10.1.0.112/image  →  http://127.0.0.1:60999
   ```
   DevStack erstellt nur einen `public` Endpoint, keinen `internal`.

2. **Glance Timeouts erhöhen:**
   ```ini
   [DEFAULT]
   client_socket_timeout = 3600  # 1 Stunde
   send_timeout = 3600           # 1 Stunde
   ```
   Damit Glance nicht nach 60s die Verbindung schließt beim 1.3GB Download.

3. **nova.conf konfigurieren:**
   ```ini
   [glance]
   api_servers = http://127.0.0.1:60999
   endpoint_override = http://127.0.0.1:60999
   valid_interfaces = internal,public
   ```
   - `api_servers`: Direkte URL
   - `endpoint_override`: Überschreibt Keystone Service Catalog
   - `valid_interfaces`: Sucht zuerst internal, dann public

4. **Services neu starten:**
   - Glance neu starten → Timeouts aktiv
   - Nova neu starten → Liest neue Config

**Wichtig:** Die Reihenfolge ist kritisch!
1. Keystone Endpoint ändern
2. Glance Config + Restart
3. Nova Config
4. Nova Restart

Wenn Nova vor dem Keystone-Update startet, cached es den alten Apache-Endpoint!

---

### 6. VM Creation vom Stemcell

```yaml
- name: Create test VM from stemcell
  run: |
    source ./devstack/openrc admin admin
    
    IMAGE_ID=$(openstack image list --name "bosh-stemcell-1.1298-test" -f value -c ID)
    NETWORK_ID=$(openstack network list --name private -f value -c ID)
    
    openstack server create \
      --image "$IMAGE_ID" \
      --flavor m1.small \
      --network "$NETWORK_ID" \
      bosh-stemcell-test-vm
    
    # Wait for ACTIVE or ERROR
    for i in {1..60}; do
      STATUS=$(openstack server show bosh-stemcell-test-vm -f value -c status)
      echo "Attempt $i/60: VM status = $STATUS"
      
      if [ "$STATUS" = "ACTIVE" ]; then
        echo "✅ VM is ACTIVE!"
        break
      elif [ "$STATUS" = "ERROR" ]; then
        echo "❌ VM went to ERROR state!"
        openstack server show bosh-stemcell-test-vm
        exit 1
      fi
      
      sleep 5
    done
```

**Was passiert:**

1. **VM erstellen:**
   ```bash
   openstack server create \
     --image <stemcell-id> \
     --flavor m1.small \
     --network private \
     bosh-stemcell-test-vm
   ```

2. **Unter der Haube (Nova):**
   - Nova Scheduler wählt Host aus
   - Nova Compute auf dem Host:
     1. Kontaktiert Glance: "Gib mir Image XYZ"
     2. **Download:** `GET http://127.0.0.1:60999/v2/images/{id}/file`
     3. Glance streamt 1.3GB über HTTP
     4. Nova speichert als `/var/lib/nova/instances/_base/{id}`
     5. Erstellt COW (Copy-on-Write) Disk für VM
     6. Startet VM via libvirt/KVM

3. **Download dauert ~2-3 Minuten** (1.3GB @ ~10MB/s)
   - Mit 1-Stunden-Timeout: kein Problem
   - Ohne Timeout: würde nach 60s abbrechen

4. **Polling:**
   - Alle 5 Sekunden: Status abfragen
   - `BUILD` → `ACTIVE` = Erfolg ✅
   - `BUILD` → `ERROR` = Fehler ❌

---

## Zusammenfassung: Warum ist das so komplex?

### Problem 1: Apache kann große Uploads nicht handhaben
- **Symptom:** HTTP 413 oder Connection Reset
- **Ursache:** Apache buffert gesamten Upload
- **Lösung:** `SetEnv proxy-sendchunked 1` (Streaming statt Buffering)

### Problem 2: Glance HTTP-Upload ist instabil für große Files
- **Symptom:** Connection Reset trotz Apache-Fix
- **Ursache:** Glance/Eventlet Probleme mit ~1GB+ HTTP-Body
- **Lösung:** Filesystem-Workaround (direktes Kopieren)

### Problem 3: Nova würde über Apache downloaden
- **Symptom:** HTTP 502 Proxy Error beim VM-Create
- **Ursache:** Keystone Endpoint zeigt auf Apache Port 80
- **Lösung:** Endpoint auf direkten Glance-Port ändern

### Problem 4: Glance schließt Verbindung bei langem Download
- **Symptom:** RemoteDisconnected nach ~60s
- **Ursache:** Default Socket-Timeout zu kurz
- **Lösung:** `client_socket_timeout = 3600` (1 Stunde)

---

## Architektur-Diagramm

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub Actions                       │
│                                                         │
│  1. DevStack installiert                               │
│  2. Apache Config gefixt                               │
│  3. Stemcell (1.3GB) gedownloadet                      │
│  4. Stemcell zu Glance Filesystem kopiert (Workaround)│
│  5. Nova Config: Bypass Apache                         │
│  6. VM Creation                                        │
└─────────────────────────────────────────────────────────┘
                          │
                          │ SSH/DevStack Commands
                          ↓
┌─────────────────────────────────────────────────────────┐
│              DevStack VM (in GitHub Runner)             │
│                                                         │
│  ┌─────────────┐    ┌──────────────┐   ┌───────────┐  │
│  │   Apache    │───→│    Glance    │   │   Nova    │  │
│  │  Port 80    │    │  Port 60999  │   │ Compute   │  │
│  │             │    │              │   │           │  │
│  │ (bypassed   │    │ Filesystem:  │   │ Downloads │  │
│  │  for VM     │    │ /opt/stack/  │   │ Image via │  │
│  │  download)  │    │ data/glance/ │←──│ HTTP API  │  │
│  └─────────────┘    │ images/      │   │           │  │
│                     │              │   │ Timeout:  │  │
│                     │ Timeout:     │   │ Inherits  │  │
│                     │ 3600s (1h)   │   │ from      │  │
│                     └──────────────┘   │ Glance    │  │
│                                        └───────────┘  │
│                                                       │
│  Keystone Endpoint:                                  │
│  http://127.0.0.1:60999 (Direct, not Apache!)       │
└─────────────────────────────────────────────────────────┘
```

---

## Key Takeaways

1. **Apache `SetEnv proxy-sendchunked 1` ist kritisch** für große Uploads (verhindert Buffering)

2. **Filesystem-Workaround** ist die einzige zuverlässige Methode für ~1GB+ in DevStack Glance

3. **Keystone Endpoint** muss auf direkten Glance-Port zeigen, nicht auf Apache

4. **Glance Timeouts** müssen hoch genug sein für lange Downloads (3600s = 1h)

5. **Reihenfolge ist wichtig:**
   - Keystone Endpoint ändern
   - Glance Config + Restart
   - Nova Config
   - Nova Restart

6. **`upload_stemcell.py` wird NICHT verwendet** weil es auch Connection-Resets hatte

7. **Production-Systeme** sollten Swift/Ceph nutzen, nicht file:// Backend

---

## Debugging-Tipps

**Wenn Upload fehlschlägt:**
- Apache Logs: `/var/log/apache2/glance-api-error.log`
- Glance Logs: `journalctl -u devstack@g-api.service`
- Check Apache Config: `LimitRequestBody` und `proxy-sendchunked`

**Wenn VM Creation fehlschlägt:**
- Nova Compute Logs: `journalctl -u devstack@n-cpu.service`
- Check Endpoint: `openstack endpoint list --service glance`
- Check nova.conf: `grep -A 5 "\[glance\]" /etc/nova/nova.conf`
- Check Glance Timeouts: `grep timeout /etc/glance/glance-api.conf`

**Wenn Connection Reset:**
- Glance Timeout zu kurz → erhöhen auf 3600s
- Apache buffering aktiv → `SetEnv proxy-sendchunked 1` prüfen

---

## Referenzen

- Troubleshooting Doc: `docs/bats-smoke-test-troubleshooting-journey.md`
- Apache Fix Doc: `docs/glance-upload-fix.md`
- Workflow File: `.github/workflows/bats-smoke-test.yml`
- Upload Script (unused): `.github/workflows/upload_stemcell.py`
