#!/usr/bin/env bash
# =============================================================================
# post.sh – Instagram Content Publishing via Graph API
# =============================================================================
# Verwendung:
#   Einzelbild:  ./post.sh --caption "Text" --image "https://example.com/1.jpg"
#   Karussell:   ./post.sh --caption "Text" --image "https://…/1.jpg" --image "https://…/2.jpg"
#
# .env-Datei (im gleichen Verzeichnis):
#   ACCESS_TOKEN=EAABsbCS...
#   IG_USER_ID=171111100000000000
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Konfiguration
# ---------------------------------------------------------------------------
API_HOST="https://graph.instagram.com"
API_VERSION="v21.0"
POLL_INTERVAL=5   # Sekunden zwischen Status-Abfragen
POLL_MAX=12       # Maximale Anzahl Versuche (= 60s)

# ---------------------------------------------------------------------------
# .env laden
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ Fehler: .env-Datei nicht gefunden unter $ENV_FILE" >&2
  exit 1
fi

# Nur KEY=VALUE-Zeilen einlesen, Kommentare und Leerzeilen ignorieren
while IFS='=' read -r key value; do
  [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
  # Anführungszeichen aus dem Wert entfernen
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  export "$key=$value"
done < "$ENV_FILE"

if [[ -z "${ACCESS_TOKEN:-}" || -z "${IG_USER_ID:-}" ]]; then
  echo "❌ Fehler: ACCESS_TOKEN und IG_USER_ID müssen in der .env-Datei gesetzt sein." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Argumente parsen
# ---------------------------------------------------------------------------
CAPTION=""
IMAGE_URLS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --caption)
      CAPTION="$2"
      shift 2
      ;;
    --image)
      IMAGE_URLS+=("$2")
      shift 2
      ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "❌ Unbekannter Parameter: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ${#IMAGE_URLS[@]} -eq 0 ]]; then
  echo "❌ Fehler: Mindestens eine --image URL ist erforderlich." >&2
  exit 1
fi

if [[ ${#IMAGE_URLS[@]} -gt 10 ]]; then
  echo "❌ Fehler: Maximal 10 Bilder pro Karussell-Post erlaubt." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

# API-Aufruf mit Bearer-Auth, gibt Response-Body aus
api_post() {
  local endpoint="$1"
  shift
  local url="${API_HOST}/${API_VERSION}/${endpoint}"

  local response
  response=$(curl --silent --show-error --fail-with-body \
    -X POST "$url" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    "$@")

  echo "$response"
}

api_get() {
  local endpoint="$1"
  local url="${API_HOST}/${API_VERSION}/${endpoint}"

  curl --silent --show-error --fail-with-body \
    -X GET "$url" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}"
}

# Prüft ob JSON ein "error"-Feld enthält und gibt es aus
check_error() {
  local response="$1"
  local context="$2"

  if echo "$response" | grep -q '"error"'; then
    echo "❌ Fehler bei: $context" >&2
    echo "$response" | python3 -c "
import sys, json
try:
    e = json.load(sys.stdin).get('error', {})
    print(f\"  Typ:     {e.get('type','?')}\", file=sys.stderr)
    print(f\"  Code:    {e.get('code','?')} / subcode {e.get('error_subcode','?')}\", file=sys.stderr)
    print(f\"  Meldung: {e.get('message','?')}\", file=sys.stderr)
except: print(sys.stdin.read(), file=sys.stderr)
" 2>&1 >&2
    exit 1
  fi
}

# Extrahiert einen JSON-Wert per Key (einfaches grep, kein jq nötig)
extract_id() {
  echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])"
}

# Pollt den Container-Status bis FINISHED oder Fehler
poll_status() {
  local container_id="$1"
  local attempt=0

  echo "⏳ Warte auf Container-Status FINISHED (alle ${POLL_INTERVAL}s, max. $((POLL_MAX * POLL_INTERVAL))s)..."

  while [[ $attempt -lt $POLL_MAX ]]; do
    attempt=$((attempt + 1))

    local response
    response=$(api_get "${container_id}?fields=status_code,status")
    check_error "$response" "Status-Abfrage Container $container_id"

    local status
    status=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status_code',''))")

    echo "   Versuch $attempt/$POLL_MAX: $status"

    case "$status" in
      FINISHED)
        echo "✅ Container bereit."
        return 0
        ;;
      ERROR|EXPIRED)
        echo "❌ Container-Status: $status – Abbruch." >&2
        exit 1
        ;;
      IN_PROGRESS|"")
        sleep "$POLL_INTERVAL"
        ;;
      *)
        echo "⚠️  Unbekannter Status: $status – warte weiter..."
        sleep "$POLL_INTERVAL"
        ;;
    esac
  done

  echo "❌ Timeout: Container wurde nicht rechtzeitig fertig." >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Hauptlogik
# ---------------------------------------------------------------------------

