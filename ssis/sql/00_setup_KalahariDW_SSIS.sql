/*
================================================================================
KALAHARI PETROLEUM - SSIS (Biml) incremental load target
================================================================================
Target for the Biml-generated SSIS packages in ssis/Kalahari.SSIS. The star schema
matches sql/01_create_load_dw_full.sql, but instead of one drop-and-rebuild script
the warehouse is loaded the way a long-lived production estate is:

  dimensions  source query -> stg.<Dim> (truncate + load) -> MERGE into dw.<Dim> (Type 1)
  facts       only source rows with Id above etl.Watermark are extracted; surrogate keys
              come from Lookup transforms; the watermark moves after a successful load
  audit       etl.PackageRun (one row per package run, row counts, error text)

The source ERP database is only ever read. Static reference dimensions (date,
SARS activity, usage type, refund rate) are seeded here, as in the original script.
Re-runnable: drops and recreates this database's objects.
================================================================================
*/
IF DB_ID('KalahariDW_SSIS') IS NULL CREATE DATABASE KalahariDW_SSIS;
GO
-- staging/warehouse loads are re-runnable from source, so point-in-time log backups are not needed
ALTER DATABASE KalahariDW_SSIS SET RECOVERY SIMPLE;
GO
USE KalahariDW_SSIS;
GO
IF SCHEMA_ID('etl') IS NULL EXEC('CREATE SCHEMA etl');
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
GO

/* ---------------- audit + watermark ---------------- */
IF OBJECT_ID('etl.PackageRun') IS NULL
CREATE TABLE etl.PackageRun (
    RunId          int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    PackageName    nvarchar(200)  NOT NULL,
    ExecutionGuid  nvarchar(50)   NULL,
    StartTime      datetime2(0)   NOT NULL DEFAULT SYSDATETIME(),
    EndTime        datetime2(0)   NULL,
    Status         varchar(20)    NOT NULL DEFAULT 'Running',
    RowsRead       bigint         NULL,
    RowsWritten    bigint         NULL,
    RowsRejected   bigint         NULL,
    Message        nvarchar(4000) NULL
);
DROP TABLE IF EXISTS etl.Watermark;
CREATE TABLE etl.Watermark (
    TableName     varchar(100) NOT NULL PRIMARY KEY,
    LastSourceId  int          NOT NULL DEFAULT 0,
    UpdatedAt     datetime2(0) NOT NULL DEFAULT SYSDATETIME()
);
INSERT INTO etl.Watermark (TableName) VALUES ('dw.FactFuelTransaction'), ('dw.FactFuelDelivery'), ('dw.FactMeterReading');
GO

/* ---------------- drop in dependency order ---------------- */
DROP TABLE IF EXISTS dw.FactFuelTransaction, dw.FactFuelDelivery, dw.FactMeterReading;
DROP TABLE IF EXISTS dw.DimRefundRate, dw.DimSARSUsageType, dw.DimCostCentre, dw.DimProduct, dw.DimLocation, dw.DimEquipment;
DROP TABLE IF EXISTS dw.DimEligibleActivity, dw.DimDate;
DROP TABLE IF EXISTS stg.DimCostCentre, stg.DimProduct, stg.DimLocation, stg.DimEquipment;
GO

/* ---------------- static reference dimensions (as in sql/01_create_load_dw_full.sql) ---------------- */
CREATE TABLE dw.DimDate (
    DateKey              int          NOT NULL PRIMARY KEY,   -- yyyymmdd
    FullDate             date         NOT NULL,
    [Year]               smallint     NOT NULL,
    [Quarter]            tinyint      NOT NULL,
    MonthNumber          tinyint      NOT NULL,
    [MonthName]          varchar(20)  NOT NULL,
    YearMonth            char(7)      NOT NULL,                -- yyyy-MM
    DayOfMonth           tinyint      NOT NULL,
    [DayName]            varchar(20)  NOT NULL,
    IsWeekend            bit          NOT NULL,
    FiscalYearSA         varchar(9)   NOT NULL,                -- Apr-Mar e.g. FY2021/22
    SeasonSouthernAfrica varchar(10)  NOT NULL
);
GO

/* Calendar covers all source data (2009) through end 2023. */
;WITH n AS (
    SELECT TOP (5844) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_objects a CROSS JOIN sys.all_objects b
),
d AS (
    SELECT DATEADD(day, i, CAST('2009-01-01' AS date)) AS dt FROM n
)
INSERT INTO dw.DimDate
SELECT
    YEAR(dt)*10000 + MONTH(dt)*100 + DAY(dt),
    dt,
    YEAR(dt),
    DATEPART(quarter, dt),
    MONTH(dt),
    DATENAME(month, dt),
    CONVERT(char(7), dt, 126),
    DAY(dt),
    DATENAME(weekday, dt),
    CASE WHEN DATEPART(weekday, dt) IN (1,7) THEN 1 ELSE 0 END,
    CASE WHEN MONTH(dt) >= 4
         THEN CONCAT('FY', YEAR(dt), '/', RIGHT(YEAR(dt)+1, 2))
         ELSE CONCAT('FY', YEAR(dt)-1, '/', RIGHT(YEAR(dt), 2)) END,
    CASE WHEN MONTH(dt) IN (12,1,2) THEN 'Summer'
         WHEN MONTH(dt) IN (3,4,5)  THEN 'Autumn'
         WHEN MONTH(dt) IN (6,7,8)  THEN 'Winter'
         ELSE 'Spring' END
