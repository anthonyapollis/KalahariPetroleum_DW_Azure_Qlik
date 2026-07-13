# Qlik Sense App Guide — Kalahari Petroleum Fleet Fuel / SARS Diesel Refund

[← Back to project overview](../README.md) · [Data story](../index.html) · [Azure architecture](../azure/AZURE_ARCHITECTURE.md)

*Kalahari Petroleum is a fictional company invented for this portfolio piece; see the
[README case-study note](../README.md) for context. The Azure account name below
(`stanglominingdw01`) is a real, unchanged infrastructure identifier.*

Tenant: `https://go10njvx344b4j2.eu.qlikcloud.com`

**The app described below is live**: "Kalahari Petroleum - Fuel & Diesel Refund"
(`app id 9c13b9e4-e393-4d9a-9f8b-3d62e3a28719`), built end-to-end via `qlik-cli` and the
Qlik Cloud REST/Engine APIs — data loaded (12 tables, reconciled row counts), 14 master
measures, and all 6 sheets below with real charts, all verified against the actual
warehouse totals (e.g. `Litres Issued` KPI evaluates to exactly 290,557,288 — the same
figure validated throughout this project). Data lives in the app's own Qlik Cloud
DataFiles storage (`lib://DataFiles/*.txt`, uploaded from `data_export/*.tsv` — `.tsv`
isn't an allowed DataFiles extension, `.txt` is, so the files were renamed on upload;
the load script's explicit `(txt, ..., delimiter is '\t')` format spec doesn't care about
the extension either way). This guide remains the reference for rebuilding the app from
scratch, or for anyone who prefers to build it by hand in the UI.

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
actually evaluates before moving on to the next one.

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
| # | Chart type | Dimension | Measure(s) |
|---|---|---|---|
| 1 | Pie chart | synthetic dimension `='Eligible'` / `='Non-Eligible'` via two measures, or use a Bar chart instead (pie charts with two fixed slices are simpler as a bar) | Eligible Litres, Non-Eligible Litres |
| 2 | Bar chart | `ActivityDescription` (from DimEligibleActivity, needs a join or an additional load — see note) | Litres Issued |
| 3 | Table | `SpecificActivityPerformed` | Total Fuel Used |

*Note: `ActivityDescription`/`EligibilityStatus` live on `DimEligibleActivity`, not loaded
in the shipped script (only `EligibleActivityKey` is carried on the Fuel Issue rows). Add
a `DimEligibleActivity` LOAD block (same pattern as `DimLocation` etc.) if you want chart 2
exactly as specified; otherwise substitute `EligibleActivityKey` as the dimension.*

### Sheet 5 — Tank & Delivery Reconciliation
| # | Chart type | Dimension | Measure(s) |
|---|---|---|---|
| 1 | Bar chart | `LocationDescription`, `YearMonth` | Tank Net Movement |
| 2 | Table | `DocumentNumber`, `LocationDescription`, `YearMonth` | Litres Delivered |

### Sheet 6 — Data Quality
| # | Chart type | Dimension | Measure(s) |
|---|---|---|---|
| 1 | KPI | — | `Count({<FactType={'Fuel Issue'}>} DISTINCT FuelEventId)` |
| 2 | KPI | — | `Count({<FactType={'Fuel Issue'}>} FuelEventId) - Count({<FactType={'Fuel Issue'}>} DISTINCT FuelEventId)` *(duplicate count)* |
| 3 | KPI | — | usage rows unmatched to equipment: 203,309 in the QA data (RegNumber mismatch vs equipment master — this is a static finding from `dw.vw_DataQuality`, not live-computable from the loaded fields; show as a text KPI) |
| 4 | KPI | — | fuel issues exceeding 1.5× tank size: 14,746 (same — static from `dw.vw_DataQuality`) |

*For live-computable versions of KPIs 3–4, load `dw.vw_DataQuality` itself as an
additional table in the script (`SELECT issue, row_count FROM dw.vw_DataQuality`) and
bind these KPIs to it directly instead of hardcoding.*

## Reproducibility

Every number above should reconcile against `data/analysis/*.csv` and the Excel
workbook's matching sheet — if a Qlik measure doesn't match the corresponding CSV
total, the load script or the measure expression has a bug, not the source data
(the DW itself is validated to the hundredth of a litre — see the main README).
