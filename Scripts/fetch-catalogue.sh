#!/usr/bin/env bash
# Refreshes the checked-in list of valid telematic descriptor ids.
#
# BMW rejects a container containing an unknown or deprecated descriptor with
# "CU-402 Telematic key is invalid", so DescriptorCatalogueTests pins every id the
# app uses against this list. Run this when BMW extends the catalogue.
set -euo pipefail
OUT="$(dirname "$0")/../Tests/BMWBarKitTests/Fixtures/catalogue-ids.json"
python3 - "$OUT" <<'PY'
import json, sys, time, urllib.request
base = "https://www.bmw.co.uk/en-gb/utilities/bmw/api/cd/catalogue"
ids, offset = set(), 0
while True:
    with urllib.request.urlopen(f"{base}?streamable=true&offset={offset}&q=&category=", timeout=30) as r:
        page = json.load(r)["data"]["items"]
    if not page:
        break
    ids.update(i["id"] for i in page)
    offset += len(page)
    time.sleep(0.15)
json.dump({
    "_source": f"{base}?streamable=true",
    "_note": f"Streamable telematic descriptor ids published by BMW. Regenerate with Scripts/fetch-catalogue.sh.",
    "count": len(ids),
    "ids": sorted(ids),
}, open(sys.argv[1], "w"), indent=1)
print(f"wrote {len(ids)} ids to {sys.argv[1]}")
PY
