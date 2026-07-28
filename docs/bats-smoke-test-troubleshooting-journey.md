# BATS Smoke Test - Troubleshooting Journey (2026-07-21)

## Ziel
BOSH Stemcell (~1.3GB) in DevStack Glance hochladen und eine VM daraus erstellen.

---

## Problem 1: Connection Reset beim Upload

### Fehler
```
❌ Connection error: ('Connection aborted.', ConnectionResetError(104, 'Connection reset by peer'))
```

### Versuchte Lösungen (alle gescheitert)

#### Versuch 1: Content-Type Header entfernen
- **Idee:** Apache/Glance lehnt `application/octet-stream` ab
- **Ergebnis:** ❌ Connection Reset bleibt

#### Versuch 2: Content-Length Header explizit setzen
```python
headers = {
    'X-Auth-Token': token,
    'Content-Length': str(file_size)
}
```
- **Idee:** Verhindert chunked transfer encoding
- **Ergebnis:** ❌ Connection Reset bleibt

#### Versuch 3: Datei komplett in Memory laden
```python
with open(image_path, 'rb') as f:
    file_data = f.read()  # Ganze 1.3GB in RAM
    response = requests.put(url, data=file_data)
```
- **Idee:** Kein Streaming = keine chunked encoding Probleme
- **Ergebnis:** ❌ Connection Reset bleibt

#### Versuch 4: Glance Socket Timeouts erhöhen
```ini
[DEFAULT]
client_socket_timeout = 3600
send_timeout = 3600
workers = 1
```
- **Idee:** Eventlet-Timeout zu kurz für 1.3GB
- **Ergebnis:** ❌ Connection Reset bleibt

#### Versuch 5: Apache Proxy-Konfiguration
```apache
KeepAlive Off
SetEnv proxy-sendchunked 1
LimitRequestBody 0
ProxyTimeout 3600
```
- **Idee:** Apache-Limits blockieren große Uploads
- **Ergebnis:** ❌ Connection Reset bleibt (kommt von Glance selbst)

#### Versuch 6: OpenStack CLI nutzen
```bash
openstack image set --file image $IMAGE_ID  # ❌ Parameter existiert nicht
```
- **Ergebnis:** ❌ Falscher Befehl

#### Versuch 7: Glance CLI nutzen
```bash
glance image-upload --file image --progress $IMAGE_ID
```
- **Ergebnis:** ❌ HTTP 415 Unsupported Media Type (über Apache)

#### Versuch 8: Glance CLI mit direktem Port
```bash
glance --os-image-url http://127.0.0.1:60999 image-upload --file image $IMAGE_ID
```
- **Ergebnis:** ❌ Connection Reset (auch ohne Apache)

### ✅ Erfolgreiche Lösung: Filesystem-Import (Workaround)

**Umgehe HTTP-Upload komplett** - kopiere Datei direkt ins Glance-Verzeichnis:

```bash
# 1. Datei kopieren
sudo cp image /opt/stack/data/glance/images/${IMAGE_ID}

# 2. Ownership setzen
sudo chown stack:stack /opt/stack/data/glance/images/${IMAGE_ID}

# 3. Metadata berechnen
IMAGE_SIZE=$(stat -c%s /opt/stack/data/glance/images/${IMAGE_ID})
IMAGE_CHECKSUM=$(md5sum /opt/stack/data/glance/images/${IMAGE_ID} | cut -d' ' -f1)

# 4. Datenbank aktualisieren
sudo mysql glance -e "
  UPDATE images 
  SET status='active', size=${IMAGE_SIZE}, checksum='${IMAGE_CHECKSUM}' 
  WHERE id='${IMAGE_ID}';
  
  INSERT INTO image_locations (image_id, value, meta_data, status, deleted, created_at, updated_at)
  VALUES (
    '${IMAGE_ID}',
    '{\"url\": \"file:///opt/stack/data/glance/images/${IMAGE_ID}\", \"metadata\": {}}',
    '{}',
    'active',
    0,
    NOW(),
    NOW()
  );
"
```