FROM d
WHERE dt <= '2023-12-31';
GO

/* SARS eligible-activity classification, from fn_GetStorageReportLive logic
   found in the Gmail SQL evidence (pattern -> SARS activity description). */
CREATE TABLE dw.DimEligibleActivity (
    EligibleActivityKey int          NOT NULL PRIMARY KEY,
    ActivityCodePattern varchar(20)  NOT NULL,
    ActivityDescription varchar(300) NOT NULL,
    EligibilityStatus   varchar(30)  NOT NULL
);
INSERT INTO dw.DimEligibleActivity VALUES
 (1 ,'Waste%','Removal of waste products and disposal of mining operations','Eligible'),
 (2 ,'LGO%'  ,'Transport on mining site of ore or substances containing minerals for processing/recovery','Eligible'),
 (3 ,'VLGO%' ,'Transport on mining site of ore or substances containing minerals for processing/recovery','Eligible'),
 (4 ,'HGO%'  ,'Transport on mining site of ore or substances containing minerals for processing/recovery','Eligible'),
 (5 ,'MGO%'  ,'Transport on mining site of ore or substances containing minerals for processing/recovery','Eligible'),
 (6 ,'G1%'   ,'Transport on mining site of ore or substances containing minerals for processing/recovery','Eligible'),
 (7 ,'HLG%'  ,'Transport on mining site of ore or substances containing minerals for processing/recovery','Eligible'),
 (8 ,'LLG%'  ,'Transport on mining site of ore or substances containing minerals for processing/recovery','Eligible'),
 (9 ,'OG2%'  ,'Transport on mining site of ore or substances containing minerals for processing/recovery','Eligible'),
 (10,'L/HR'  ,'Equipment metered per operating hour (mining equipment)','Eligible - Mining'),
 (99,'%'     ,'Unclassified / other activity','Ineligible');
GO

/* SARS usage types + rate-change factors from the policy PDF evidence. */
CREATE TABLE dw.DimSARSUsageType (
    SARSUsageTypeKey      int           NOT NULL PRIMARY KEY,
    UsageTypeName         varchar(60)   NOT NULL,
    Sector                varchar(40)   NOT NULL,
    QualifyingPercentage  decimal(5,2)  NULL,     -- evidenced only for On Land
    RateChangeFactor      decimal(10,5) NOT NULL
);
INSERT INTO dw.DimSARSUsageType VALUES
 (1,'On Land (Farming, Mining & Forestry)','Primary - On Land',80.00,0.95587),
 (2,'Offshore'                            ,'Offshore'         ,NULL ,0.95551),
 (3,'Electricity Generation Plants'       ,'Electricity'      ,NULL ,0.95578),
 (4,'Rail & Harbour Services'             ,'Rail & Harbour'   ,NULL ,0.95652);
GO

/* Refund rates (cents per litre) - 2020 policy example values from evidence.
   EffectiveFrom for the "previous" rate is assumed 2019-04-01 (policy shows
   the change at 1 April 2020); update when current SARS rates are sourced. */
CREATE TABLE dw.DimRefundRate (
    RefundRateKey            int           IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SARSUsageTypeKey         int           NOT NULL REFERENCES dw.DimSARSUsageType(SARSUsageTypeKey),
    EffectiveFromDate        date          NOT NULL,
    EffectiveToDate          date          NULL,
    RefundRateCentsPerLitre  decimal(10,2) NOT NULL,
    SourceNote               varchar(200)  NOT NULL
);
INSERT INTO dw.DimRefundRate (SARSUsageTypeKey, EffectiveFromDate, EffectiveToDate, RefundRateCentsPerLitre, SourceNote) VALUES
 (1,'2019-04-01','2020-03-31',333.60,'SARS policy PDF example - previous rate'),
 (1,'2020-04-01',NULL        ,349.00,'SARS policy PDF example - rate after 1 Apr 2020'),
 (2,'2019-04-01','2020-03-31',537.00,'SARS policy PDF example - previous rate'),
 (2,'2020-04-01',NULL        ,562.00,'SARS policy PDF example - rate after 1 Apr 2020'),
 (3,'2019-04-01','2020-03-31',367.50,'SARS policy PDF example - previous rate'),
 (3,'2020-04-01',NULL        ,384.50,'SARS policy PDF example - rate after 1 Apr 2020'),
 (4,'2019-04-01','2020-03-31',198.00,'SARS policy PDF example - previous rate'),
 (4,'2020-04-01',NULL        ,207.00,'SARS policy PDF example - rate after 1 Apr 2020');
GO