BASE_URL="${API_HOST}/${API_VERSION}"

echo ""
echo "📸 Instagram Publishing Script"
echo "==============================="
echo "  Account:  $IG_USER_ID"
echo "  Bilder:   ${#IMAGE_URLS[@]}"
[[ -n "$CAPTION" ]] && echo "  Caption:  ${CAPTION:0:60}..."
echo ""

# ── Einzelbild ──────────────────────────────────────────────────────────────
if [[ ${#IMAGE_URLS[@]} -eq 1 ]]; then
  echo "▶ Modus: Einzelbild"
  echo ""

  # 1. Container erstellen
  echo "1️⃣  Erstelle Media-Container..."
  BODY=$(python3 -c "
import json, sys
d = {'image_url': sys.argv[1]}
if sys.argv[2]: d['caption'] = sys.argv[2]
print(json.dumps(d))
" "${IMAGE_URLS[0]}" "$CAPTION")

  RESPONSE=$(api_post "${IG_USER_ID}/media" -d "$BODY")
  check_error "$RESPONSE" "Container erstellen"
  CONTAINER_ID=$(extract_id "$RESPONSE")
  echo "   Container-ID: $CONTAINER_ID"

  # 2. Status prüfen
  echo ""
  echo "2️⃣  Prüfe Container-Status..."
  poll_status "$CONTAINER_ID"

  # 3. Publishen
  echo ""
  echo "3️⃣  Veröffentliche Post..."
  PUBLISH_BODY=$(python3 -c "import json,sys; print(json.dumps({'creation_id': sys.argv[1]}))" "$CONTAINER_ID")
  PUBLISH_RESPONSE=$(api_post "${IG_USER_ID}/media_publish" -d "$PUBLISH_BODY")
  check_error "$PUBLISH_RESPONSE" "Veröffentlichen"
  MEDIA_ID=$(extract_id "$PUBLISH_RESPONSE")

  echo ""
  echo "🎉 Erfolgreich veröffentlicht!"
  echo "   Media-ID: $MEDIA_ID"

# ── Karussell ───────────────────────────────────────────────────────────────
else
  echo "▶ Modus: Karussell (${#IMAGE_URLS[@]} Bilder)"
  echo ""

  # 1. Kind-Container für jedes Bild erstellen
  echo "1️⃣  Erstelle Kind-Container für jedes Bild..."
  CHILD_IDS=()

  for i in "${!IMAGE_URLS[@]}"; do
    IMG="${IMAGE_URLS[$i]}"
    echo "   Bild $((i+1))/${#IMAGE_URLS[@]}: $IMG"

    BODY=$(python3 -c "
import json, sys
print(json.dumps({'image_url': sys.argv[1], 'is_carousel_item': 'true'}))
" "$IMG")

    RESPONSE=$(api_post "${IG_USER_ID}/media" -d "$BODY")
    check_error "$RESPONSE" "Kind-Container Bild $((i+1))"
    CHILD_ID=$(extract_id "$RESPONSE")
    CHILD_IDS+=("$CHILD_ID")
    echo "   → Container-ID: $CHILD_ID"
  done

  # 2. Karussell-Container erstellen
  echo ""
  echo "2️⃣  Erstelle Karussell-Container..."
  CHILDREN_LIST=$(IFS=,; echo "${CHILD_IDS[*]}")

  BODY=$(python3 -c "
import json, sys
d = {
  'media_type': 'CAROUSEL',
  'children': sys.argv[1]
}
if sys.argv[2]: d['caption'] = sys.argv[2]
print(json.dumps(d))
" "$CHILDREN_LIST" "$CAPTION")

  RESPONSE=$(api_post "${IG_USER_ID}/media" -d "$BODY")
  check_error "$RESPONSE" "Karussell-Container erstellen"
  CAROUSEL_ID=$(extract_id "$RESPONSE")
  echo "   Karussell-Container-ID: $CAROUSEL_ID"

  # 3. Status des Karussell-Containers prüfen
  echo ""
  echo "3️⃣  Prüfe Karussell-Container-Status..."
  poll_status "$CAROUSEL_ID"

  # 4. Publishen
  echo ""
  echo "4️⃣  Veröffentliche Karussell-Post..."
  PUBLISH_BODY=$(python3 -c "import json,sys; print(json.dumps({'creation_id': sys.argv[1]}))" "$CAROUSEL_ID")
  PUBLISH_RESPONSE=$(api_post "${IG_USER_ID}/media_publish" -d "$PUBLISH_BODY")
  check_error "$PUBLISH_RESPONSE" "Veröffentlichen"
  MEDIA_ID=$(extract_id "$PUBLISH_RESPONSE")

  echo ""
  echo "🎉 Karussell erfolgreich veröffentlicht!"
  echo "   Media-ID: $MEDIA_ID"
fi

echo ""