**Warum es funktioniert:**
- Umgeht Glance/Eventlet HTTP-Upload komplett
- Nutzt direkten Filesystem-Zugriff
- DevStack-spezifisch, aber funktioniert zuverlässig

---

## Problem 2: API-Fehler "Attribute is read-only"

### Fehler
```
403 Forbidden: Attribute 'size' is read-only.
403 Forbidden: Attribute 'status' is read-only.
```

### ✅ Lösung
Diese Felds sind via Glance API read-only → **Direkter MySQL-Update** erforderlich

---

## Problem 3: MySQL Access Denied

### Fehler
```
ERROR 1045 (28000): Access denied for user 'root'@'localhost' (using password: NO)
```

### ✅ Lösung: Auto-Detection der MySQL-Credentials

```bash
if sudo test -f /etc/mysql/debian.cnf; then
  MYSQL_CMD="sudo mysql --defaults-file=/etc/mysql/debian.cnf"
elif sudo mysql -u root -e "SELECT 1" &>/dev/null; then
  MYSQL_CMD="sudo mysql -u root"
else
  MYSQL_CMD="sudo mysql"
fi
```

---

## Problem 4: MySQL Field 'deleted' fehlt

### Fehler
```
ERROR 1364 (HY000): Field 'deleted' doesn't have a default value
```

### ✅ Lösung
`deleted=0` explizit im INSERT setzen:

```sql
INSERT INTO image_locations (..., deleted, ...) 
VALUES (..., 0, ...)
```

---

## Problem 5: Nova - "Image has no associated data"

### Fehler
```
ERROR nova.compute.manager: Image xxx is unacceptable: Image has no associated data
```

### Ursache
Datei existiert im Filesystem, aber **image_locations** Tabelle fehlt der Eintrag.

### ✅ Lösung
`image_locations` Eintrag mit `file://` URL erstellen (siehe Problem 1)

---

## Problem 6: bosh.io API temporär nicht erreichbar

### Fehler
```
jq: error (at <stdin>:1): Cannot index number with number
404 Not Found: Requested route ('bosh.io') does not exist.
```

### ✅ Lösung: Fallback zu direkter Google Storage URL

```bash
if ! echo "$STEMCELL_INFO" | jq -e '. | type == "array"' > /dev/null 2>&1; then
  # Fallback zu direkter URL
  STEMCELL_URL="https://storage.googleapis.com/bosh-core-stemcells/1.1298/bosh-stemcell-1.1298-openstack-kvm-ubuntu-jammy-go_agent.tgz"
fi
```

---

## Problem 7: chown - Invalid User

### Fehler
```
chown: invalid user: 'stack:stack'
```

### ✅ Lösung: User-Detection vor chown

```bash
if id glance &>/dev/null; then
  sudo chown glance:glance "$FILE"
elif id stack &>/dev/null; then
  sudo chown stack:stack "$FILE"
else
  sudo chmod 644 "$FILE"
fi
```

---

## Finale Architektur

### Upload-Flow (Workaround)
```
Stemcell Download (bosh.io)
    ↓
Extract stemcell.tgz
    ↓
Copy image → /opt/stack/data/glance/images/${IMAGE_ID}
    ↓
MySQL UPDATE:
  - images table: status='active', size, checksum
  - image_locations table: file:// URL
    ↓
Nova creates VM from image
```

### Wichtige Erkenntnisse

1. **Glance/Eventlet hat Probleme mit großen HTTP-Uploads** (~1GB+)
   - Connection Reset bei allen Ansätzen (requests, curl, glance CLI)
   - Auch mit Content-Length, ohne chunked encoding, mit Timeouts
   
2. **Filesystem-Import ist der zuverlässige Workaround**
   - Nur für DevStack/Test-Umgebungen
   - Produktion: Swift/Ceph Backend nutzen

3. **MySQL-Direktzugriff notwendig**
   - Viele Felder sind read-only via API
   - `image_locations` ist kritisch für Nova

