# Kalahari fuel tabular model (SSAS Tabular, DAX, dynamic RLS)

A SQL Server Analysis Services tabular model (compatibility level 1400) over the star schema that the
[Biml-generated SSIS packages](../ssis) load into `KalahariDW_SSIS`. It is the layer a Power BI or Excel
user connects to: named measures, a marked date table, and row-level security.

## Model

```
                 Date (marked date table)            Eligible Activity
                  │        │         │                      │
     Fuel Transactions   Fuel Deliveries   Meter Readings ──┘ (transactions only)
     (one AFS issue)     (one delivery)    (one meter reading)
      │   │   │   │         │     │           │
 Equipment Location Product Cost Centre        Equipment
            └───── shared with deliveries ─────┘
```

- **Three facts at three grains**, joined only through **conformed dimensions** (Date, Location, Product,
  Equipment). `Delivered minus Issued (L)` compares deliveries with issues without either fact knowing about
  the other: the Kimball bus matrix working in DAX.
- Single-direction, one-to-many relationships from each fact to its dimensions, so no ambiguous filter paths.
  Eligible Activity relates to transactions only; relating it through Equipment as well would create a second path.
- `Date` is marked as a date table on a continuous calendar, so time intelligence (`SAMEPERIODLASTYEAR`,
  `TOTALYTD`, `DATESINPERIOD`) works.
- Keys and raw numeric columns are hidden; users see measures and descriptive attributes.

## Measures

| Measure | DAX idea |
|---|---|
| Litres Issued, Fuel Transactions, Avg Litres per Transaction | base aggregations |
| Eligible Litres, Eligible Litres %, Qualifying Claim Litres | `CALCULATE` with `KEEPFILTERS` on the SARS eligibility status; 80% on-land factor |
| Litres Issued PY, YoY %, YTD, Rolling 3M | time intelligence on the marked date table |
| Litres Delivered | excludes deliveries the source flagged as duplicates |
| Delivered minus Issued (L) | tank reconciliation across two fact grains |
| Meter Units Recorded, Litres per Meter Unit | fuel efficiency against odometer / hour meters |
| Transactions Missing Equipment | data-quality measure for the support team |

## Row-level security

| Role | Rule |
|---|---|
| **Site Managers** (dynamic) | `CONTAINS ( 'Security User Location', [UserName], USERNAME (), [LocationKey], Location[LocationKey] )` on `Location`. The filter flows to transactions and deliveries. |
| **Fleet Finance** (static) | reads everything, for SARS diesel-refund reporting |

Access lives in data (`sec.UserLocation`), not in the model: granting a manager a new site is an `INSERT`,
with no model redeploy. In Power BI or Fabric the same pattern uses `USERPRINCIPALNAME()` against Entra ID.

## Verified: model results equal the SQL warehouse

`deploy_and_test.ps1` deploys with TMSL, processes, then compares DAX against SQL. Output from 16 September 2026:

```
DAX measures vs SQL warehouse
PASS Litres Issued                        model 290,557,288.3   sql 290,557,288.3
PASS Fuel Transactions                    model     325,504.0   sql     325,504.0
PASS Eligible Litres                      model 249,194,118.0   sql 249,194,118.0
PASS Litres Delivered (non-duplicate)     model  83,566,650.1   sql  83,566,650.1
PASS Meter Units Recorded                 model   4,009,077.7   sql   4,009,077.7
PASS Transactions Missing Equipment       model           0.0   sql           0.0
Time intelligence
PASS Litres Issued 2021                   model  92,081,753.8   sql  92,081,753.8
PASS Litres Issued PY (2020)              model  81,317,128.2   sql  81,317,128.2
Row-level security: role 'Site Managers'
PASS Locations visible to role            model           3.0   sql           3.0
PASS Litres visible to role               model 221,566,500.8   sql 221,566,500.8
PASS Role 'Fleet Finance' sees all litres model 290,557,288.3   sql 290,557,288.3
All checks passed
```

The RLS test connects with `Roles=Site Managers`, so `USERNAME()` resolves to the caller and only the three
locations mapped to that login in `sec.UserLocation` are visible.

## Deploy

```powershell
sqlcmd -S localhost -E -i tabular\sql\01_rls_security_table.sql -v DemoUser="$env:USERDOMAIN\$env:USERNAME"
powershell.exe -File tabular\deploy_and_test.ps1          # Windows PowerShell 5.1 (AMO / ADOMD)
```

`Kalahari.Tabular/Model.bim` also opens in Tabular Editor or a Visual Studio Analysis Services project.
