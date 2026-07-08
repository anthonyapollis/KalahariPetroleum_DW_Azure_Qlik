/*
================================================================================
ANGLO MINING FUEL / SARS DIESEL REFUND - COMPLETE SQL SERVER DATA WAREHOUSE
================================================================================
Database : AngloData_QA_20220825_1820 (QA copy - safe to build dw schema in)
Style    : Kimball star schema in schema [dw]
Sources  : dbo.datAFSRecord, dbo.datFuelDelivery, dbo.datMeterReading,
           dbo.datTripRecord, dbo.datLocationVolumeReading,
           dbo.cacheUsageLogbook, dbo.cacheStorageLogbook,
           dbo.lstEquipment/lstMake/lstModel/lstVehicleType/lstConsumptionType,
           dbo.lstLocation, dbo.lstProduct, dbo.CostCentre

SARS diesel refund logic (Rebate Item 670.04, Schedule 6, Customs & Excise Act)
comes from the Gmail evidence pack (Darryl/DieselCubed + SARS policy PDF):
  eligible_litres        = total_litres - non_eligible_litres
  qualifying_claim_litres = eligible_litres * 0.80          (on-land primary)
  refund_amount_rand     = qualifying_claim_litres * rate_c_per_l / 100
CAUTION: rates seeded in dw.DimRefundRate are the 2020 policy examples from
the evidence PDF. They are implementation evidence, NOT current tax advice.

Re-runnable: drops and rebuilds all dw objects. Never touches dbo sources.
================================================================================
*/

USE [AngloData_QA_20220825_1820];
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'dw')
    EXEC('CREATE SCHEMA dw');
GO

/* ---------- Drop views first, then facts, then dims ---------- */
DROP VIEW IF EXISTS dw.vw_MonthlyFuelSummary;
DROP VIEW IF EXISTS dw.vw_DieselRefundByMonth;
DROP VIEW IF EXISTS dw.vw_EquipmentFuelEfficiency;
DROP VIEW IF EXISTS dw.vw_TankReconciliation;
DROP VIEW IF EXISTS dw.vw_DataQuality;
GO
DROP TABLE IF EXISTS dw.FactDieselRefundClaim;
DROP TABLE IF EXISTS dw.FactFuelUsageClassification;
DROP TABLE IF EXISTS dw.FactStorageLogbook;
DROP TABLE IF EXISTS dw.FactLocationVolume;
DROP TABLE IF EXISTS dw.FactEquipmentTrip;
DROP TABLE IF EXISTS dw.FactMeterReading;
DROP TABLE IF EXISTS dw.FactFuelDelivery;
DROP TABLE IF EXISTS dw.FactFuelTransaction;
DROP TABLE IF EXISTS dw.DimRefundRate;
DROP TABLE IF EXISTS dw.DimSARSUsageType;
DROP TABLE IF EXISTS dw.DimCostCentre;
DROP TABLE IF EXISTS dw.DimProduct;
DROP TABLE IF EXISTS dw.DimLocation;
DROP TABLE IF EXISTS dw.DimEquipment;      -- references DimEligibleActivity, drop first
DROP TABLE IF EXISTS dw.DimEligibleActivity;
DROP TABLE IF EXISTS dw.DimDate;
GO

/* ================================================================
   DIMENSIONS
   ================================================================ */

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

/* Equipment enriched with make/model/vehicle-type/consumption-type names and
   the SARS eligibility classification applied to its fleet/reg code. */
