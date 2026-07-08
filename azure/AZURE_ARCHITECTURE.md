# Azure Architecture — Kalahari Petroleum Fleet Fuel DW

[← Back to project overview](../README.md) · [Data story](../index.html) · [Qlik app guide](../qlik/QLIK_APP_GUIDE.md)

*Kalahari Petroleum is a fictional company invented for this portfolio piece — see the
[README case-study note](../README.md). Resource and database names below (`rg-anglo-mining-dw`,
`AngloData_QA_20220825_1820`, etc.) are real, unchanged infrastructure identifiers created before
the rebrand; Azure resource groups can't be renamed in place.*

## Deployed resources (subscription "Azure subscription 1", tenant the-spot.tech)

| Resource | Name | Region | Notes |
|---|---|---|---|
| Resource group | `rg-anglo-mining-dw` | southafricanorth | everything lives here |
| Storage (ADLS Gen2) | `stanglominingdw01` | southafricanorth | Standard_LRS, HNS on |
| Containers | `raw`, `curated` | | raw = TSV landing, curated = Parquet |
| Data Factory | `adf-anglo-mining-dw` | southafricanorth | |
| ADF linked service | `ls_adls` | | account-key auth to the storage |
| ADF datasets | `ds_raw_tsv`, `ds_curated_parquet` | | parameterised by table name |
| ADF pipeline | `pl_raw_to_curated` | | ForEach + Copy, TSV → snappy Parquet |

## Data flow

```
SQL Server (DESKTOP-ES5HL78, AngloData_QA_20220825_1820)
  └─ dw star schema (01_create_load_dw_full.sql)
       └─ bcp export to TSV (02_export_dw_to_tsv.ps1)  ~23.7M rows total
            └─ azcopy → abfss://raw@stanglominingdw01/dw/
                 └─ ADF pl_raw_to_curated (ForEach Copy)
                      └─ abfss://curated@stanglominingdw01/dw/<Table>/<Table>.parquet
                           └─ Qlik Sense Cloud (SAS web-files or Azure Storage connector)
```

**Note on types:** the Copy activity does no schema mapping, so curated
Parquet columns are string-typed (values verified exact). Qlik casts with
`Num#()`/`Date#()` at load; if a typed lake is needed later, add a mapping
to the Copy activity or a Data Flow with a defined projection.

## Production pattern (documented, not deployed): direct on-prem pull

For scheduled incremental loads without the manual bcp/azcopy hop:

1. Install a **Self-Hosted Integration Runtime** on the SQL Server host
   (ADF → Manage → Integration runtimes → New → Self-Hosted; install MSI,
   register with the generated key).
2. Linked service `ls_onprem_sql` (SQL Server, Windows auth via SHIR).
3. Copy activity source = SQL query with watermark
   (`WHERE ModifyDate > @{pipeline().parameters.lastWatermark}`),
   sink = `ds_curated_parquet`. Watermark stored in a control table or
   pipeline variable; schedule trigger monthly to align with SARS claim periods.
4. Scale-out: the 21.9M-row CoordRef copies fine through one SHIR node;
   partition option "Physical partitions of table" if it grows.

## Cost control

Everything deployed is consumption/GB priced; at this data size expect
under R50/month (≈1.5 GB LRS storage + a few ADF activity runs).
Kill switch (deletes everything, irreversible):

```
az group delete --name rg-anglo-mining-dw --yes --no-wait
```

## Redeploy from scratch

`deploy_adf.ps1` in this folder recreates linked service, datasets and
pipeline from the JSON files after the resource group/storage/factory exist.
