# Migrating an SSIS + SQL Server + tabular estate to Microsoft Fabric

A migration note for the three Biml-generated SSIS projects in this portfolio. It is written the
way I would approach a long-lived client environment: keep the business running, move one
pattern at a time, and prove each step against numbers the business already trusts.

| Project | SSIS pattern | Repo |
|---|---|---|
| Kalahari Petroleum | metadata-driven dimension MERGE + watermark-incremental facts, SSAS tabular model with dynamic RLS | [`ssis/`](../ssis), [`tabular/`](../tabular) |
| Libstar | file ingestion (gzip + ForEach loop), rule-table cleansing, quarantine, reconciliation gate | [Libstar-Product-Analytics/ssis](https://github.com/anthonyapollis/Libstar-Product-Analytics/tree/master/ssis) |
| Lyra Wellbeing | SCD Type 2 dimension from daily snapshots | [Lyra-Analytics-Project/ssis](https://github.com/anthonyapollis/Lyra-Analytics-Project/tree/main/ssis) |

## 1. Principles

1. **Parity before retirement.** Every SSIS package already has a parity or reconciliation check
   (`90_parity_with_original_dw.sql`, `dw.vw_kpi_summary`, `expected_scd2_results.json`). The Fabric
   version runs in parallel and must match those checks before the SSIS job is switched off.
2. **Move patterns, not packages.** A 20-year estate has hundreds of packages but a small number of
   patterns. Metadata-driven Biml makes that visible: one list entry per table. The same metadata
   drives the Fabric pipelines.
3. **Keep the audit trail.** `etl.PackageRun` (start, end, rows read/written/rejected, error text)
   carries over as a Warehouse table written by every pipeline, so support runbooks keep working.
4. **Lift-and-shift is a bridge, not a destination.** Packages that are expensive to rewrite can run
   unchanged on an Azure-SSIS integration runtime (Azure Data Factory) while their neighbours move.

## 2. Pattern mapping

| SSIS today | Fabric target | Notes |
|---|---|---|
| Execute SQL: run log start/end, OnError handler | Pipeline *Script* / *Stored procedure* activities on success and failure paths writing `etl.PackageRun` | Pipeline run ID replaces `System::ExecutionInstanceGUID` |
| `etl.Config` table + package parameters | Pipeline parameters + *Lookup* activity on a config table; *variable libraries* for per-workspace values | Same "parameter wins, else config" rule |
| Dimension: source query → `stg` → generated `MERGE` (Kalahari) | *Copy data* to Warehouse staging → stored procedure with `MERGE` (or `UPDATE` + `INSERT` where `MERGE` is unavailable) | Generate the procedures from the same metadata that generates the Biml |
| Fact: watermark → Lookup surrogate keys → fast load (Kalahari) | *Lookup* watermark → *Copy data* with `WHERE Id > @{watermark}` → T-SQL `INSERT … SELECT` joining dimensions → update watermark | Surrogate-key lookups become set-based joins, which is faster and easier to test |
| Flat-file ingestion + gzip Script Task (Libstar) | OneLake lakehouse `Files/` landing; *Copy data* reads `.csv.gz` natively (no script needed) | Retire the Script Task |
| Derived Column + Lookup cleansing rules, Conditional Split to quarantine (Libstar) | *Dataflow Gen2* for analyst-maintained rules, or a Spark notebook for the 5M-row volume; rule tables stay as tables | Quarantine table and `reject_reason` are kept unchanged, so the reject breakdown can be compared 1:1 |
| Reconciliation gate that `THROW`s before publish (Libstar) | *If condition* activity on a reconciliation query; fail the pipeline before the publish activity | |
| SCD Type 2: hash compare, expire + insert in one transaction (Lyra) | Warehouse stored procedure run by the pipeline (the same T-SQL), or Delta `MERGE` in a notebook | Unique "one current row" rule: enforce with a post-load check where filtered unique indexes are unavailable |
| SSAS Tabular model, DAX measures, roles (Kalahari) | Fabric semantic model in Direct Lake (or Import) on the Warehouse; measures and roles move via Tabular Editor / TMDL | Dynamic RLS with `USERNAME()` becomes `USERPRINCIPALNAME()` against Entra ID accounts |
| SQL Agent schedules | Pipeline schedules / triggers; `Invoke pipeline` for master-child order | |
| Project deployment (`.ispac`, SSIS catalog) | Git integration + deployment pipelines (Dev → Test → Prod) | |

## 3. Fabric Warehouse T-SQL differences to plan for

Verified in practice while moving a dbt project from DuckDB to a Fabric Warehouse
([red-yellow-salesforce-handoff](https://github.com/anthonyapollis/red-yellow-salesforce-handoff/tree/analytics-platform)).
Feature support changes often, so confirm each item against current documentation for the tenant's region.

- Warehouse tables do not accept `nvarchar`; use `varchar` with a UTF-8 collation. `datename()` returns `nvarchar`, so cast it.
- No recursive CTEs, no `GROUP BY` ordinals, no `JOIN … USING`, no `ORDER BY` inside a view or table definition.
- `bit` comparisons must be explicit (`= 0` / `= 1`).
- `datepart(weekday, …)` depends on `DATEFIRST`; do not rely on the server default.
- Comparisons ignore trailing spaces in `=` and `IN`. A hash does not. The Kalahari cost-centre key hit exactly this
  (8,549 transactions differed only by case or trailing space) and now normalises before hashing.
- Filtered indexes and `IDENTITY` behave differently or may be unavailable: generate surrogate keys in the load
  procedure and keep uniqueness checks as explicit tests.

## 4. Phased plan

| Phase | Scope | Exit criterion |
|---|---|---|
| 0. Inventory | Export every package to Biml (BimlExpress *Convert SSIS packages to Biml*), classify by pattern, record owners and schedules | Pattern count and package-to-pattern map agreed |
| 1. Land | OneLake landing + Copy activities feeding the existing SQL Server staging tables | Staging row counts identical for two weeks |
| 2. Warehouse | Dimension and fact procedures in the Fabric Warehouse, running in parallel with SSIS | All parity checks pass daily |
| 3. Semantic model | Direct Lake model with the same measures and roles | DAX results equal the SSAS model for a fixed query set |
| 4. Cut-over | Switch reports, disable SQL Agent jobs, keep SSIS packages deployable for one release cycle | No open reconciliation differences |
| 5. Decommission | Remove SSIS jobs and on-prem objects no longer referenced | Sign-off from data owners |

## 5. Support considerations during migration

- Two systems run in parallel; the run log records which engine produced each load.
- Reconciliation differences are logged as incidents with a root cause, not patched in reports.
- Access follows least privilege: pipeline identities read sources; only the load procedures write the warehouse.
