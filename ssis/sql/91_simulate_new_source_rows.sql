/*
  Incremental-load test without writing to the source ERP.

  Removes the newest N rows of dw.FactFuelTransaction and rewinds its watermark to the
  highest remaining source id, which is exactly the warehouse state before those N
  source rows existed. The next KAL_Master run must then:
    - load exactly N fact rows (no duplicates: SourceAFSRecordId is UNIQUE)
    - leave FactFuelDelivery / FactMeterReading untouched (0 rows read)
    - report 0 updates from the dimension MERGEs
  and 90_parity_with_original_dw.sql must pass again.

  sqlcmd -S localhost -E -i 91_simulate_new_source_rows.sql -v NewRows=5000
*/
SET NOCOUNT ON;
USE KalahariDW_SSIS;

DELETE f
FROM dw.FactFuelTransaction f
WHERE f.SourceAFSRecordId IN (SELECT TOP ($(NewRows)) SourceAFSRecordId
                              FROM dw.FactFuelTransaction ORDER BY SourceAFSRecordId DESC);
PRINT CONCAT('Removed ', @@ROWCOUNT, ' newest fact rows');

UPDATE etl.Watermark
   SET LastSourceId = (SELECT MAX(SourceAFSRecordId) FROM dw.FactFuelTransaction), UpdatedAt = SYSDATETIME()
 WHERE TableName = 'dw.FactFuelTransaction';

SELECT TableName, LastSourceId FROM etl.Watermark;
SELECT COUNT_BIG(*) AS fact_rows_now FROM dw.FactFuelTransaction;
