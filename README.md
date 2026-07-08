# Anglo Mining Fuel — SQL DW → Azure Data Factory → Qlik Sense

**[Open `index.html`](index.html) for the interactive data story** — "Fuelling a Mining Giant."
Repo: [github.com/anthonyapollis/AngloMiningFuel_DW_Azure_Qlik](https://github.com/anthonyapollis/AngloMiningFuel_DW_Azure_Qlik) (private) ·
[PDF report](reports/Anglo_Mining_Fuel_Data_Story.pdf) · [Excel workbook](reports/Anglo_Mining_Fuel_Data_Story.xlsx)

End-to-end analytics build over the Anglo mining fuel / petroleum-logbook ERP
(`AngloData_QA_20220825_1820`, local SQL Server) with SARS diesel-refund
(Rebate Item 670.04) business logic from the Gmail evidence pack.

Built 2026-07-06/07. ~23.7M rows shipped through the full pipeline:
1.85M DW fact rows + the 21.9M-row dbo.CoordRef geo reference
(1 GB TSV → 346 MB snappy Parquet in curated). CoordRef re-export is opt-in
(`02_export_dw_to_tsv.ps1 -IncludeCoordRef`, ~26 min of bcp on this machine).

## What's here

| Path | What |
|---|---|
| [`index.html`](index.html) | **The data-story ebook** — "Fuelling a Mining Giant" (open directly in a browser) |
| [`reports/Anglo_Mining_Fuel_Data_Story.pdf`](reports/Anglo_Mining_Fuel_Data_Story.pdf) | Print render of the ebook |
| [`reports/Anglo_Mining_Fuel_Data_Story.xlsx`](reports/Anglo_Mining_Fuel_Data_Story.xlsx) | 13-sheet workbook: KPIs, refund claims, fleet/haulage aggregates, data quality, native charts |
| [`sql/01_create_load_dw_full.sql`](sql/01_create_load_dw_full.sql) | Complete re-runnable star-schema build: 8 dimensions, 8 facts, 5 analysis views, FKs + indexes, in schema `dw` |
| [`sql/02_export_dw_to_tsv.ps1`](sql/02_export_dw_to_tsv.ps1) | bcp export of all DW tables + CoordRef to headered TSV |
| [`sql/03_build_local_parquet.py`](sql/03_build_local_parquet.py) | Local curated Parquet build (incremental; pandas QUOTE_NONE parser) |
| [`sql/04_export_analysis_csvs.ps1`](sql/04_export_analysis_csvs.ps1) | Reporting aggregates (refunds, fuel trends, fleet, haulage, DQ) → `data/analysis/*.csv` |
| [`sql/05_build_reports.py`](sql/05_build_reports.py) | Chart set (→ `data/charts/*.png`) + Excel workbook with native charts (→ `reports/*.xlsx`) |
| [`sql/06_build_ebook.py`](sql/06_build_ebook.py) | Builds `index.html` (charts embedded as base64) |
| [`data_export/`](data_export/) | The exported TSVs (source for both Azure and local curated) |
| [`curated_local/dw/`](curated_local/dw/) | **Local curated Parquet layer** — same layout as Azure `curated/dw/`; the project runs fully offline |
| [`azure/AZURE_ARCHITECTURE.md`](azure/AZURE_ARCHITECTURE.md) | Deployed resources, data flow, SHIR production pattern, cost + kill switch |
| [`azure/deploy_adf.ps1`](azure/deploy_adf.ps1), [`azure/run_pipeline.ps1`](azure/run_pipeline.ps1) | Re-deploy ADF artifacts / trigger + poll the pipeline |
| [`azure/adf/`](azure/adf/) | ADF dataset & pipeline definitions (TSV → Parquet ForEach copy) |
| [`qlik/anglo_mining_fuel_load_script.qvs`](qlik/anglo_mining_fuel_load_script.qvs) | Qlik Sense load script — cloud variant (ADLS via SAS) |
| [`qlik/anglo_mining_fuel_load_script_local.qvs`](qlik/anglo_mining_fuel_load_script_local.qvs) | Qlik load script — **local variant** (folder connection `AngloDW` → `data_export\`), same model |
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
copy, TSV → snappy Parquet). See `azure/AZURE_ARCHITECTURE.md`; kill switch:
`az group delete --name rg-anglo-mining-dw --yes`.

## Local-first

Everything runs without Azure: SQL Server DW (localhost) → `data_export\` TSVs
→ `curated_local\dw\` Parquet (`python sql/03_build_local_parquet.py`,
incremental) → local Qlik script variant. Azure is a mirror of the same
layout, not a dependency.

**Scope note:** the source DB is a full mining fleet-operations ERP, not just
fuel — haulage/material movement (datTripRecord.MaterialType), geospatial
telemetry (CoordRef, EquipmentTripTrace, Geofence), SAP integration staging,
machine activity, and fuel-price/levy audits. This DW models the fuel + SARS
refund lens; haulage/geofence/SAP facts are natural extensions.

**Known source-data quirk:** one lstEquipment row had a tab embedded in
RegNumber (cleaned in dw and stripped defensively in the build script);
usage-logbook text contains literal `"` characters, so all parsers are
configured with quoting disabled (ADF `quoteChar:""`, pandas `QUOTE_NONE`).

## Qlik Sense

Paste `qlik/anglo_mining_fuel_load_script.qvs` into a new app on the tenant,
add a container SAS (regenerate — the shipped placeholder is blank; see
`qlik/QLIK_APP_GUIDE.md`), reload. Model avoids Qlik circular references by
concatenating the five transactional facts into one table with `FactType`,
keeping the month-grain refund claims as a labelled data island.

## Repository / Git LFS

Pushed to `github.com/anthonyapollis/AngloMiningFuel_DW_Azure_Qlik` (private).
`dbo.CoordRef`'s TSV and Parquet exports (1 GB / 331 MB) are tracked via
[Git LFS](https://git-lfs.com) — everything else is plain git. Clone with
`git lfs install` done once, then a normal `git clone` pulls LFS content
automatically. No Azure secrets are committed: the Qlik cloud script ships
with a blank SAS placeholder (see `qlik/QLIK_APP_GUIDE.md` to regenerate one),
and `azure/*.key` / `qlik/raw_container_sas_*.txt` are gitignored.