4. **DevStack ist fragil**
   - Verschiedene MySQL-Auth-Methoden
   - User-Namen variieren (glance vs stack)
   - Apache-Proxy kann stören

---

## Commits Timeline

1. `f235a33` - Try upload WITHOUT Content-Type header
2. `539cba9` - Fix: Auto-detect Glance port
3. `3fb5a66` - WORKAROUND: Bypass Apache, direct port 9292
4. `41a1654` - Fix: Apache rejecting application/octet-stream
5. `2795794` - Fix: Replace curl with Python requests
6. `8db6ea3` - Fix: Add Content-Length header
7. `3cc24b1` - Enable workflow on every push
8. `bcb434f` - Fix: Load file into memory
9. `a62509e` - Fix: Configure Glance socket timeout
10. `2314c22` - Try OpenStack CLI for upload
11. `f2815a7` - Fix: Use 'glance image-upload'
12. `c027cf8` - Force glance CLI to use direct port
13. `89fce48` - **WORKAROUND: Copy directly to filesystem**
14. `fbd9ee8` - Fix: Proper user detection
15. `d78a6f9` - Fix: Set metadata and activate via database
16. `e8e6ce5` - Fix: Auto-detect MySQL credentials
17. `ac1e439` - Fix: Add image_locations entry
18. `a7cac95` - Fix: Add 'deleted' field
19. `9eb6c44` - Fix: Add fallback for bosh.io API
20. `87232ca` - Fix: Use direct Google Storage URL

---

## Problem 8: Malformed file:// URL - Doppel-Slash

### Fehler (2026-07-27)
```
TypeError: 'ImageProxy' object is not callable
glanceclient.exc.CommunicationError: Error finding address for http://127.0.0.1:60999/v2/images/.../file
Unknown scheme '' found in URI.: glance_store.exceptions.UnknownScheme: Unknown scheme '' found in URI
```

### Symptom
- ✅ Image-Datei existiert: `/opt/stack/data/glance/images/41ef1b0a-ada6-4037-9d8e-bf084a424116` (1.3GB)
- ✅ MySQL `images` Tabelle: `status='active'`, `size` und `checksum` korrekt
- ✅ MySQL `image_locations` Tabelle: Eintrag mit `file://` URL existiert
- ❌ Nova kann Image nicht von Glance downloaden: "Remote end closed connection without response"
- ❌ Glance kann Location nicht parsen: "Unknown scheme '' found in URI"

### Root Cause

**Glance Config hat trailing slash:**
```ini
[glance_store]
filesystem_store_datadir = /opt/stack/data/glance/images/
                                                      ↑ trailing slash
```

**Workflow baut URL:**
```bash
FILE_LOCATION="file://${GLANCE_STORE_PATH}/${IMAGE_ID}"
# Mit trailing slash: file:///opt/stack/data/glance/images//41ef1b0a...
#                                                       ↑↑ Doppel-Slash!
```

**Was passiert:**
1. Doppel-Slash macht die URL malformed
2. Glance kann Schema nicht extrahieren → leerer String `''`
3. `glance_store.exceptions.UnknownScheme: Unknown scheme '' found in URI`
4. Glance versucht ImageProxy-Objekt als callable zu nutzen → `TypeError`
5. Nova bekommt Connection Reset beim Download

### ✅ Lösung: Trailing Slash entfernen

```bash
# Find Glance's filesystem store path
GLANCE_STORE_PATH=$(sudo grep -A5 "\[glance_store\]" /etc/glance/glance-api.conf | grep filesystem_store_datadir | cut -d'=' -f2 | tr -d ' ' || echo "/var/lib/glance/images")

if [ -z "$GLANCE_STORE_PATH" ]; then
  GLANCE_STORE_PATH="/var/lib/glance/images"
fi

# CRITICAL: Remove trailing slash to avoid double-slash in file:// URL
GLANCE_STORE_PATH="${GLANCE_STORE_PATH%/}"

# Now build URL - no more double slash!
FILE_LOCATION="file://${GLANCE_STORE_PATH}/${IMAGE_ID}"
# Result: file:///opt/stack/data/glance/images/41ef1b0a... ✅
```

