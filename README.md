# Kalahari Petroleum — SQL Data Warehouse (DW) → Azure Data Factory → Qlik Sense

**[Open `index.html`](index.html) for the interactive data story** — "Fuelling an Oil & Gas Giant."
Repo: [github.com/anthonyapollis/KalahariPetroleum_DW_Azure_Qlik](https://github.com/anthonyapollis/KalahariPetroleum_DW_Azure_Qlik) (private) ·
[PDF report](reports/Kalahari_Petroleum_Fuel_Data_Story.pdf) · [Excel workbook](reports/Kalahari_Petroleum_Fuel_Data_Story.xlsx)

> **Case-study note:** Kalahari Petroleum is a fictional oil & gas company invented for this
> portfolio piece. The underlying operational data is a real (anonymised) mining/haulage
> fleet-fuel ERP (Enterprise Resource Planning system) database, presented here under a
> fictional identity to demonstrate the data model and analytics pipeline without naming the
> source organisation.

> **SSIS, tabular model and Fabric migration.**
> - [`ssis/`](ssis/README.md): the warehouse load rebuilt as metadata-driven SSIS packages generated from Biml.
>   Dimensions use `MERGE`, facts load incrementally from a watermark, and every run is logged. It passes
>   all 16 parity checks against the original warehouse.
> - [`tabular/`](tabular/README.md): an SSAS Tabular model with DAX time intelligence, facts at three grains
>   sharing conformed dimensions, and dynamic row-level security, verified measure by measure against SQL.
> - [`docs/SSIS_TO_FABRIC_MIGRATION.md`](docs/SSIS_TO_FABRIC_MIGRATION.md): how this estate moves to Microsoft Fabric.

## The business problem, in one paragraph

A heavy-vehicle fleet burns diesel it can partially reclaim from SARS (the South African
Revenue Service) under a diesel-refund scheme for on-land primary-sector activity — but only
for litres correctly classified as "eligible," and only if the underlying transaction data is
trustworthy. Get the classification wrong and you either under-claim (losing real money) or
over-claim on bad data (a compliance risk). This project builds the data platform that answers
three questions with evidence, not guesswork: **how much fuel is actually being used and where,
which litres genuinely qualify for refund, and which transactions in the ledger shouldn't be
trusted at all** — then puts all three in front of finance, operations, and compliance
stakeholders in the format each of them actually uses (a written report, a spreadsheet, a BI
tool, a map).

End-to-end analytics build over an upstream fleet-fuel / petroleum-logbook ERP
(source database `AngloData_QA_20220825_1820`, local SQL Server, retained
under its original technical name — see note above) with SARS diesel-refund
(Rebate Item 670.04 of Schedule 6 to the Customs & Excise Act) business logic
from the evidence pack.

Built 2026-07-06/08. ~23.7M rows shipped through the full pipeline:
1.85M DW (data warehouse) fact rows + the 21.9M-row dbo.CoordRef geo reference
(1 GB TSV → 346 MB snappy Parquet in curated). CoordRef re-export is opt-in
(`02_export_dw_to_tsv.ps1 -IncludeCoordRef`, ~26 min of bcp — SQL Server's
bulk copy program — on this machine).

## Tech stack

| Layer | Tools |
|---|---|
| Source & warehouse | SQL Server (star schema, schema `dw`: 8 dimensions, 8 facts, 5 views) |
| Orchestration / cloud | Azure Data Factory (ADF), Azure Data Lake Storage (ADLS) Gen2, Azure CLI |
| Data engineering | Python (pandas, pyarrow), PowerShell, bcp, azcopy |
| Machine learning | scikit-learn (Isolation Forest anomaly detection) |
| Visualisation | matplotlib (static charts), Leaflet.js (interactive map), xlsxwriter (native Excel charts) |
| BI / self-service | Qlik Sense Cloud — cloud (ADLS) and local (folder-connection) load-script variants |
| Publishing | Self-contained HTML ebook, headless-Chrome PDF render, 13-sheet Excel workbook |
| Version control | Git + GitHub Releases (for the 3 files over GitHub's 100 MB repo limit — see below) |

## Data availability — how to verify every number in this report

**Every chart, table, and figure in this report traces back to a file in this repository.**
There is no step where you have to take a number on faith:

1. `data_export/` — the raw TSV export of every warehouse table, straight off SQL Server (bcp,
   UTF-8). This is the ground truth.
2. `curated_local/dw/` — the same data as Parquet, partitioned exactly like the Azure `curated`
   container, for fast local analysis (pandas/DuckDB/Spark all read Parquet natively).
3. `data/analysis/` — the reporting aggregates (refunds by month, fuel by location, ML anomaly
   scores, map site/route data) computed directly from the warehouse — the CSVs behind every
   chart and Excel sheet.
4. `sql/01`–`10` — the numbered build scripts that produce steps 1–3 and the final reports, in
   order, so the whole pipeline (warehouse build → export → aggregates → charts/Excel/ebook/map/ML)
   is re-runnable from source, not just described.

**Clone the repo, then grab three files from Releases:**
```
git clone https://github.com/anthonyapollis/KalahariPetroleum_DW_Azure_Qlik.git
```
That gets everything except three files that exceed GitHub's 100 MB per-file repo limit
(`data_export/CoordRef.tsv` 1 GB, `curated_local/dw/CoordRef/CoordRef.parquet` 331 MB,
`data_export/FactEquipmentTrip.tsv` 174 MB — together, the raw and Parquet forms of a
21.9-million-row GPS reference table plus a large haulage-trip export). They're published as
**[GitHub Release assets](https://github.com/anthonyapollis/KalahariPetroleum_DW_Azure_Qlik/releases/tag/v1.0-data)**
instead of committed to the repo — download and drop each one at the path named on the release
page. (Git LFS was the first approach tried here; its free tier is 1 GB storage + 1 GB/month
bandwidth per account, and this dataset alone is 1.6 GB, so a single clone would exceed the
free allowance. Release assets have no such quota.) Nothing is held back or summarised-only —
every number in the report traces to one of these files, LFS or not.

## What's here

| Path | What |
|---|---|
| [`index.html`](index.html) | **The data-story ebook** — "Fuelling an Oil & Gas Giant" (open directly in a browser) |
| [`reports/Kalahari_Petroleum_Fuel_Data_Story.pdf`](reports/Kalahari_Petroleum_Fuel_Data_Story.pdf) | Print render of the ebook |
| [`reports/Kalahari_Petroleum_Fuel_Data_Story.xlsx`](reports/Kalahari_Petroleum_Fuel_Data_Story.xlsx) | 13-sheet workbook: KPIs, refund claims, fleet/haulage aggregates, data quality, native charts |
| [`sql/01_create_load_dw_full.sql`](sql/01_create_load_dw_full.sql) | Complete re-runnable star-schema build: 8 dimensions, 8 facts, 5 analysis views, foreign keys (FKs) + indexes, in schema `dw` |
| [`sql/02_export_dw_to_tsv.ps1`](sql/02_export_dw_to_tsv.ps1) | bcp export of all DW tables + CoordRef to headered TSV |
| [`sql/03_build_local_parquet.py`](sql/03_build_local_parquet.py) | Local curated Parquet build (incremental; pandas QUOTE_NONE parser) |
| [`sql/04_export_analysis_csvs.ps1`](sql/04_export_analysis_csvs.ps1) | Reporting aggregates (refunds, fuel trends, fleet, haulage, DQ) → `data/analysis/*.csv` |
| [`sql/05_build_reports.py`](sql/05_build_reports.py) | Chart set (→ `data/charts/*.png`) + Excel workbook with native charts (→ `reports/*.xlsx`) |
| [`sql/06_build_ebook.py`](sql/06_build_ebook.py) | Builds `index.html` (charts embedded as base64) |
| [`data_export/`](data_export/) | The exported TSVs (source for both Azure and local curated) |
| [`curated_local/dw/`](curated_local/dw/) | **Local curated Parquet layer** — same layout as Azure `curated/dw/`; the project runs fully offline |
| [`azure/AZURE_ARCHITECTURE.md`](azure/AZURE_ARCHITECTURE.md) | Deployed resources, data flow, Self-Hosted Integration Runtime (SHIR) production pattern, cost + kill switch |
| [`azure/deploy_adf.ps1`](azure/deploy_adf.ps1), [`azure/run_pipeline.ps1`](azure/run_pipeline.ps1) | Re-deploy ADF artifacts / trigger + poll the pipeline |
| [`azure/adf/`](azure/adf/) | ADF dataset & pipeline definitions (TSV → Parquet ForEach copy) |
| [`qlik/kalahari_petroleum_fuel_load_script.qvs`](qlik/kalahari_petroleum_fuel_load_script.qvs) | Qlik Sense load script — cloud variant (ADLS via a SAS, Shared Access Signature — a time-limited Azure access token) |
| [`qlik/kalahari_petroleum_fuel_load_script_local.qvs`](qlik/kalahari_petroleum_fuel_load_script_local.qvs) | Qlik load script — **local variant** (folder connection `KalahariDW` → `data_export\`), same model |
| [`qlik/QLIK_APP_GUIDE.md`](qlik/QLIK_APP_GUIDE.md) | App setup on go10njvx344b4j2.eu.qlikcloud.com + 6 sheet designs |
| [`docs/erd_mermaid.md`](docs/erd_mermaid.md) | ERD + reconciled row counts |

## Star schema (schema `dw` on localhost)

**Dimensions:** DimDate (2009–2023, SA fiscal year + season), DimEquipment
(make/model/vehicle-type/consumption-type enriched, SARS eligibility class),
DimLocation, DimProduct, DimCostCentre (492 distinct accounting combos),
DimEligibleActivity (fn_GetStorageReportLive patterns), DimSARSUsageType,
DimRefundRate (2020 policy evidence rates).

**Facts:** FactFuelTransaction (325,504), FactFuelDelivery (2,153),
FactMeterReading (139,123), FactEquipmentTrip (778,254), FactLocationVolume
(27,293), FactStorageLogbook (295,509), FactFuelUsageClassification (282,793),
FactDieselRefundClaim (44 claim months).

**Validation:** issued litres and delivery volumes reconcile exactly to source
(290,557,288.29 L / 83,566,650.10 L). `dw.vw_DataQuality` surfaces real issues:
1,728 duplicate FuelEventIds, 14,746 issues > 1.5× tank size, 203,309 usage
rows with RegNumbers absent from the equipment master, 288 non-positive
delivery volumes.

**SARS refund calc** (per claim month): `eligible = total − non-eligible`,
`qualifying = eligible × 80%`, `refund R = qualifying × rate ÷ 100`.
Example from the built data, 2022-07: 3,088,780.8 L eligible → R8,623,875.99
at 349c/L. **Rates are the 2020 policy examples from the evidence PDF — update
`dw.DimRefundRate` with current SARS rates before any real claim.**

## Azure

Resource group `rg-anglo-mining-dw` (southafricanorth): ADLS Gen2
`stanglominingdw01` (`raw` TSV / `curated` Parquet), Data Factory
`adf-anglo-mining-dw` with pipeline `pl_raw_to_curated` (parameterised ForEach
copy, TSV → snappy Parquet). Resource names are unchanged internal
infrastructure identifiers — created before the Kalahari Petroleum rebrand and
kept as-is since Azure resource groups can't be renamed in place. See
`azure/AZURE_ARCHITECTURE.md`; kill switch: `az group delete --name rg-anglo-mining-dw --yes`.

## Local-first

Everything runs without Azure: SQL Server DW (localhost) → `data_export\` TSVs
→ `curated_local\dw\` Parquet (`python sql/03_build_local_parquet.py`,
incremental) → local Qlik script variant. Azure is a mirror of the same
layout, not a dependency.

**Scope note:** the source DB is a full fleet-operations ERP, not just fuel —
haulage/material movement (datTripRecord.MaterialType), geospatial telemetry
(CoordRef, EquipmentTripTrace, Geofence), SAP integration staging, machine
activity, and fuel-price/levy audits. This DW models the fuel + SARS refund
lens; haulage/geofence/SAP facts are natural extensions.

**Known source-data quirk:** one lstEquipment row had a tab embedded in
RegNumber (cleaned in dw and stripped defensively in the build script);
usage-logbook text contains literal `"` characters, so all parsers are
configured with quoting disabled (ADF `quoteChar:""`, pandas `QUOTE_NONE`).

## Qlik Sense

**The app is live**: "Kalahari Petroleum - Fuel & Diesel Refund" on the tenant, built
end-to-end via `qlik-cli` (data loaded, 14 master measures, 6 sheets with real charts,
every KPI verified against the reconciled warehouse totals — e.g. Litres Issued shows
exactly 290,557,288). See `qlik/QLIK_APP_GUIDE.md` for the exact commands used and for
rebuilding it from scratch. Model avoids Qlik circular references by concatenating the
five transactional facts into one table with `FactType`, keeping the month-grain refund
claims as a labelled data island.

## Repository

Pushed to `github.com/anthonyapollis/KalahariPetroleum_DW_Azure_Qlik` (private).
Plain git, no Git LFS — see "Data availability" above for why, and the
[v1.0-data release](https://github.com/anthonyapollis/KalahariPetroleum_DW_Azure_Qlik/releases/tag/v1.0-data)
for the 3 files too large for the repo itself. No Azure secrets are
committed: the Qlik cloud script ships with a blank SAS placeholder (see
`qlik/QLIK_APP_GUIDE.md` to regenerate one), and `azure/*.key` /
`qlik/raw_container_sas_*.txt` are gitignored.
