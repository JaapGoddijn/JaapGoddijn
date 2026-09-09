# vlucht.sh

Vluchtstatus opvragen via de gratis [adsb.lol](https://api.adsb.lol/docs) API. Geen sleutel nodig.

```
./vlucht.sh TRA6260
```

Vereist: bash, curl, jq.

Uitvoer (twee korte regels, past op een telefoonscherm):

```
KLM1001 · PH-BXA (B738) · in de lucht
11278 m · 843 km/u · 51.9235,2.3457 · naar LHR (London)
```

Niet gevonden:

```
TRA6260: niet in de lucht (aan de grond of transponder uit).
```

Exitcodes: 0 ok, 1 verkeerd gebruik, 2 jq/curl ontbreekt, 3 API-fout of time-out (10 s).

## Testen zonder internet

`ADSB_API_BASE` en `ADSB_ROUTE_BASE` kunnen naar mappen met mock-bestanden wijzen (curl leest `file://`):

```
ADSB_API_BASE=file:///pad/naar/mock ADSB_ROUTE_BASE=file:///pad/naar/mock/routes ./vlucht.sh KLM1001
# leest /pad/naar/mock/v2/callsign/KLM1001 en /pad/naar/mock/routes/KL/KLM1001.json
```

## Gebruikte endpoints

- Positie: `GET https://api.adsb.lol/v2/callsign/<CALLSIGN>` (velden `r`, `t`, `alt_baro`, `gs`, `lat`, `lon`).
- Bestemming: `GET https://vrs-standing-data.adsb.lol/routes/<2 letters>/<CALLSIGN>.json` (veld `_airports`, laatste = bestemming; 404 als onbekend).

## Test tegen de echte API

De workflow `.github/workflows/test-vlucht.yml` draait bij elke push van `vlucht.sh` op GitHub Actions: TRA6260 plus een op dat moment vliegende lijnvlucht.
