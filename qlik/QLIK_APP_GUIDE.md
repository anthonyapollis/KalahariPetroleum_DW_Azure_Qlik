# Qlik Sense App Guide — Anglo Mining Fuel / SARS Diesel Refund

Tenant: `https://go10njvx344b4j2.eu.qlikcloud.com`

## Getting the data in (pick one)

**Option A — Web files + SAS (fastest, no connector setup)**
1. Generate a read SAS for the `raw` container (valid e.g. 90 days):
   ```
   az storage container generate-sas --account-name stanglominingdw01 --name raw --permissions rl --expiry 2026-10-05 --auth-mode key --account-key <key> -o tsv
   ```
2. In the tenant: Create → New analytics app → open **Data load editor**.
3. Paste `anglo_mining_fuel_load_script.qvs`, set `vSAS` to the token, reload.

**Option B — Azure Storage connector (governed)**
1. Data load editor → Create new connection → **Azure Storage**.
2. Account `stanglominingdw01`, key from `az storage account keys list`, container `raw`.
3. Replace each `FROM [$(vBase)/...]` with the `lib://` path the connector gives you.

**Automation note:** app creation/reload can be scripted with `qlik-cli` or the
qlik-mcp-server (github.com/arthurfantaci/qlik-mcp-server) once an API key is
issued in the tenant (Profile → API keys). Not possible non-interactively
without that key.

## Data model
Single concatenated fact table `Fuel` (FactType = Fuel Issue / Fuel Delivery /
Usage Classification / Meter Reading / Equipment Trip) associated to DimDate,
DimEquipment, DimLocation, DimProduct, DimCostCentre, DimEligibleActivity.
`RefundClaims` is a deliberate data island (month-grain SARS 670.04 output
from the DW, fields prefixed `Claim.`).

## Suggested sheets

1. **Executive Fuel Overview**
   - KPIs: Litres Issued, Litres Delivered, Refund (R), Eligible %
   - Line: Litres Issued by YearMonth (dimension: YearMonth)
   - Bar: Litres Issued by LocationDescription (top 15)
   - Filter panel: Year, FiscalYearSA, LocationDescription, ProductName

2. **SARS Diesel Refund**
   - KPIs (island): `Sum(Claim.RefundRand)`, `Sum(Claim.EligibleLitres)`,
     `Sum(Claim.QualifyingLitres)`
   - Combo chart: Claim.YearMonth vs Claim.EligibleLitres / Claim.NonEligibleLitres
     (stacked bars) + Claim.RefundRand (line)
   - Table: full claims island with RateMissingFlag conditional formatting
   - Text note: rates are 2020 policy examples (Rebate Item 670.04)

3. **Equipment Efficiency**
   - Scatter: dimension FleetId; x `Sum({<FactType={'Meter Reading'}>} UnitsWorked)`,
     y `Sum({<FactType={'Fuel Issue'}>} IssuedLitres)` — outliers = anomaly candidates
   - Table: Litres per Hour/Km by MakeName/ModelName/VehicleTypeName
   - Filter: ConsumptionTypeName (L/HR vs L/100KM), EligibilityClass

4. **Eligibility & Activity**
   - Pie: Eligible vs Non-Eligible litres (Usage Classification)
   - Bar: litres by EligibilityStatus / ActivityDescription (DimEligibleActivity)
   - Table: SpecificActivityPerformed with litres — audit drill-down

5. **Tank & Delivery Reconciliation**
   - Waterfall/bar: Delivered minus Issued by LocationDescription and YearMonth
   - Table: DocumentNumber-level deliveries

6. **Data Quality**
   - KPIs: duplicate FuelEventId count, usage rows unmatched to equipment
     (203,309 in QA data — RegNumber mismatch vs equipment master),
     fuel issues exceeding 1.5× tank size (14,746)
   - Table: `Count({<FactType={'Fuel Issue'}>} DISTINCT FuelEventId)` vs
     `Count({<FactType={'Fuel Issue'}>} FuelEventId)`

Master measures: definitions are at the bottom of the load script.
