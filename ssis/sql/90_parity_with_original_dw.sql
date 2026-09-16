/*
  Parity check: the SSIS incremental load (KalahariDW_SSIS) against the original one-shot
  rebuild (sql/01_create_load_dw_full.sql, schema dw in the source ERP database).

  Surrogate key VALUES differ between the two builds (both are identities), so the check
  compares row counts, measure totals and how many fact rows found each dimension member.

  sqlcmd -S localhost -E -i 90_parity_with_original_dw.sql -v SourceDb="AngloData_QA_20220825_1820"
*/
SET NOCOUNT ON;
USE KalahariDW_SSIS;

WITH checks AS (
    SELECT 'DimLocation rows' AS check_name, (SELECT COUNT_BIG(*) FROM dw.DimLocation) AS ssis, (SELECT COUNT_BIG(*) FROM [$(SourceDb)].dw.DimLocation) AS original
    UNION ALL SELECT 'DimProduct rows', (SELECT COUNT_BIG(*) FROM dw.DimProduct), (SELECT COUNT_BIG(*) FROM [$(SourceDb)].dw.DimProduct)
    UNION ALL SELECT 'DimEquipment rows', (SELECT COUNT_BIG(*) FROM dw.DimEquipment), (SELECT COUNT_BIG(*) FROM [$(SourceDb)].dw.DimEquipment)
    UNION ALL SELECT 'DimEquipment eligible', (SELECT COUNT_BIG(*) FROM dw.DimEquipment WHERE EligibilityClass = 'Eligible'), (SELECT COUNT_BIG(*) FROM [$(SourceDb)].dw.DimEquipment WHERE EligibilityClass = 'Eligible')
    UNION ALL SELECT 'DimCostCentre rows', (SELECT COUNT_BIG(*) FROM dw.DimCostCentre), (SELECT COUNT_BIG(*) FROM [$(SourceDb)].dw.DimCostCentre)
    UNION ALL SELECT 'FactFuelTransaction rows', (SELECT COUNT_BIG(*) FROM dw.FactFuelTransaction), (SELECT COUNT_BIG(*) FROM [$(SourceDb)].dw.FactFuelTransaction)
    UNION ALL SELECT 'FactFuelTransaction litres', (SELECT CAST(SUM(Litres) AS bigint) FROM dw.FactFuelTransaction), (SELECT CAST(SUM(Litres) AS bigint) FROM [$(SourceDb)].dw.FactFuelTransaction)
    UNION ALL SELECT 'FactFuelTransaction with equipment', (SELECT COUNT_BIG(EquipmentKey) FROM dw.FactFuelTransaction), (SELECT COUNT_BIG(EquipmentKey) FROM [$(SourceDb)].dw.FactFuelTransaction)
    UNION ALL SELECT 'FactFuelTransaction with location', (SELECT COUNT_BIG(LocationKey) FROM dw.FactFuelTransaction), (SELECT COUNT_BIG(LocationKey) FROM [$(SourceDb)].dw.FactFuelTransaction)
    UNION ALL SELECT 'FactFuelTransaction with product', (SELECT COUNT_BIG(ProductKey) FROM dw.FactFuelTransaction), (SELECT COUNT_BIG(ProductKey) FROM [$(SourceDb)].dw.FactFuelTransaction)
    UNION ALL SELECT 'FactFuelTransaction with cost centre', (SELECT COUNT_BIG(CostCentreKey) FROM dw.FactFuelTransaction), (SELECT COUNT_BIG(CostCentreKey) FROM [$(SourceDb)].dw.FactFuelTransaction)
    UNION ALL SELECT 'FactFuelTransaction eligible litres', (SELECT CAST(SUM(Litres) AS bigint) FROM dw.FactFuelTransaction WHERE EligibleActivityKey <> 99), (SELECT CAST(SUM(Litres) AS bigint) FROM [$(SourceDb)].dw.FactFuelTransaction WHERE EligibleActivityKey <> 99)
    UNION ALL SELECT 'FactFuelDelivery rows', (SELECT COUNT_BIG(*) FROM dw.FactFuelDelivery), (SELECT COUNT_BIG(*) FROM [$(SourceDb)].dw.FactFuelDelivery)
    UNION ALL SELECT 'FactFuelDelivery litres', (SELECT CAST(SUM(VolumeLitres) AS bigint) FROM dw.FactFuelDelivery), (SELECT CAST(SUM(VolumeLitres) AS bigint) FROM [$(SourceDb)].dw.FactFuelDelivery)
    UNION ALL SELECT 'FactMeterReading rows', (SELECT COUNT_BIG(*) FROM dw.FactMeterReading), (SELECT COUNT_BIG(*) FROM [$(SourceDb)].dw.FactMeterReading)
    UNION ALL SELECT 'FactMeterReading with equipment', (SELECT COUNT_BIG(EquipmentKey) FROM dw.FactMeterReading), (SELECT COUNT_BIG(EquipmentKey) FROM [$(SourceDb)].dw.FactMeterReading)
)
SELECT check_name, ssis, original, CASE WHEN ssis = original THEN 'PASS' ELSE 'DIFF' END AS result
FROM checks;

SELECT TableName, LastSourceId, UpdatedAt FROM etl.Watermark;
SELECT RunId, PackageName, Status, RowsRead, RowsWritten, DATEDIFF(second, StartTime, EndTime) AS seconds
FROM etl.PackageRun ORDER BY RunId;
