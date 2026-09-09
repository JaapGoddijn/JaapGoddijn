#!/usr/bin/env bash
# vlucht.sh — status van een vlucht opvragen via de gratis adsb.lol API.
#
# Gebruik:  ./vlucht.sh CALLSIGN        bijv. ./vlucht.sh TRA6260
#
# Vereisten: bash, curl, jq. Geen API-sleutel nodig.
#
# Omgevingsvariabelen (optioneel, voor testen):
#   ADSB_API_BASE    basis-URL van de API (standaard https://api.adsb.lol)
#   ADSB_ROUTE_BASE  basis-URL van de route-data (standaard
#                    https://vrs-standing-data.adsb.lol/routes)
#
# Exitcodes: 0 ok, 1 verkeerd gebruik, 2 jq ontbreekt, 3 API-fout.

set -u

BASIS="${ADSB_API_BASE:-https://api.adsb.lol}"
ROUTE_BASIS="${ADSB_ROUTE_BASE:-https://vrs-standing-data.adsb.lol/routes}"
TIMEOUT=10

# --- Controles vooraf -------------------------------------------------------

# jq is nodig om het JSON-antwoord te lezen.
if ! command -v jq >/dev/null 2>&1; then
  echo "Fout: jq ontbreekt. Installeer met bijv. 'sudo apt install jq' of 'brew install jq'." >&2
  exit 2
fi

# curl is normaal altijd aanwezig, maar voor de zekerheid.
if ! command -v curl >/dev/null 2>&1; then
  echo "Fout: curl ontbreekt." >&2
  exit 2
fi

# Callsign is verplicht.
if [ $# -lt 1 ] || [ -z "${1// /}" ]; then
  echo "Gebruik: $(basename "$0") CALLSIGN   (bijv. TRA6260)" >&2
  exit 1
fi

# Hoofdletters en geen spaties; zo staat het ook in de ADS-B-data.
CALLSIGN=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')

# --- API aanroepen ----------------------------------------------------------

# --fail: HTTP-fouten (4xx/5xx) als curl-fout melden.
ANTWOORD=$(curl -sS --fail --max-time "$TIMEOUT" "$BASIS/v2/callsign/$CALLSIGN" 2>/dev/null)
RC=$?
if [ $RC -ne 0 ]; then
  case $RC in
    28) echo "Fout: adsb.lol reageerde niet binnen ${TIMEOUT}s." >&2 ;;
    6|7) echo "Fout: adsb.lol niet bereikbaar (geen verbinding)." >&2 ;;
    22) echo "Fout: adsb.lol gaf een HTTP-fout terug." >&2 ;;
    *)  echo "Fout: adsb.lol niet bereikbaar (curl-code $RC)." >&2 ;;
  esac
  exit 3
fi

# Leeg antwoord of geen geldige JSON met een 'ac'-lijst: netjes stoppen.
if [ -z "$ANTWOORD" ] \
   || ! printf '%s' "$ANTWOORD" | jq -e 'type == "object" and (.ac | type == "array")' >/dev/null 2>&1; then
  echo "Fout: leeg of onverwacht antwoord van adsb.lol." >&2
  exit 3
fi

# --- Niet in de lucht -------------------------------------------------------

AANTAL=$(printf '%s' "$ANTWOORD" | jq '.ac | length')
if [ "$AANTAL" -eq 0 ]; then
  echo "$CALLSIGN: niet in de lucht (aan de grond of transponder uit)."
  exit 0
fi

# --- Toestel kiezen en velden lezen ----------------------------------------

# Meerdere toestellen met dezelfde callsign komt voor (oude data).
# Kies het toestel met positie en de meest recente positie-update (seen_pos).
# Velden volgens het readsb/ADSB-Exchange v2-formaat:
#   r = registratie, t = type, alt_baro = hoogte in ft of "ground",
#   gs = grondsnelheid in knopen, lat/lon = positie.
LEES=$(printf '%s' "$ANTWOORD" | jq -r '
  ( (.ac | map(select(.lat != null and .lon != null)) | sort_by(.seen_pos // 99999) | .[0]) // .ac[0] )
  | [ (.r // "?"),
      (.t // ""),
      (.alt_baro // "?" | tostring),
      (.gs // "?" | tostring),
      (.lat // "?" | tostring),
      (.lon // "?" | tostring) ]
  | @tsv')
IFS=$'\t' read -r REG TYPE ALT GS LAT LON <<<"$LEES"

# Type tussen haakjes, alleen als bekend.
TYPESTR=""
[ -n "$TYPE" ] && TYPESTR=" ($TYPE)"

# Positie kort afronden (4 decimalen ≈ 10 m), leesbaar op een smal scherm.
POS="?"
if [ "$LAT" != "?" ] && [ "$LON" != "?" ]; then
  POS=$(printf '%.4f,%.4f' "$LAT" "$LON")
fi

# --- Aan de grond met transponder aan --------------------------------------

if [ "$ALT" = "ground" ]; then
  echo "$CALLSIGN · $REG$TYPESTR"
  echo "Niet in de lucht: staat aan de grond (transponder aan) · $POS"
  exit 0
fi

# --- In de lucht: eenheden omrekenen ---------------------------------------

# Voet -> meter, knopen -> km/u. Afgerond naar hele getallen.
HOOGTE="?"
[ "$ALT" != "?" ] && HOOGTE=$(awk -v ft="$ALT" 'BEGIN{printf "%d m", ft*0.3048+0.5}')
SNELHEID="?"
[ "$GS" != "?" ] && SNELHEID=$(awk -v kt="$GS" 'BEGIN{printf "%d km/u", kt*1.852+0.5}')

# --- Bestemming (best effort) ---------------------------------------------

# adsb.lol publiceert routes per callsign als statische JSON:
#   <ROUTE_BASIS>/<eerste 2 tekens>/<CALLSIGN>.json
# Antwoord bevat "_airports" (vertrek ... bestemming); 404 als onbekend.
# Mislukt dit (time-out, onbekende route), dan laten we de bestemming weg.
BESTEMMING=""
ROUTE=$(curl -sS --fail --max-time "$TIMEOUT" \
  "$ROUTE_BASIS/${CALLSIGN:0:2}/$CALLSIGN.json" 2>/dev/null) || ROUTE=""
if [ -n "$ROUTE" ]; then
  # Laatste luchthaven is de bestemming: "DUB (Dublin)". Valt terug op de
  # laatste code uit "_airport_codes_iata" of "airport_codes" (bijv. "AMS-LHR").
  BESTEMMING=$(printf '%s' "$ROUTE" | jq -r '
    ( ._airports // [] | last // {} )
    | if (.iata // .icao) then
        (.iata // .icao) + (if .location then " (" + .location + ")" else "" end)
      else empty end
    ' 2>/dev/null | head -n 1)
  if [ -z "$BESTEMMING" ]; then
    BESTEMMING=$(printf '%s' "$ROUTE" | jq -r '
      ( ._airport_codes_iata // .airport_codes // "" ) | split("-") | last
      | select(. != "" and . != "unknown")' 2>/dev/null | head -n 1)
  fi
fi
BESTSTR=""
[ -n "$BESTEMMING" ] && BESTSTR=" · naar $BESTEMMING"

# --- Uitvoer: twee korte regels --------------------------------------------

echo "$CALLSIGN · $REG$TYPESTR · in de lucht"
echo "$HOOGTE · $SNELHEID · $POS$BESTSTR"