CREATE TABLE dw.DimEquipment (
    EquipmentKey            int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceEquipmentId       int           NULL,
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
GO

INSERT INTO dw.DimEquipment (
    SourceEquipmentId, AFSEquipmentId, FleetId, RegNumber, EquipmentDescription,
    MakeName, ModelName, VehicleTypeName, IsEligibleVehicleType, ConsumptionTypeName,
    TankSize, DecommissionDate, IsActive, EligibleActivityKey, EligibilityClass
)
SELECT
    /* strip embedded tabs (seen in source lstEquipment) so TSV exports stay rectangular */
    e.Id, e.AFSEquipmentId,
    REPLACE(e.FleetId, CHAR(9), ' '),
    REPLACE(e.RegNumber, CHAR(9), ' '),
    REPLACE(e.EquipmentDescription, CHAR(9), ' '),
    mk.Name, md.Name, vt.Name, vt.IsEligible, ct.Name,
    e.TankSize, e.DecommissionDate, e.IsActive,
    ea.k,
    CASE WHEN ea.k = 99 THEN 'Ineligible' ELSE 'Eligible' END
FROM dbo.lstEquipment e
LEFT JOIN dbo.lstMake            mk ON mk.Id = e.MakeId
LEFT JOIN dbo.lstModel           md ON md.Id = e.ModelId
LEFT JOIN dbo.lstVehicleType     vt ON vt.Id = e.VehicleTypeId
LEFT JOIN dbo.lstConsumptionType ct ON ct.Id = e.ConsumptionTypeId
CROSS APPLY (SELECT CASE
    WHEN e.FleetId LIKE 'Waste%' OR e.RegNumber LIKE 'Waste%' THEN 1
    WHEN e.FleetId LIKE 'VLGO%'  OR e.RegNumber LIKE 'VLGO%'  THEN 3
    WHEN e.FleetId LIKE 'LGO%'   OR e.RegNumber LIKE 'LGO%'   THEN 2
    WHEN e.FleetId LIKE 'HGO%'   OR e.RegNumber LIKE 'HGO%'   THEN 4
    WHEN e.FleetId LIKE 'MGO%'   OR e.RegNumber LIKE 'MGO%'   THEN 5
    WHEN e.FleetId LIKE 'G1%'    OR e.RegNumber LIKE 'G1%'    THEN 6
    WHEN e.FleetId LIKE 'HLG%'   OR e.RegNumber LIKE 'HLG%'   THEN 7
    WHEN e.FleetId LIKE 'LLG%'   OR e.RegNumber LIKE 'LLG%'   THEN 8
    WHEN e.FleetId LIKE 'OG2%'   OR e.RegNumber LIKE 'OG2%'   THEN 9
    WHEN ct.Name = 'L/HR'                                     THEN 10
    ELSE 99 END AS k) ea;

CREATE UNIQUE INDEX UX_DimEquipment_SourceId ON dw.DimEquipment(SourceEquipmentId);
GO

CREATE TABLE dw.DimLocation (
    LocationKey         int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceLocationId    int           NULL,
    AFSDepotId          int           NULL,
    LocationDescription nvarchar(300) NULL,
    IsFixed             bit           NULL,
    IsMobile            bit           NULL,
    Capacity            float         NULL,
    IsActive            bit           NULL
);
INSERT INTO dw.DimLocation (SourceLocationId, AFSDepotId, LocationDescription, IsFixed, IsMobile, Capacity, IsActive)
SELECT Id, AFSDepotId, Description, IsFixed, IsMobile, Capacity, IsActive FROM dbo.lstLocation;
CREATE UNIQUE INDEX UX_DimLocation_SourceId ON dw.DimLocation(SourceLocationId);
GO

CREATE TABLE dw.DimProduct (
    ProductKey      int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceProductId int           NULL,
    ProductName     nvarchar(200) NULL,
    IsFuel          bit           NULL,
    IsActive        bit           NULL
);
INSERT INTO dw.DimProduct (SourceProductId, ProductName, IsFuel, IsActive)
SELECT Id, Name,
       CASE WHEN UPPER(Name) LIKE '%DIESEL%' OR UPPER(Name) LIKE '%FUEL%' THEN 1 ELSE 0 END,
       IsActive
FROM dbo.lstProduct;
CREATE UNIQUE INDEX UX_DimProduct_SourceId ON dw.DimProduct(SourceProductId);
GO

/* Proper cost-centre dimension: distinct accounting attributes only.
   dbo.CostCentre is a transaction-grain extract; we bridge back to
   FactFuelTransaction through FuelEventId at load time. */
CREATE TABLE dw.DimCostCentre (
    CostCentreKey       int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CostCentreName      varchar(200) NULL,
    ResponsibilityCode  varchar(200) NULL,
    BusinessRevenueCode varchar(200) NULL,
    TaxRebateCode       varchar(200) NULL,
    GlAccount           varchar(200) NULL
);
/* Source columns are varchar(max); cast to 200 so the DISTINCT can hash-aggregate. */
INSERT INTO dw.DimCostCentre (CostCentreName, ResponsibilityCode, BusinessRevenueCode, TaxRebateCode, GlAccount)
SELECT DISTINCT LEFT(CostCentreName,200), LEFT(ResponsibilityCode,200), LEFT(BusinessRevenueCode,200), LEFT(TaxRebateCode,200), LEFT(GlAccount,200)
FROM dbo.CostCentre WITH (NOLOCK);
GO

/* ================================================================
   FACTS
   ================================================================ */

/* --- FactFuelTransaction: grain = one AFS fuel-issue transaction --- */
CREATE TABLE dw.FactFuelTransaction (
    FuelTransactionKey  bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceAFSRecordId   int           NOT NULL,
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
    /* degenerate dimensions for traceability */
    FuelEventId         int           NULL,
    VoucherNumber       nvarchar(200) NULL,
    DeviceId            nvarchar(200) NULL,
    Pump                nvarchar(200) NULL,
    TransactionPlate    nvarchar(200) NULL,
    VehicleCategoryDescription nvarchar(200) NULL,
    IsActive            bit           NULL
);
GO

/* FuelEventId -> CostCentreKey bridge built once for the load. */
SELECT c.FuelEventId, MIN(d.CostCentreKey) AS CostCentreKey
INTO #ccMap
FROM dbo.CostCentre c WITH (NOLOCK)
JOIN dw.DimCostCentre d
  ON  ISNULL(d.CostCentreName,'')      = ISNULL(LEFT(c.CostCentreName,200),'')
  AND ISNULL(d.ResponsibilityCode,'')  = ISNULL(LEFT(c.ResponsibilityCode,200),'')
  AND ISNULL(d.BusinessRevenueCode,'') = ISNULL(LEFT(c.BusinessRevenueCode,200),'')
  AND ISNULL(d.TaxRebateCode,'')       = ISNULL(LEFT(c.TaxRebateCode,200),'')
  AND ISNULL(d.GlAccount,'')           = ISNULL(LEFT(c.GlAccount,200),'')
WHERE c.FuelEventId IS NOT NULL
GROUP BY c.FuelEventId;
CREATE UNIQUE CLUSTERED INDEX cx ON #ccMap(FuelEventId);

INSERT INTO dw.FactFuelTransaction (
    SourceAFSRecordId, DateKey, TransactionDateTime, EquipmentKey, LocationKey,
    ProductKey, CostCentreKey, EligibleActivityKey, Litres, HoursOdoReading,
    CalculatedODO, FuelEventId, VoucherNumber, DeviceId, Pump, TransactionPlate,
    VehicleCategoryDescription, IsActive
)
SELECT
    a.Id,
    YEAR(a.TransactionDateTime)*10000 + MONTH(a.TransactionDateTime)*100 + DAY(a.TransactionDateTime),
    a.TransactionDateTime,
    e.EquipmentKey,
    l.LocationKey,
    p.ProductKey,
    cc.CostCentreKey,
    ISNULL(e.EligibleActivityKey, 99),
    a.Litres,
    a.HoursOdoReading,
    a.CalculatedODO,
    a.FuelEventId,
    a.VoucherNumber,
    a.DeviceId,
    a.Pump,
    a.TransactionPlate,
    a.VehicleCategoryDescription,
    a.IsActive
FROM dbo.datAFSRecord a WITH (NOLOCK)
LEFT JOIN dw.DimEquipment e ON e.SourceEquipmentId = a.EquipmentId
LEFT JOIN dw.DimLocation  l ON l.SourceLocationId  = a.LocationId
LEFT JOIN dw.DimProduct   p ON p.SourceProductId   = a.ProductId
LEFT JOIN #ccMap         cc ON cc.FuelEventId      = a.FuelEventId;

DROP TABLE #ccMap;
GO

/* --- FactFuelDelivery: grain = one tank/depot delivery --- */
CREATE TABLE dw.FactFuelDelivery (
    FuelDeliveryKey        bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceFuelDeliveryId   int           NOT NULL,
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
INSERT INTO dw.FactFuelDelivery (
    SourceFuelDeliveryId, DateKey, DeliveryTime, LocationKey, ProductKey,
    VolumeLitres, AFSTankDeliveryEventId, DocumentNumber, IsDuplicate, IsActive
)
SELECT
    d.Id,
    YEAR(d.DeliveryTime)*10000 + MONTH(d.DeliveryTime)*100 + DAY(d.DeliveryTime),
    d.DeliveryTime,
    l.LocationKey,
    p.ProductKey,
    d.Volume,
    d.AFSTankDeliveryEventId,
    d.DocumentNumber,
    d.IsDuplicate,
    d.IsActive
FROM dbo.datFuelDelivery d WITH (NOLOCK)
LEFT JOIN dw.DimLocation l ON l.SourceLocationId = d.LocationId
LEFT JOIN dw.DimProduct  p ON p.SourceProductId  = d.ProductId;
GO

/* --- FactMeterReading: grain = one odometer/hour meter reading --- */
CREATE TABLE dw.FactMeterReading (
    MeterReadingKey       bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceMeterReadingId  int      NOT NULL,
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
INSERT INTO dw.FactMeterReading (
    SourceMeterReadingId, DateKey, ReadingDate, PreviousReadingDate, EquipmentKey,
    MeasuringPoint, ReadingDiff, CounterReading, PreviousReading,
    ConsumptionTypeId, ReadingTypeId, IsActive
)
SELECT
    m.Id,
    YEAR(m.ReadingDate)*10000 + MONTH(m.ReadingDate)*100 + DAY(m.ReadingDate),
    m.ReadingDate,
    m.PreviousReadingDate,
    e.EquipmentKey,
    m.MeasuringPoint,
    m.ReadingDiff,
    m.CounterReading,
    m.PreviousReading,
    m.ConsumptionTypeId,
    m.ReadingTypeId,
    m.IsActive
FROM dbo.datMeterReading m WITH (NOLOCK)
LEFT JOIN dw.DimEquipment e ON e.SourceEquipmentId = m.EquipmentId;
GO

/* --- FactEquipmentTrip: grain = one trip/movement --- */
CREATE TABLE dw.FactEquipmentTrip (
    TripKey                   bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceTripRecordId        int           NOT NULL,
    SourceDateKey             int           NULL,
    DestinationDateKey        int           NULL,
    EquipmentKey              int           NULL,
    MaterialType              nvarchar(200) NULL,
    SourceLocationDescription nvarchar(300) NULL,
    SourceLocationUnit        nvarchar(300) NULL,
    DestinationLocation       nvarchar(300) NULL,
    DestinationLocationUnit   nvarchar(300) NULL,
    SourceTime                datetime      NULL,
    DestinationTime           datetime      NULL,
    TripDurationInMinutes     int           NULL,
    EligibleActivityPerformed nvarchar(300) NULL,
    WhereActivityPerformed    nvarchar(300) NULL,
    LatStart                  decimal(18,8) NULL,
    LongStart                 decimal(18,8) NULL,
    LatEnd                    decimal(18,8) NULL,
    LongEnd                   decimal(18,8) NULL,
    IsActive                  bit           NULL
);
INSERT INTO dw.FactEquipmentTrip (
    SourceTripRecordId, SourceDateKey, DestinationDateKey, EquipmentKey, MaterialType,
    SourceLocationDescription, SourceLocationUnit, DestinationLocation, DestinationLocationUnit,
    SourceTime, DestinationTime, TripDurationInMinutes, EligibleActivityPerformed,
    WhereActivityPerformed, LatStart, LongStart, LatEnd, LongEnd, IsActive
)
SELECT
    t.Id,
    CASE WHEN t.SourceTime IS NULL THEN NULL
         ELSE YEAR(t.SourceTime)*10000 + MONTH(t.SourceTime)*100 + DAY(t.SourceTime) END,
    CASE WHEN t.DestinationTime IS NULL THEN NULL
         ELSE YEAR(t.DestinationTime)*10000 + MONTH(t.DestinationTime)*100 + DAY(t.DestinationTime) END,
    e.EquipmentKey,
    t.MaterialType,
    t.SourceLocationDescription,
    t.SourceLocationUnit,
    t.DestinationLocation,
    t.DestinationLocationUnit,
    t.SourceTime,
    t.DestinationTime,
    t.TripDurationInMinutes,
    t.EligibleActivityPerformed,
    t.WhereActivityPerformed,
    t.LatStart, t.LongStart, t.LatEnd, t.LongEnd,
    t.IsActive
FROM dbo.datTripRecord t WITH (NOLOCK)
LEFT JOIN dw.DimEquipment e ON e.SourceEquipmentId = t.EquipmentId;
GO

/* --- FactLocationVolume: grain = one tank volume reading --- */
CREATE TABLE dw.FactLocationVolume (
    LocationVolumeKey            bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    SourceLocationVolumeReadingId int      NOT NULL,
    DateKey                      int      NULL,
    ReadingDateTime              datetime NULL,
    LocationKey                  int      NULL,
    VolumeReadingLitres          float    NULL,
    IsDuplicate                  bit      NULL,
    IsAggregate                  bit      NULL,
    IsActive                     bit      NULL
);
INSERT INTO dw.FactLocationVolume (
    SourceLocationVolumeReadingId, DateKey, ReadingDateTime, LocationKey,
    VolumeReadingLitres, IsDuplicate, IsAggregate, IsActive
)
SELECT
    v.Id,
    YEAR(v.ReadingDateTime)*10000 + MONTH(v.ReadingDateTime)*100 + DAY(v.ReadingDateTime),
    v.ReadingDateTime,
    l.LocationKey,
    v.VolumeReading,
    v.IsDuplicate,
    v.IsAggregate,
    v.IsActive
FROM dbo.datLocationVolumeReading v WITH (NOLOCK)
LEFT JOIN dw.DimLocation l ON l.SourceLocationId = v.LocationId;
GO

/* --- FactStorageLogbook: grain = one storage/tank logbook line --- */
CREATE TABLE dw.FactStorageLogbook (
    StorageLogbookKey         bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DateKey                   int           NULL,
    LogDate                   date          NULL,
    LocationKey               int           NULL,
    EquipmentKey              int           NULL,   -- disposed-to vehicle via RegNumber
    OpeningBalanceLitres      float         NULL,
    LitresReceived            float         NULL,   -- TRY_CONVERT from nvarchar source
    LitresDisposed            float         NULL,
    MeterReadingAfterDisposal float         NULL,
    RegNumber                 nvarchar(100) NULL,
    DisposedToVehicle         nvarchar(300) NULL,
    PurposeOfDisposal         varchar(500)  NULL,
    InvoiceNumber             nvarchar(200) NULL
);
GO

/* RegNumber -> EquipmentKey helper map (RegNumber is not unique in the master;
   take the lowest key deterministically). */
SELECT RegNumber, MIN(EquipmentKey) AS EquipmentKey
INTO #regMap
FROM dw.DimEquipment
WHERE RegNumber IS NOT NULL
GROUP BY RegNumber;
CREATE UNIQUE CLUSTERED INDEX cx ON #regMap(RegNumber);

INSERT INTO dw.FactStorageLogbook (
    DateKey, LogDate, LocationKey, EquipmentKey, OpeningBalanceLitres, LitresReceived,
    LitresDisposed, MeterReadingAfterDisposal, RegNumber, DisposedToVehicle,
    PurposeOfDisposal, InvoiceNumber
)
SELECT
    YEAR(s.[Date])*10000 + MONTH(s.[Date])*100 + DAY(s.[Date]),
    s.[Date],
    l.LocationKey,
    r.EquipmentKey,
    s.OpeningBalance,
    TRY_CONVERT(float, REPLACE(s.LitresReceived, ',', '')),
    s.LitresDisposed,
    s.MeterReadingAfterDisposal,
    LEFT(s.RegNumber, 100),
    LEFT(s.DisposedToVehicle, 300),
    LEFT(s.PurposeOfDisposal, 500),
    LEFT(s.InvoiceNumber, 200)
FROM dbo.cacheStorageLogbook s WITH (NOLOCK)
LEFT JOIN dw.DimLocation l ON l.SourceLocationId = s.LocationId
LEFT JOIN #regMap        r ON r.RegNumber        = s.RegNumber;
GO

/* --- FactFuelUsageClassification: grain = one usage logbook line.
   This is the SARS eligible/non-eligible source (vw_UsageReportCached). --- */
CREATE TABLE dw.FactFuelUsageClassification (
    UsageClassificationKey bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,
    DateKey                int            NULL,
    TransactionDateTime    datetime       NOT NULL,
    EquipmentKey           int            NULL,
    RegNumber              nvarchar(50)   NULL,
    TypeOfVehicle          nvarchar(100)  NULL,
    QuantityReceivedLitres float          NULL,
    OpeningBalanceFuel     float          NULL,
    TotalFuelUsedLitres    float          NULL,
    UnusedBalanceLitres    float          NULL,
    NonEligibleLitres      float          NULL,
    EligiblePurchasesLitres float         NULL,
    EligibleUsageLitres    AS (TotalFuelUsedLitres - NonEligibleLitres) PERSISTED,
    OpeningOdo             float          NULL,
    ClosingOdo             float          NULL,
    TotalOdoUsed           float          NULL,
    SpecificActivityPerformed nvarchar(2000) NULL,
    WhereActivityPerformed nvarchar(2000) NULL,
    ReceivedFromStorageUnitNumber nvarchar(100) NULL
);
INSERT INTO dw.FactFuelUsageClassification (
    DateKey, TransactionDateTime, EquipmentKey, RegNumber, TypeOfVehicle,
    QuantityReceivedLitres, OpeningBalanceFuel, TotalFuelUsedLitres, UnusedBalanceLitres,
    NonEligibleLitres, EligiblePurchasesLitres, OpeningOdo, ClosingOdo, TotalOdoUsed,
    SpecificActivityPerformed, WhereActivityPerformed, ReceivedFromStorageUnitNumber
)
SELECT
    YEAR(u.TransactionDateTime)*10000 + MONTH(u.TransactionDateTime)*100 + DAY(u.TransactionDateTime),
    u.TransactionDateTime,
    r.EquipmentKey,
    u.RegNumber,
    u.TypeOfVehicle,
    u.QuantityReceived,
    u.OpeningBalanceFuel,
    u.TotalFuelUsed,
    u.UnusedBalance,
    u.NonEligible,
    u.EligiblePurchases,
    TRY_CONVERT(float, REPLACE(u.OpeningOdo,  ',', '')),
    TRY_CONVERT(float, REPLACE(u.ClosingOdo,  ',', '')),
    TRY_CONVERT(float, REPLACE(u.TotalOdoUsed,',', '')),
    LEFT(u.SpecificActivityPerformed, 2000),
    LEFT(u.WhereActivityPerformed, 2000),
    u.ReceivedFromStorageUnitNumber
FROM dbo.cacheUsageLogbook u WITH (NOLOCK)
LEFT JOIN #regMap r ON r.RegNumber = u.RegNumber;

DROP TABLE #regMap;
GO

/* --- FactDieselRefundClaim: grain = claim month x SARS usage type.
   SARS Rebate Item 670.04 on-land calculation from the evidence pack:
     eligible = total - non_eligible; qualifying = eligible * 80%;
     refund_R = qualifying * rate_c_per_l / 100. --- */
CREATE TABLE dw.FactDieselRefundClaim (
    DieselRefundClaimKey    int IDENTITY(1,1) NOT NULL PRIMARY KEY,
    ClaimPeriodDateKey      int           NOT NULL,   -- first day of month
    ClaimYearMonth          char(7)       NOT NULL,
    SARSUsageTypeKey        int           NOT NULL REFERENCES dw.DimSARSUsageType(SARSUsageTypeKey),
    RefundRateKey           int           NULL REFERENCES dw.DimRefundRate(RefundRateKey),
    TotalLitres             decimal(18,3) NULL,
    NonEligibleLitres       decimal(18,3) NULL,
    EligibleLitres          decimal(18,3) NULL,
    EligiblePurchasesLitres decimal(18,3) NULL,       -- as reported by source system
    QualifyingClaimLitres   decimal(18,3) NULL,
    RefundRateCentsPerLitre decimal(10,2) NULL,
    RefundAmountRand        decimal(18,2) NULL,
    RateMissingFlag         bit           NOT NULL DEFAULT 0
);
INSERT INTO dw.FactDieselRefundClaim (
    ClaimPeriodDateKey, ClaimYearMonth, SARSUsageTypeKey, RefundRateKey,
    TotalLitres, NonEligibleLitres, EligibleLitres, EligiblePurchasesLitres,
    QualifyingClaimLitres, RefundRateCentsPerLitre, RefundAmountRand, RateMissingFlag
)
SELECT
    YEAR(m.MonthStart)*10000 + MONTH(m.MonthStart)*100 + 1,
    CONVERT(char(7), m.MonthStart, 126),
    1,                                            -- On Land (Mining)
    rr.RefundRateKey,
    m.TotalLitres,
    m.NonEligibleLitres,
    m.TotalLitres - m.NonEligibleLitres,
    m.EligiblePurchasesLitres,
    ROUND((m.TotalLitres - m.NonEligibleLitres) * 0.80, 3),
    rr.RefundRateCentsPerLitre,
    ROUND((m.TotalLitres - m.NonEligibleLitres) * 0.80 * rr.RefundRateCentsPerLitre / 100.0, 2),
    CASE WHEN rr.RefundRateKey IS NULL THEN 1 ELSE 0 END
FROM (
    SELECT
        DATEFROMPARTS(YEAR(TransactionDateTime), MONTH(TransactionDateTime), 1) AS MonthStart,
        CAST(SUM(TotalFuelUsedLitres)     AS decimal(18,3)) AS TotalLitres,
        CAST(SUM(NonEligibleLitres)       AS decimal(18,3)) AS NonEligibleLitres,
        CAST(SUM(EligiblePurchasesLitres) AS decimal(18,3)) AS EligiblePurchasesLitres
    FROM dw.FactFuelUsageClassification
    GROUP BY DATEFROMPARTS(YEAR(TransactionDateTime), MONTH(TransactionDateTime), 1)
) m
LEFT JOIN dw.DimRefundRate rr
  ON rr.SARSUsageTypeKey = 1
 AND m.MonthStart >= rr.EffectiveFromDate
 AND (rr.EffectiveToDate IS NULL OR m.MonthStart <= rr.EffectiveToDate);
GO

/* ================================================================
   FOREIGN KEYS + INDEXES
   ================================================================ */
ALTER TABLE dw.FactFuelTransaction ADD
    CONSTRAINT FK_FFT_Date      FOREIGN KEY (DateKey)             REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_FFT_Equipment FOREIGN KEY (EquipmentKey)        REFERENCES dw.DimEquipment(EquipmentKey),
    CONSTRAINT FK_FFT_Location  FOREIGN KEY (LocationKey)         REFERENCES dw.DimLocation(LocationKey),
    CONSTRAINT FK_FFT_Product   FOREIGN KEY (ProductKey)          REFERENCES dw.DimProduct(ProductKey),
    CONSTRAINT FK_FFT_CostCtr   FOREIGN KEY (CostCentreKey)       REFERENCES dw.DimCostCentre(CostCentreKey),
    CONSTRAINT FK_FFT_Activity  FOREIGN KEY (EligibleActivityKey) REFERENCES dw.DimEligibleActivity(EligibleActivityKey);
ALTER TABLE dw.FactFuelDelivery ADD
    CONSTRAINT FK_FFD_Date      FOREIGN KEY (DateKey)      REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_FFD_Location  FOREIGN KEY (LocationKey)  REFERENCES dw.DimLocation(LocationKey),
    CONSTRAINT FK_FFD_Product   FOREIGN KEY (ProductKey)   REFERENCES dw.DimProduct(ProductKey);
ALTER TABLE dw.FactMeterReading ADD
    CONSTRAINT FK_FMR_Date      FOREIGN KEY (DateKey)      REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_FMR_Equipment FOREIGN KEY (EquipmentKey) REFERENCES dw.DimEquipment(EquipmentKey);
ALTER TABLE dw.FactEquipmentTrip ADD
    CONSTRAINT FK_FET_SrcDate   FOREIGN KEY (SourceDateKey)      REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_FET_DstDate   FOREIGN KEY (DestinationDateKey) REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_FET_Equipment FOREIGN KEY (EquipmentKey)       REFERENCES dw.DimEquipment(EquipmentKey);
ALTER TABLE dw.FactLocationVolume ADD
    CONSTRAINT FK_FLV_Date      FOREIGN KEY (DateKey)      REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_FLV_Location  FOREIGN KEY (LocationKey)  REFERENCES dw.DimLocation(LocationKey);
ALTER TABLE dw.FactStorageLogbook ADD
    CONSTRAINT FK_FSL_Date      FOREIGN KEY (DateKey)      REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_FSL_Location  FOREIGN KEY (LocationKey)  REFERENCES dw.DimLocation(LocationKey),
    CONSTRAINT FK_FSL_Equipment FOREIGN KEY (EquipmentKey) REFERENCES dw.DimEquipment(EquipmentKey);
ALTER TABLE dw.FactFuelUsageClassification ADD
    CONSTRAINT FK_FUC_Date      FOREIGN KEY (DateKey)      REFERENCES dw.DimDate(DateKey),
    CONSTRAINT FK_FUC_Equipment FOREIGN KEY (EquipmentKey) REFERENCES dw.DimEquipment(EquipmentKey);
ALTER TABLE dw.FactDieselRefundClaim ADD
    CONSTRAINT FK_FRC_Date      FOREIGN KEY (ClaimPeriodDateKey) REFERENCES dw.DimDate(DateKey);
GO

CREATE INDEX IX_FFT_Date      ON dw.FactFuelTransaction(DateKey) INCLUDE (Litres);
CREATE INDEX IX_FFT_Equipment ON dw.FactFuelTransaction(EquipmentKey);
CREATE INDEX IX_FFT_Location  ON dw.FactFuelTransaction(LocationKey);
CREATE INDEX IX_FMR_Equipment ON dw.FactMeterReading(EquipmentKey) INCLUDE (ReadingDiff);
CREATE INDEX IX_FET_Equipment ON dw.FactEquipmentTrip(EquipmentKey);
CREATE INDEX IX_FUC_Date      ON dw.FactFuelUsageClassification(DateKey);
GO

/* ================================================================
   ANALYSIS VIEWS
   ================================================================ */
CREATE VIEW dw.vw_MonthlyFuelSummary AS
SELECT
    d.YearMonth,
    d.[Year],
    d.FiscalYearSA,
    l.LocationDescription,
    p.ProductName,
    ea.EligibilityStatus,
    SUM(f.Litres)  AS LitresIssued,
    COUNT_BIG(*)   AS TransactionCount
FROM dw.FactFuelTransaction f
JOIN dw.DimDate d              ON d.DateKey = f.DateKey
LEFT JOIN dw.DimLocation l     ON l.LocationKey = f.LocationKey
LEFT JOIN dw.DimProduct p      ON p.ProductKey = f.ProductKey
LEFT JOIN dw.DimEligibleActivity ea ON ea.EligibleActivityKey = f.EligibleActivityKey
GROUP BY d.YearMonth, d.[Year], d.FiscalYearSA, l.LocationDescription, p.ProductName, ea.EligibilityStatus;
GO

CREATE VIEW dw.vw_DieselRefundByMonth AS
SELECT
    c.ClaimYearMonth,
    u.UsageTypeName,
    c.TotalLitres,
    c.NonEligibleLitres,
    c.EligibleLitres,
    c.QualifyingClaimLitres,
    c.RefundRateCentsPerLitre,
    c.RefundAmountRand,
    c.RateMissingFlag
FROM dw.FactDieselRefundClaim c
JOIN dw.DimSARSUsageType u ON u.SARSUsageTypeKey = c.SARSUsageTypeKey;
GO

CREATE VIEW dw.vw_EquipmentFuelEfficiency AS
WITH fuel AS (
    SELECT EquipmentKey, d.YearMonth, SUM(Litres) AS Litres
    FROM dw.FactFuelTransaction f JOIN dw.DimDate d ON d.DateKey = f.DateKey
    GROUP BY EquipmentKey, d.YearMonth
),
meter AS (
    SELECT EquipmentKey, d.YearMonth, SUM(ReadingDiff) AS UnitsWorked
    FROM dw.FactMeterReading m JOIN dw.DimDate d ON d.DateKey = m.DateKey
    GROUP BY EquipmentKey, d.YearMonth
)
SELECT
    e.EquipmentKey, e.FleetId, e.RegNumber, e.MakeName, e.ModelName,
    e.VehicleTypeName, e.ConsumptionTypeName, e.EligibilityClass,
    fu.YearMonth,
    fu.Litres,
    mt.UnitsWorked,
    CASE WHEN mt.UnitsWorked > 0 THEN fu.Litres / mt.UnitsWorked END AS LitresPerUnit
FROM fuel fu
JOIN dw.DimEquipment e ON e.EquipmentKey = fu.EquipmentKey
LEFT JOIN meter mt ON mt.EquipmentKey = fu.EquipmentKey AND mt.YearMonth = fu.YearMonth;
GO

CREATE VIEW dw.vw_TankReconciliation AS
WITH iss AS (
    SELECT LocationKey, d.YearMonth, SUM(Litres) AS IssuedLitres
    FROM dw.FactFuelTransaction f JOIN dw.DimDate d ON d.DateKey = f.DateKey
    GROUP BY LocationKey, d.YearMonth
),
del AS (
    SELECT LocationKey, d.YearMonth, SUM(VolumeLitres) AS DeliveredLitres
    FROM dw.FactFuelDelivery f JOIN dw.DimDate d ON d.DateKey = f.DateKey
    GROUP BY LocationKey, d.YearMonth
)
SELECT
    l.LocationKey, l.LocationDescription,
    COALESCE(i.YearMonth, dl.YearMonth) AS YearMonth,
    dl.DeliveredLitres,
    i.IssuedLitres,
    ISNULL(dl.DeliveredLitres,0) - ISNULL(i.IssuedLitres,0) AS NetLitres
FROM dw.DimLocation l
LEFT JOIN iss i  ON i.LocationKey  = l.LocationKey
FULL  JOIN del dl ON dl.LocationKey = l.LocationKey AND dl.YearMonth = i.YearMonth
WHERE COALESCE(i.YearMonth, dl.YearMonth) IS NOT NULL;
GO

CREATE VIEW dw.vw_DataQuality AS
SELECT 'AFS transaction missing equipment'        AS issue, COUNT_BIG(*) AS row_count FROM dw.FactFuelTransaction WHERE EquipmentKey IS NULL
UNION ALL SELECT 'AFS transaction missing location',        COUNT_BIG(*) FROM dw.FactFuelTransaction WHERE LocationKey IS NULL
UNION ALL SELECT 'AFS transaction zero/negative litres',    COUNT_BIG(*) FROM dw.FactFuelTransaction WHERE Litres <= 0
UNION ALL SELECT 'AFS duplicate FuelEventId',               COUNT_BIG(*) FROM (SELECT FuelEventId FROM dw.FactFuelTransaction WHERE FuelEventId IS NOT NULL GROUP BY FuelEventId HAVING COUNT(*) > 1) x
UNION ALL SELECT 'Fuel issue exceeds 1.5x tank size',       COUNT_BIG(*) FROM dw.FactFuelTransaction f JOIN dw.DimEquipment e ON e.EquipmentKey = f.EquipmentKey WHERE e.TankSize > 0 AND f.Litres > e.TankSize * 1.5
UNION ALL SELECT 'Usage non-eligible exceeds total',        COUNT_BIG(*) FROM dw.FactFuelUsageClassification WHERE NonEligibleLitres > TotalFuelUsedLitres
UNION ALL SELECT 'Usage row unmatched to equipment',        COUNT_BIG(*) FROM dw.FactFuelUsageClassification WHERE EquipmentKey IS NULL
UNION ALL SELECT 'Delivery zero/negative volume',           COUNT_BIG(*) FROM dw.FactFuelDelivery WHERE VolumeLitres <= 0
UNION ALL SELECT 'Delivery flagged duplicate',              COUNT_BIG(*) FROM dw.FactFuelDelivery WHERE IsDuplicate = 1;
GO

/* ================================================================
   FINAL ROW COUNTS
   ================================================================ */
SELECT 'DimDate' AS table_name, COUNT_BIG(*) AS row_count FROM dw.DimDate
UNION ALL SELECT 'DimEquipment',                COUNT_BIG(*) FROM dw.DimEquipment
UNION ALL SELECT 'DimLocation',                 COUNT_BIG(*) FROM dw.DimLocation
UNION ALL SELECT 'DimProduct',                  COUNT_BIG(*) FROM dw.DimProduct
UNION ALL SELECT 'DimCostCentre',               COUNT_BIG(*) FROM dw.DimCostCentre
UNION ALL SELECT 'DimEligibleActivity',         COUNT_BIG(*) FROM dw.DimEligibleActivity
UNION ALL SELECT 'DimSARSUsageType',            COUNT_BIG(*) FROM dw.DimSARSUsageType
UNION ALL SELECT 'DimRefundRate',               COUNT_BIG(*) FROM dw.DimRefundRate
UNION ALL SELECT 'FactFuelTransaction',         COUNT_BIG(*) FROM dw.FactFuelTransaction
UNION ALL SELECT 'FactFuelDelivery',            COUNT_BIG(*) FROM dw.FactFuelDelivery
UNION ALL SELECT 'FactMeterReading',            COUNT_BIG(*) FROM dw.FactMeterReading
UNION ALL SELECT 'FactEquipmentTrip',           COUNT_BIG(*) FROM dw.FactEquipmentTrip
UNION ALL SELECT 'FactLocationVolume',          COUNT_BIG(*) FROM dw.FactLocationVolume
UNION ALL SELECT 'FactStorageLogbook',          COUNT_BIG(*) FROM dw.FactStorageLogbook
UNION ALL SELECT 'FactFuelUsageClassification', COUNT_BIG(*) FROM dw.FactFuelUsageClassification
UNION ALL SELECT 'FactDieselRefundClaim',       COUNT_BIG(*) FROM dw.FactDieselRefundClaim
ORDER BY table_name;
