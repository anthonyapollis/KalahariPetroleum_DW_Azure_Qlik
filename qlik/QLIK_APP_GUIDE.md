# Qlik Sense App Guide — Kalahari Petroleum Fleet Fuel / SARS Diesel Refund

[← Back to project overview](../README.md) · [Data story](../index.html) · [Azure architecture](../azure/AZURE_ARCHITECTURE.md)

*Kalahari Petroleum is a fictional company invented for this portfolio piece; see the
[README case-study note](../README.md) for context. The Azure account name below
(`stanglominingdw01`) is a real, unchanged infrastructure identifier.*

Tenant: `https://go10njvx344b4j2.eu.qlikcloud.com`

**The app described below is live**: "Kalahari Petroleum - Fuel & Diesel Refund"
(`app id 9c13b9e4-e393-4d9a-9f8b-3d62e3a28719`), built end-to-end via `qlik-cli` and the
Qlik Cloud REST/Engine APIs — data loaded (12 tables, reconciled row counts), 14 master
measures, 6 sheets with 27 objects (KPIs, charts, tables, filter listboxes, caption text),
all verified against the actual warehouse totals (e.g. `Litres Issued` KPI evaluates to
exactly 290,557,288 — the same figure validated throughout this project). Fully brand-
colored (navy/teal/gold/red/blue matching the ebook/Excel palette). Data lives in the
app's own Qlik Cloud DataFiles storage (`lib://DataFiles/*.txt`, uploaded from
`data_export/*.tsv` — `.tsv` isn't an allowed DataFiles extension, `.txt` is, so the files
were renamed on upload; the load script's explicit `(txt, ..., delimiter is '\t')` format
spec doesn't care about the extension either way).

The exact JSON used to build it is committed here: [`qlik_master_measures.json`](qlik_master_measures.json)
(14 master measures) and [`qlik_app_objects.json`](qlik_app_objects.json) (all 6 sheets +
27 objects — colors, titles, subtitles, footnotes, value labels and per-column `cId`s
included). **The fastest path is the build script:**

```powershell
.\build_qlik_app.ps1 -AppId <id>                          # measures + visual layer
.\build_qlik_app.ps1 -AppId <id> -UploadData              # full build incl. data upload + reload
.\build_qlik_app.ps1 -AppId <id> -VerifyOnly              # health check an existing app
```

[`build_qlik_app.ps1`](build_qlik_app.ps1) wraps every gotcha documented below (stdin
redirect, one-call object posting) and finishes with three verifications: the Litres
Issued KPI must reconcile to the DW figure 290,557,288, every sheet's `cells[]` must
still reference the named objects, and every chart column must carry a `cId`. This guide
remains the reference for rebuilding by hand in the UI, or for understanding what each
file does.

This guide is written so building the app takes ~10 minutes with no guesswork: every
measure and every chart below is copy-paste ready — exact expression, exact dimension,
exact chart type as it appears in the Qlik Sense "Add chart" panel.

## Step 0 — Getting the data in (pick one)

**Option A — Web files + SAS (fastest, no connector setup)**
1. Generate a read SAS for the `raw` container (valid e.g. 90 days):
   ```
   az storage container generate-sas --account-name stanglominingdw01 --name raw --permissions rl --expiry 2026-10-05 --auth-mode key --account-key <key> -o tsv
   ```
2. In the tenant: Create → New analytics app → open **Data load editor**.
3. Paste `kalahari_petroleum_fuel_load_script.qvs`, set `vSAS` to the token, reload.

**Option B — Azure Storage connector (governed)**
1. Data load editor → Create new connection → **Azure Storage**.
2. Account `stanglominingdw01`, key from `az storage account keys list`, container `raw`.
3. Replace each `FROM [$(vBase)/...]` with the `lib://` path the connector gives you.

**Option C — Local, no Azure at all**
Paste `kalahari_petroleum_fuel_load_script_local.qvs` instead — points at a folder
connection (`KalahariDW`) over `data_export/`, works fully offline.

