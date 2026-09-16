# Kalahari fuel warehouse: metadata-driven SSIS from Biml

The one-shot rebuild script [`sql/01_create_load_dw_full.sql`](../sql/01_create_load_dw_full.sql) turned into the
kind of load a long-lived Microsoft estate actually runs: **incremental SSIS packages**, generated from a single
[Biml](Kalahari.SSIS/Kalahari_SSIS.biml) file whose metadata list describes every dimension and fact.

| Generated package | Pattern |
|---|---|
| `KAL_Dim_DimLocation`, `KAL_Dim_DimProduct`, `KAL_Dim_DimEquipment`, `KAL_Dim_DimCostCentre` | source query → `stg.<Dim>` → generated `MERGE` into `dw.<Dim>` (Type 1 on the business key; updates only rows whose attributes changed, via `EXCEPT`) |
| `KAL_Fact_FactFuelTransaction`, `KAL_Fact_FactFuelDelivery`, `KAL_Fact_FactMeterReading` | read `etl.Watermark` → extract only source rows above it → Lookup transforms for surrogate keys → fast load → move the watermark |
| `KAL_Master` | all dimensions, then all facts |

Adding a table is a new entry in the metadata list, not a new hand-built package. Every package logs to
`etl.PackageRun` (rows read/written, duration, error text on failure). The source ERP database is read-only.

## Result: parity with the original warehouse

[`sql/90_parity_with_original_dw.sql`](sql/90_parity_with_original_dw.sql) compares the SSIS-loaded
`KalahariDW_SSIS` with the original `dw` schema. Surrogate key values differ between two builds, so it checks
row counts, measure totals and how many fact rows found each dimension:

| Check | SSIS | Original | |
|---|---:|---:|---|
| DimLocation / DimProduct / DimEquipment / DimCostCentre rows | 28 / 10 / 2,256 / 492 | 28 / 10 / 2,256 / 492 | PASS |
| DimEquipment classed SARS-eligible | 853 | 853 | PASS |
| FactFuelTransaction rows / litres | 325,504 / 290,557,288 | 325,504 / 290,557,288 | PASS |
| … with equipment / location / product key | 325,504 each | 325,504 each | PASS |
| … with cost-centre key | 282,349 | 282,349 | PASS |
| … eligible litres | 249,194,117 | 249,194,117 | PASS |
| FactFuelDelivery rows / litres | 2,153 / 83,566,650 | 2,153 / 83,566,650 | PASS |
| FactMeterReading rows / with equipment | 139,123 / 139,123 | 139,123 / 139,123 | PASS |

**Root cause found on the way.** The source cost-centre extract has no key, so the dimension's business key is a
hash of its five attributes. The first run matched 8,549 fewer transactions to a cost centre than the original.
The original joined on `=`, and SQL Server's case-insensitive collation also ignores trailing spaces, so
`'ABC'` equals `'abc '`. A hash does not. A second issue was that `NULL` and `''` hashed alike (468 hashes for
492 cost centres). The hash input is now `NULL`-marked, upper-cased and right-trimmed: 492 unique keys and
282,349 matched transactions, identical to the original.

## Incremental behaviour

[`sql/91_simulate_new_source_rows.sql`](sql/91_simulate_new_source_rows.sql) removes the newest 5,000 transaction
facts and rewinds the watermark. That is the warehouse exactly as it was before those 5,000 source rows existed,
with no writes to the source ERP. `KAL_Master` was then run twice (from `etl.PackageRun`):

| Package | Run after 5,000 "new" source rows | Run with nothing new |
|---|---|---|
| `KAL_Fact_FactFuelTransaction` | read **5,000**, wrote **5,000** (5 s) | read 0, wrote 0 |
| `KAL_Fact_FactFuelDelivery` | read 0, wrote 0 | read 0, wrote 0 |
| `KAL_Fact_FactMeterReading` | read 0, wrote 0 | read 0, wrote 0 |
| `KAL_Dim_*` (4 packages) | staged all members, MERGE changed 0 | staged all members, MERGE changed 0 |

After both runs all 16 parity checks pass again. `SourceAFSRecordId` is `UNIQUE` in the warehouse, so a
watermark mistake would fail loudly rather than duplicate litres.

A full first load of all eight packages takes about 2 minutes from the Visual Studio debugger; the incremental
run above took 82 seconds, most of it dimension staging.

## Run it

```powershell
sqlcmd -S localhost -E -i ssis\sql\00_setup_KalahariDW_SSIS.sql   # target, static dimensions, watermark + audit tables
```

1. Open `ssis\Kalahari.SSIS.sln` in Visual Studio with SSDT and BimlExpress.
2. Right-click `Kalahari_SSIS.biml` → **Generate SSIS Packages**.
3. Right-click `KAL_Master.dtsx` → **Execute Package** (or run the built `.ispac` with DTExec where the Integration
   Services feature is installed).
4. `sqlcmd -S localhost -E -i ssis\sql\90_parity_with_original_dw.sql -v SourceDb="AngloData_QA_20220825_1820"`

The semantic layer on top of this warehouse is in [`../tabular`](../tabular); the plan for moving this estate to
Microsoft Fabric is in [`../docs/SSIS_TO_FABRIC_MIGRATION.md`](../docs/SSIS_TO_FABRIC_MIGRATION.md).
