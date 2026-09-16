/*
  Row-level security mapping for the Kalahari tabular model.

  sec.UserLocation lists which fuel locations each Windows login may see. The model's
  "Site Managers" role filters Location with CONTAINS(..., USERNAME(), ...), so the rows
  here decide what a site manager sees; nobody edits the model to change access.

  Also grants the Analysis Services service account read access so the model can process.

  Run with the login to map for the demo, e.g.
    sqlcmd -S localhost -E -i 01_rls_security_table.sql -v DemoUser="DOMAIN\user"
*/
SET QUOTED_IDENTIFIER ON;
GO
USE KalahariDW_SSIS;
GO
IF SCHEMA_ID('sec') IS NULL EXEC('CREATE SCHEMA sec');
GO
DROP TABLE IF EXISTS sec.UserLocation;
CREATE TABLE sec.UserLocation (
    UserName    nvarchar(256) NOT NULL,
    LocationKey int           NOT NULL REFERENCES dw.DimLocation(LocationKey),
    CONSTRAINT PK_UserLocation PRIMARY KEY (UserName, LocationKey)
);
/* Demo mapping: the three busiest fixed sites by litres issued. */
INSERT INTO sec.UserLocation (UserName, LocationKey)
SELECT TOP (3) N'$(DemoUser)', f.LocationKey
FROM dw.FactFuelTransaction f
JOIN dw.DimLocation l ON l.LocationKey = f.LocationKey
WHERE l.IsFixed = 1
GROUP BY f.LocationKey
ORDER BY SUM(f.Litres) DESC;
GO

/* Analysis Services processes the model as its service account. */
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'NT Service\MSSQLServerOLAPService')
    CREATE LOGIN [NT Service\MSSQLServerOLAPService] FROM WINDOWS;
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'NT Service\MSSQLServerOLAPService')
    CREATE USER [NT Service\MSSQLServerOLAPService] FOR LOGIN [NT Service\MSSQLServerOLAPService];
ALTER ROLE db_datareader ADD MEMBER [NT Service\MSSQLServerOLAPService];
GO
SELECT UserName, LocationKey FROM sec.UserLocation;