/* ---------------- dimensions loaded by SSIS (Type 1, business key = source id) ---------------- */
CREATE TABLE dw.DimEquipment (
    EquipmentKey            int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceEquipmentId       int           NOT NULL UNIQUE,
    AFSEquipmentId          int           NULL,
    FleetId                 nvarchar(100) NULL,
    RegNumber               nvarchar(100) NULL,
    EquipmentDescription    nvarchar(300) NULL,
    MakeName                nvarchar(50)  NULL,
    ModelName               nvarchar(100) NULL,
    VehicleTypeName         nvarchar(100) NULL,
    IsEligibleVehicleType   bit           NULL,
    ConsumptionTypeName     nvarchar(50)  NULL,
    TankSize                float         NULL,
    DecommissionDate        datetime      NULL,
    IsActive                bit           NULL,
    EligibleActivityKey     int           NULL REFERENCES dw.DimEligibleActivity(EligibleActivityKey),
    EligibilityClass        varchar(30)   NULL
);
CREATE TABLE dw.DimLocation (
    LocationKey         int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceLocationId    int           NOT NULL UNIQUE,
    AFSDepotId          int           NULL,
    LocationDescription nvarchar(300) NULL,
    IsFixed             bit           NULL,
    IsMobile            bit           NULL,
    Capacity            float         NULL,
    IsActive            bit           NULL
);
CREATE TABLE dw.DimProduct (
    ProductKey      int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceProductId int           NOT NULL UNIQUE,
    ProductName     nvarchar(200) NULL,
    IsFuel          bit           NULL,
    IsActive        bit           NULL
);
/* The source cost-centre extract has no key of its own, so the business key is a hash of its attributes. */
CREATE TABLE dw.DimCostCentre (
    CostCentreKey       int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CostCentreHash      binary(20)   NOT NULL UNIQUE,
    CostCentreName      varchar(200) NULL,
    ResponsibilityCode  varchar(200) NULL,
    BusinessRevenueCode varchar(200) NULL,
    TaxRebateCode       varchar(200) NULL,
    GlAccount           varchar(200) NULL
);
GO

/* staging copies: same columns, no surrogate key, no constraints */
SELECT TOP (0) SourceEquipmentId, AFSEquipmentId, FleetId, RegNumber, EquipmentDescription, MakeName, ModelName, VehicleTypeName,
       IsEligibleVehicleType, ConsumptionTypeName, TankSize, DecommissionDate, IsActive, EligibleActivityKey, EligibilityClass
INTO stg.DimEquipment FROM dw.DimEquipment;
SELECT TOP (0) SourceLocationId, AFSDepotId, LocationDescription, IsFixed, IsMobile, Capacity, IsActive INTO stg.DimLocation FROM dw.DimLocation;
SELECT TOP (0) SourceProductId, ProductName, IsFuel, IsActive INTO stg.DimProduct FROM dw.DimProduct;
SELECT TOP (0) CostCentreHash, CostCentreName, ResponsibilityCode, BusinessRevenueCode, TaxRebateCode, GlAccount INTO stg.DimCostCentre FROM dw.DimCostCentre;
GO

/* ---------------- facts loaded incrementally by SSIS ---------------- */
CREATE TABLE dw.FactFuelTransaction (   -- grain: one AFS fuel-issue transaction
    FuelTransactionKey  bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceAFSRecordId   int           NOT NULL UNIQUE,
    DateKey             int           NULL,
    TransactionDateTime datetime      NOT NULL,
    EquipmentKey        int           NULL,
    LocationKey         int           NULL,
    ProductKey          int           NULL,
    CostCentreKey       int           NULL,
    EligibleActivityKey int           NULL,
    Litres              float         NOT NULL,
    HoursOdoReading     float         NULL,
    CalculatedODO       float         NULL,
    FuelEventId         int           NULL,
    VoucherNumber       nvarchar(200) NULL,
    DeviceId            nvarchar(200) NULL,
    Pump                nvarchar(200) NULL,
    TransactionPlate    nvarchar(200) NULL,
    VehicleCategoryDescription nvarchar(200) NULL,
    IsActive            bit           NULL
);
CREATE TABLE dw.FactFuelDelivery (      -- grain: one tank/depot delivery
    FuelDeliveryKey        bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceFuelDeliveryId   int           NOT NULL UNIQUE,
    DateKey                int           NULL,
    DeliveryTime           datetime      NULL,
    LocationKey            int           NULL,
    ProductKey             int           NULL,
    VolumeLitres           float         NULL,
    AFSTankDeliveryEventId int           NULL,
    DocumentNumber         nvarchar(200) NULL,
    IsDuplicate            bit           NULL,
    IsActive               bit           NULL
);
CREATE TABLE dw.FactMeterReading (      -- grain: one odometer/hour meter reading
    MeterReadingKey       bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceMeterReadingId  int      NOT NULL UNIQUE,
    DateKey               int      NULL,
    ReadingDate           datetime NULL,
    PreviousReadingDate   datetime NULL,
    EquipmentKey          int      NULL,
    MeasuringPoint        int      NULL,
    ReadingDiff           float    NULL,
    CounterReading        float    NULL,
    PreviousReading       float    NULL,
    ConsumptionTypeId     int      NULL,
    ReadingTypeId         int      NULL,
    IsActive              bit      NULL
);
GO