**Automation — this is how the live app was actually built.** Generate an API key in
the tenant (avatar/profile icon → **Settings → API keys → Generate new key**, scopes:
Management API + User API — the value is shown once, copy it immediately). Then, with
[`qlik-cli`](https://github.com/qlik-oss/qlik-cli):
```
qlik context create <name> --server https://go10njvx344b4j2.eu.qlikcloud.com --api-key <key>
qlik context use <name>
qlik app create --app "App Name"                       # note the returned app id
qlik data-file create --name DimDate.txt --file data_export/DimDate.tsv   # repeat per table, .txt not .tsv (see note above)
qlik app script set qlik/kalahari_petroleum_fuel_load_script_local.qvs --app <appId>
                                                          # first rewrite FROM [lib://KalahariDW/X.tsv] -> FROM [lib://DataFiles/X.txt]
qlik app reload --app <appId>
qlik app measure set <measures.json> --app <appId>       # GenericMeasureProperties array, needs qInfo.qId per measure
qlik app object set <sheets-and-charts.json> --app <appId>  # GenericObjectProperties array: sheets (qType "sheet", cells[]) + each chart/kpi/table object
```
Notes from doing this for real: `qlik data-file create` needs `< NUL` stdin redirection
on Windows (its stdin-vs-file detection misfires otherwise); DataFiles rejects `.tsv` as
an extension (`DF-010`) but accepts `.txt`; every master measure and generic object needs
an explicit `qInfo.qId` or the API rejects it; percent number formats use `qNumFormat.qType:
"R"` with a `%` in the format string, not a `"P"` type (that's not a valid enum value).
`qlik app object data --app <appId> <objectId>` is the fastest way to verify a chart
actually evaluates before moving on to the next one (doesn't work for `listbox` objects —
use `qlik app object properties` or `layout` for those instead, `qSize.qcy` shows the
row count).

**Sheet/object linking — the one that will bite you:** a sheet's `cells[].name` is meant
to reference a chart/kpi/table by its `qId`, but this only works if that object is posted
in the *same* `qlik app object set` call as the sheet. Post them in separate calls (e.g.
build the sheet first, add colors to the KPI in a later call) and the CLI silently spawns
a duplicate object with a random ID instead of updating the linked one — the sheet then
shows an un-styled orphan copy, no error raised anywhere. Always assemble one combined
JSON (every sheet + every object it references) and post it in a single call — see
`qlik_app_objects.json` in this folder for the working pattern. If you suspect this has
happened, `qlik app object properties --app <id> <sheetId>` and check whether
`cells[].name` still matches your intended IDs or has been replaced with short random
strings.

**Number format renders literally without separator characters:** a measure's
`qNumFormat` with `qUseThou: 0` but a thousands separator in the pattern (`"qFmt":
"#,##0"`) makes the engine print the format string itself — KPIs show `290557288,##0`
instead of `290,557,288`. The working combination is `qUseThou: 1` plus explicit
separator characters: `"qDec": "."`, `"qThou": ","`. See `qlik_master_measures.json`
for the corrected definitions.

**Charts render blank without per-column `cId`:** KPIs and listboxes draw fine, but
any object with a dimension (bar/line/combo/scatter/table) renders as an empty panel
if its hypercube columns lack a component ID — the Qlik Sense client indexes columns
by `qDef.cId`, which the engine API does not require and does not generate. Give every
entry in `qDimensions` and `qMeasures` a unique `qDef.cId` (this project uses
`<objectId>-d0`/`<objectId>-m0`), and set `showTitles: true` + `title` at the object's
top level or the chart header stays empty too. `qlik app object data` returning correct
values does NOT prove the chart will render — that call exercises the engine, not the
client.

**Data-model constraint found while building Sheet 4:** `EligibleActivityKey` (which
links to `DimEligibleActivity`/`ActivityDescription`) only exists on Fuel Issue rows in
the concatenated `Fuel` table, not on Usage Classification rows — so a chart of
`ActivityDescription` × `Eligible Litres`/`Non-Eligible Litres` silently buckets
everything into a single blank "-" dimension value (those measures are Usage-
Classification-scoped). The working version uses `ActivityDescription` × `Litres Issued`
instead, which resolves correctly.

## Data model
Single concatenated fact table `Fuel` (FactType = Fuel Issue / Fuel Delivery /
Usage Classification / Meter Reading / Equipment Trip) associated to DimDate,
DimEquipment, DimLocation, DimProduct, DimCostCentre, DimEligibleActivity.
`RefundClaims` is a deliberate data island (month-grain SARS 670.04 output
from the DW, fields prefixed `Claim.`).

## Step 1 — Master measures

Create these once (**Master items → Measures → New**) before building any sheet.
Number format for every litre measure: `#,##0` (whole number, thousands separator).
Currency measures: `R #,##0` (or `#,##0 "R"` depending on locale).

| Name | Expression | Format |
|---|---|---|
| Litres Issued | `Sum({<FactType={'Fuel Issue'}>} IssuedLitres)` | number |
| Litres Delivered | `Sum({<FactType={'Fuel Delivery'}>} DeliveredLitres)` | number |
| Total Fuel Used | `Sum({<FactType={'Usage Classification'}>} UsageTotalLitres)` | number |
| Eligible Litres | `Sum({<FactType={'Usage Classification'}>} EligibleLitres)` | number |
| Non-Eligible Litres | `Sum({<FactType={'Usage Classification'}>} NonEligibleLitres)` | number |
| Eligible % | `Sum({<FactType={'Usage Classification'}>} EligibleLitres) / Sum({<FactType={'Usage Classification'}>} UsageTotalLitres)` | percent |
| Qualifying Litres | `Sum({<FactType={'Usage Classification'}>} EligibleLitres) * 0.8` | number |
| Refund (R, 349c/l) | `Sum({<FactType={'Usage Classification'}>} EligibleLitres) * 0.8 * 3.49` | currency |
| Litres per Hour/Km | `Sum({<FactType={'Fuel Issue'}>} IssuedLitres) / Sum({<FactType={'Meter Reading'}>} UnitsWorked)` | number, 2 dec |
| Trips | `Sum({<FactType={'Equipment Trip'}>} TripCount)` | number |
| Tank Net Movement | `Sum({<FactType={'Fuel Delivery'}>} DeliveredLitres) - Sum({<FactType={'Fuel Issue'}>} IssuedLitres)` | number |

Island (`RefundClaims`, use directly, no `FactType` filter needed):

| Name | Expression |
|---|---|
| Claim Refund | `Sum(Claim.RefundRand)` |
| Claim Eligible Litres | `Sum(Claim.EligibleLitres)` |
| Claim Qualifying Litres | `Sum(Claim.QualifyingLitres)` |

**Caution baked into the model:** the 349 c/L rate is the 2020 SARS policy example from
the project's evidence pack — not current tax advice. `RefundClaims` (the island) carries
the DW-computed, per-period-accurate figures; the flat `Refund (R, 349c/l)` master measure
is a simplified always-current-rate approximation for exploratory dashboarding only.

## Step 2 — Build the sheets

### Sheet 1 — Executive Fuel Overview
| # | Chart type | Dimension | Measure(s) |
|---|---|---|---|
| 1 | KPI | — | Litres Issued |
| 2 | KPI | — | Litres Delivered |
| 3 | KPI | — | Refund (R, 349c/l) |
| 4 | KPI | — | Eligible % |
| 5 | Line chart | `YearMonth` | Litres Issued |
| 6 | Bar chart (horizontal) | `LocationDescription` (sort by measure, top 15) | Litres Issued |

Filter pane: `Year`, `FiscalYearSA`, `LocationDescription`, `ProductName`.

### Sheet 2 — SARS Diesel Refund
| # | Chart type | Dimension | Measure(s) |
|---|---|---|---|
| 1 | KPI | — | Claim Refund |
| 2 | KPI | — | Claim Eligible Litres |
| 3 | KPI | — | Claim Qualifying Litres |
| 4 | Combo chart | `Claim.YearMonth` | Bars (stacked): `Sum(Claim.EligibleLitres)`, `Sum(Claim.NonEligibleLitres)`; Line (2nd axis): `Sum(Claim.RefundRand)` |
| 5 | Table | `Claim.YearMonth` | All `Claim.*` fields; conditional format `Claim.RateMissingFlag` red when true |

Text/image object: "Rates are 2020 SARS policy examples (Rebate Item 670.04, Schedule 6,
Customs & Excise Act) — not tax advice."

### Sheet 3 — Equipment Efficiency
| # | Chart type | Dimension | Measure(s) |
|---|---|---|---|
| 1 | Scatter plot | `FleetId` | x: `Sum({<FactType={'Meter Reading'}>} UnitsWorked)`; y: `Sum({<FactType={'Fuel Issue'}>} IssuedLitres)` |
| 2 | Table | `MakeName`, `ModelName`, `VehicleTypeName` | Litres per Hour/Km |

Filter pane: `ConsumptionTypeName` (L/HR vs L/100KM — don't mix these on the scatter,
they're different units), `EligibilityClass`.
**Reading it:** points far from the trend line are the anomaly candidates — same idea as
the Isolation Forest model in `sql/10_ml_anomaly_detection.py`, but as an eyeballable
exploratory view instead of a scored list.

### Sheet 4 — Eligibility & Activity
`DimEligibleActivity` *is* loaded in the shipped script (`ActivityCodePattern`,
`ActivityDescription`, `EligibilityStatus`), associated via `EligibleActivityKey` — but
that key only exists on Fuel Issue rows, not Usage Classification rows, so charts against
it must use `Litres Issued`, not `Eligible Litres`/`Non-Eligible Litres` (see the
data-model constraint note above — a chart built against the wrong measure silently
buckets everything into a blank "-" dimension value with no error).

| # | Chart type | Dimension | Measure(s) |
|---|---|---|---|
| 1 | Bar chart | `ActivityDescription` | Litres Issued |
| 2 | Bar chart | `EligibilityStatus` | Litres Issued |
| 3 | Table | `SpecificActivityPerformed` | Total Fuel Used |

Filter pane: `EligibilityStatus`.

### Sheet 5 — Tank & Delivery Reconciliation
| # | Chart type | Dimension | Measure(s) |
|---|---|---|---|
| 1 | Bar chart | `LocationDescription`, `YearMonth` | Tank Net Movement |
| 2 | Table | `DocumentNumber`, `LocationDescription`, `YearMonth` | Litres Delivered |

### Sheet 6 — Data Quality
| # | Type | Dimension | Measure(s) / content |
|---|---|---|---|
| 1 | KPI | — | `Count({<FactType={'Fuel Issue'}>} DISTINCT FuelEventId)` |
| 2 | KPI | — | `Count({<FactType={'Fuel Issue'}>} FuelEventId) - Count({<FactType={'Fuel Issue'}>} DISTINCT FuelEventId)` *(duplicate count)* |
| 3 | KPI | — | Trips (fleet-wide sanity total) |
| 4 | Text/note | — | Static findings from `dw.vw_DataQuality`, not live-computable from the loaded fields: 203,309 usage-logbook rows unmatched to equipment master (RegNumber mismatch), 14,746 fuel issues exceeding 1.5× tank size |

*For live-computable versions of the two static findings, load `dw.vw_DataQuality` itself
as an additional table in the script (`SELECT issue, row_count FROM dw.vw_DataQuality`)
and bind KPIs to it directly instead of the fixed text note.*

## Reproducibility

Every number above should reconcile against `data/analysis/*.csv` and the Excel
workbook's matching sheet — if a Qlik measure doesn't match the corresponding CSV
total, the load script or the measure expression has a bug, not the source data
(the DW itself is validated to the hundredth of a litre — see the main README).