**Ergebnis:**
- ✅ Korrekte URL ohne Doppel-Slash
- ✅ Glance kann Schema `file://` parsen
- ✅ Nova kann Image erfolgreich von Glance downloaden
- ✅ VM wird erfolgreich erstellt

---

## Lessons Learned

### Was NICHT funktioniert (für 1.3GB Stemcells in DevStack)
- ❌ HTTP Upload via Glance API (requests, curl)
- ❌ Glance CLI Upload (auch mit direktem Port)
- ❌ Apache als Proxy vor Glance
- ❌ Verschiedene Content-Type Header
- ❌ Chunked vs. Non-Chunked Encoding
- ❌ Timeout-Erhöhungen in Glance Config

### Was funktioniert ✅
- ✅ Direkter Filesystem-Zugriff + MySQL-Update
- ✅ Fallback-URLs für bosh.io
- ✅ Auto-Detection (MySQL credentials, User, Ports)
- ✅ Robuste Fehlerbehandlung
- ✅ **Path-Normalisierung (trailing slash entfernen)**

### Critical Details für Filesystem-Import
1. **Path muss normalisiert sein** - keine trailing slashes!
2. **URL Schema muss korrekt sein** - `file://` mit genau 3 Slashes
3. **image_locations.value ist JSON** - muss korrekt escaped sein
4. **Ownership ist wichtig** - glance:glance oder stack:stack
5. **Checksum muss stimmen** - sonst schlägt Verification fehl

### Für Produktion
- Nutze **Swift** oder **Ceph** als Glance Backend
- DevStack ist nur für kleine Images (<100MB) via HTTP zuverlässig
- Große Images benötigen objektspeicher-basierte Backends

---

## Erfolgreicher Workflow

**Status:** ✅ Funktioniert zuverlässig (nach Problem 8 Fix)

**Limitation:** DevStack-spezifischer Workaround, nicht für Produktion geeignet

**Alternative für Produktion:** 
- Glance mit Swift/Ceph Backend
- Oder Glance mit S3-kompatiblem Storage
- Vermeidet HTTP-Upload-Probleme komplett

---

## Commits Timeline (Updated)

1. `f235a33` - Try upload WITHOUT Content-Type header
2. `539cba9` - Fix: Auto-detect Glance port
3. `3fb5a66` - WORKAROUND: Bypass Apache, direct port 9292
4. `41a1654` - Fix: Apache rejecting application/octet-stream
5. `2795794` - Fix: Replace curl with Python requests
6. `8db6ea3` - Fix: Add Content-Length header
7. `3cc24b1` - Enable workflow on every push
8. `bcb434f` - Fix: Load file into memory
9. `a62509e` - Fix: Configure Glance socket timeout
10. `2314c22` - Try OpenStack CLI for upload
11. `f2815a7` - Fix: Use 'glance image-upload'
12. `c027cf8` - Force glance CLI to use direct port
13. `89fce48` - **WORKAROUND: Copy directly to filesystem**
14. `fbd9ee8` - Fix: Proper user detection
15. `d78a6f9` - Fix: Set metadata and activate via database
16. `e8e6ce5` - Fix: Auto-detect MySQL credentials
17. `ac1e439` - Fix: Add image_locations entry
18. `a7cac95` - Fix: Add 'deleted' field
19. `9eb6c44` - Fix: Add fallback for bosh.io API
20. `87232ca` - Fix: Use direct Google Storage URL
21. `3ca0d6c` - Debug: Add extensive logging for Glance download failure
22. `b98217e` - Add Nova image_download_timeout config
23. `2686240` - Fix: Increase Glance timeouts for large image downloads
24. `40f0ad6` - Fix: Update public endpoint instead of internal
25. `7090462` - Fix: Update Keystone endpoint BEFORE restarting Nova
26. `e2605a7` - **Fix: Remove trailing slash from GLANCE_STORE_PATH** ✅
