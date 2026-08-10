/* =====================================================================
   DW_MBS.sql
   ---------------------------------------------------------------------
   Rebuilds the MBS-family voice-trade dataset from the RAW tables,
   replacing a query against IDB_Reporting.dbo.IDB_DEAL_VOICE (being
   decommissioned). Logic lifted from stored proc
   IDB_Reporting.dbo.LoadVoiceTradeData.

   Covers four product groups, each from BOTH department blocks so no
   records are dropped:
       SPECIFIED  (SpecDb)      - HF (Division 100) + RC (Division 200)
       ARMS       (ArmDb)       - HF + RC
       CMO        (CmoDb)       - HF + RC
       MBS-Rttm   (MbsDbRttm)   - HF + RC

   Dealer is resolved per section as:
       Dealer      = <detail>.CustNo      (raw source dealer number)
       DealerName  = <customer>.CustName  (via Customer join)
   and MasterDealerCode is stamped at the end from IDB_DEALER_MASTER,
   scoped by each row's own Department (matches proc lines 1403-1407).

   NO product-group / dealer / department filtering: everything in the
   window lands in #COMBINED.

   Thin field set only (trade id, keys, cusip, dealer, name, master
   code, qty, price, dates, type, trader). Commission / shared-account
   columns intentionally omitted for now.
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @dealer     VARCHAR(8);         -- optional; leave NULL for all dealers
DECLARE @tradedate1 DATETIME,
        @tradedate2 DATETIME;
SET @tradedate1 = '20241201';
SET @tradedate2 = '20241231';

/* ---------------------------------------------------------------------
   Common staging table. Every INSERT projects onto exactly these
   columns; a source that lacks a field pads it with a typed NULL.
   --------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#COMBINED') IS NOT NULL DROP TABLE #COMBINED;
CREATE TABLE #COMBINED
(
    source_tag       varchar(16)   NULL,   -- 'SPEC-HF', 'ARM-RC', etc.  (our tag)
    department       varchar(5)    NULL,   -- 'HF' / 'RC'  (drives master-code join)
    productgroup     varchar(20)   NULL,   -- 'SPECIFIED' / 'ARMS' / 'CMO' / 'MBS'
    trade_id         varchar(60)   NULL,
    deal_negotiation_id varchar(30) NULL,
    TradeKey         nchar(12)     NULL,
    TradeGroupKey    nchar(14)     NULL,
    TradeDetailsKey  nvarchar(16)  NULL,
    Cusip            varchar(50)   NULL,
    SecurityDesc     varchar(255)  NULL,
    tradedate        datetime      NULL,
    buysell          varchar(5)    NULL,
    quantity_orig    decimal(20,6) NULL,
    tradeprice       varchar(30)   NULL,
    tw_tradetype     varchar(25)   NULL,
    tradetype2       varchar(25)   NULL,
    isaggressor      char(1)       NULL,
    legtype          varchar(20)   NULL,
    sectype          nvarchar(4)   NULL,
    trader           varchar(50)   NULL,
    dealer           varchar(100)  NULL,   -- CustNo (source dealer number)
    dealer_name      varchar(255)  NULL,   -- CustName
    master_dealer_code varchar(10) NULL    -- filled by UPDATE at the end
);

/* =====================================================================
   1. SPECIFIED  -  HF block   (SpecDb, Division 100)
   proc ref: lines 443-589
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     TradeKey, TradeGroupKey, TradeDetailsKey, Cusip, SecurityDesc,
     tradedate, buysell, quantity_orig, tradeprice, tw_tradetype,
     tradetype2, isaggressor, legtype, sectype, trader, dealer, dealer_name)
SELECT
    'SPEC-HF',
    'HF',
    'SPECIFIED',
    CAST(B.TradeNo AS varchar(50)) + D.BorS,
    B.TradeNo,
    B.TradeKey,
    C.TradeGroupKey,
    D.TradeDetailsKey,
    Cusip = ISNULL(P.PoolCusipNo, C.CusipNo),
    SecurityDesc = C.SecType + ' ' + CAST(C.Coupon AS varchar(15)),
    B.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    Quantity = ISNULL(P.PoolFaceAmount, ISNULL(C.OrigFaceAmount, 0)),
    TradePrice = D.Price,
    tw_tradetype = CASE WHEN ISNULL(C.TbaType,'') = 'C' THEN 'OUTRIGHT'
                        WHEN ISNULL(C.TbaType,'') IN ('S1','S2','S3') THEN 'BFLY'
                        ELSE 'OUTRIGHT' END,
    tradetype2   = CASE WHEN ISNULL(C.TbaType,'') = 'C' THEN 'OUTRIGHT'
                        WHEN ISNULL(C.TbaType,'') IN ('S1','S2','S3') THEN 'BFLY'
                        ELSE 'OUTRIGHT' END,
    IsAggressor  = CASE WHEN D.CustCommissions > 0 THEN 1 ELSE 0 END,
    LegType      = C.TbaType,
    SecType      = C.SecType,
    TraderName   = abr.TraderName,
    Dealer       = D.CustNo,
    DealerName   = cu.CustName
FROM SpecDb.dbo.SpecifiedTrades B (NOLOCK)
    INNER JOIN SpecDb.dbo.SpecifiedTradesGroup C (NOLOCK)
        ON B.TradeKey = C.TradeKey
    INNER JOIN SpecDb.dbo.SpecifiedTradesDetails D (NOLOCK)
        ON C.TradeGroupKey = D.TradeGroupKey
    LEFT JOIN SpecDb.dbo.SpecifiedTradesPools P (NOLOCK)
        ON D.TradeDetailsKey = P.TradeDetailsKey
    LEFT JOIN ArmSpecifiedDb..Customer cu (NOLOCK)
        ON D.CustNo = cu.CustNo
    LEFT JOIN ArmSpecifiedDb.dbo.Broker abr (NOLOCK)
        ON D.AcctNo = abr.AcctNo
WHERE B.TradeDate BETWEEN @tradedate1 AND @tradedate2
  AND B.Division = 100        /* HF */
  AND D.BrokerName <> 'BALORD';

/* =====================================================================
   2. SPECIFIED  -  RC block   (SpecDb, Division 200)
   proc ref: lines 1271-1389
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     TradeKey, TradeGroupKey, TradeDetailsKey, Cusip, SecurityDesc,
     tradedate, buysell, quantity_orig, tradeprice, tw_tradetype,
     tradetype2, isaggressor, legtype, sectype, trader, dealer, dealer_name)
SELECT
    'SPEC-RC',
    'RC',
    'SPECIFIED',
    CAST(B.TradeNo AS varchar(50)) + D.BorS,
    B.TradeNo,
    B.TradeKey,
    C.TradeGroupKey,
    D.TradeDetailsKey,
    Cusip = C.CusipNo,
    SecurityDesc = C.SecType + ' ' + CAST(C.Coupon AS varchar(15)),
    B.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    Quantity = ISNULL(C.OrigFaceAmount, 0)
               * CASE WHEN sa.Broker_ID_HF IS NOT NULL THEN 0 ELSE 1 END,
    TradePrice = D.Price,
    tw_tradetype = CASE WHEN ISNULL(C.TbaType,'') = 'C' THEN 'OUTRIGHT'
                        WHEN ISNULL(C.TbaType,'') IN ('S1','S2','S3') THEN 'BFLY'
                        ELSE 'OUTRIGHT' END,
    tradetype2   = CASE WHEN ISNULL(C.TbaType,'') = 'C' THEN 'OUTRIGHT'
                        WHEN ISNULL(C.TbaType,'') IN ('S1','S2','S3') THEN 'BFLY'
                        ELSE 'OUTRIGHT' END,
    IsAggressor  = CASE WHEN C.CommissionPayer = D.BorS THEN 1
                        WHEN C.CommissionPayer = 'T' THEN 1 ELSE 0 END,
    LegType      = C.TbaType,
    SecType      = C.SecType,
    TraderName   = abr.TraderName,
    Dealer       = D.CustNo,
    DealerName   = cu.CustName
FROM SpecDb.dbo.SpecifiedTrades B (NOLOCK)
    INNER JOIN SpecDb.dbo.SpecifiedTradesGroup C (NOLOCK)
        ON B.TradeKey = C.TradeKey
    INNER JOIN SpecDb.dbo.SpecifiedTradesDetails D (NOLOCK)
        ON C.TradeGroupKey = D.TradeGroupKey
    LEFT JOIN ArmSpecifiedDb..Customer cu (NOLOCK)
        ON D.CustNo = cu.CustNo
    LEFT JOIN ArmSpecifiedDb.dbo.Broker abr (NOLOCK)
        ON D.AcctNo = abr.AcctNo
    LEFT JOIN IDB_Reporting.dbo.IDB_HF_SharedAccounts sa
        ON abr.AcctNo COLLATE DATABASE_DEFAULT = sa.SharedAcctNo_HF COLLATE DATABASE_DEFAULT
       AND CONVERT(varchar(8), B.TradeDate, 112)
               BETWEEN sa.EffectiveStartDate AND sa.EffectiveEndDate
       AND sa.ProductGroup = 'SPECIFIED'
WHERE B.TradeDate BETWEEN @tradedate1 AND @tradedate2
  AND B.Division = 200        /* RC */
  AND abr.BrokerName <> 'BALORD';

/* =====================================================================
   3. ARMS  -  HF block   (ArmDb)
   proc ref: lines 343-440
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     TradeKey, TradeGroupKey, TradeDetailsKey, Cusip, SecurityDesc,
     tradedate, buysell, quantity_orig, tradeprice, tw_tradetype,
     tradetype2, isaggressor, legtype, sectype, trader, dealer, dealer_name)
SELECT
    'ARM-HF',
    'HF',
    'ARMS',
    CAST(B.TradeNo AS varchar(50)) + D.BorS,
    B.TradeNo,
    B.TradeKey,
    C.TradeGroupKey,
    D.TradeDetailsKey,
    Cusip = (SELECT MAX(stp.PoolCusipNo)
             FROM ArmDb.dbo.ArmTradesPools stp (NOLOCK)
             WHERE stp.TradeDetailsKey = D.TradeDetailsKey),
    SecurityDesc = C.SecType + ' ' + CAST(C.Coupon AS varchar(15)),
    B.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    Quantity = ISNULL(P.PoolCurrentAmount, OrigFaceAmount),
    TradePrice = D.Price,
    tw_tradetype = NULL,
    tradetype2   = NULL,
    IsAggressor  = CASE WHEN D.CustCommissions > 0 THEN 1 ELSE 0 END,
    LegType      = NULL,
    SecType      = C.SecType,
    TraderName   = abr.TraderName,
    Dealer       = d.CustNo,
    DealerName   = cu.CustName
FROM ArmDb.dbo.ArmTrades B (NOLOCK)
    INNER JOIN ArmDb.dbo.ArmTradesGroup C (NOLOCK)
        ON B.TradeKey = C.TradeKey
    INNER JOIN ArmDb.dbo.ArmTradesDetails D (NOLOCK)
        ON C.TradeGroupKey = D.TradeGroupKey
    LEFT JOIN ArmSpecifiedDb..Customer cu (NOLOCK)
        ON D.CustNo = cu.CustNo
    LEFT JOIN ArmSpecifiedDb.dbo.Broker abr (NOLOCK)
        ON D.AcctNo = abr.AcctNo
    OUTER APPLY
    (
        SELECT PoolCurrentAmount = SUM(stp.PoolCurrentAmount),
               PoolPrincipal     = SUM(stp.PoolPrincipal),
               PoolInterest      = SUM(stp.PoolInterest)
        FROM ArmDb.dbo.ArmTradesPools stp (NOLOCK)
        WHERE stp.TradeDetailsKey = D.TradeDetailsKey
    ) P
WHERE B.TradeDate BETWEEN @tradedate1 AND @tradedate2
  AND D.BrokerName <> 'BALORD';

/* =====================================================================
   4. ARMS  -  RC block   (ArmDb)
   Same raw tables; RC-side customer/shared-account resolution.
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     TradeKey, TradeGroupKey, TradeDetailsKey, Cusip, SecurityDesc,
     tradedate, buysell, quantity_orig, tradeprice, tw_tradetype,
     tradetype2, isaggressor, legtype, sectype, trader, dealer, dealer_name)
SELECT
    'ARM-RC',
    'RC',
    'ARMS',
    CAST(B.TradeNo AS varchar(50)) + D.BorS,
    B.TradeNo,
    B.TradeKey,
    C.TradeGroupKey,
    D.TradeDetailsKey,
    Cusip = (SELECT MAX(stp.PoolCusipNo)
             FROM ArmDb.dbo.ArmTradesPools stp (NOLOCK)
             WHERE stp.TradeDetailsKey = D.TradeDetailsKey),
    SecurityDesc = C.SecType + ' ' + CAST(C.Coupon AS varchar(15)),
    B.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    Quantity = ISNULL(P.PoolCurrentAmount, OrigFaceAmount)
               * CASE WHEN sa.Broker_ID_HF IS NOT NULL THEN 0 ELSE 1 END,
    TradePrice = D.Price,
    tw_tradetype = NULL,
    tradetype2   = NULL,
    IsAggressor  = CASE WHEN D.CustCommissions > 0 THEN 1 ELSE 0 END,
    LegType      = NULL,
    SecType      = C.SecType,
    TraderName   = abr.TraderName,
    Dealer       = d.CustNo,
    DealerName   = cu.CustName
FROM ArmDb.dbo.ArmTrades B (NOLOCK)
    INNER JOIN ArmDb.dbo.ArmTradesGroup C (NOLOCK)
        ON B.TradeKey = C.TradeKey
    INNER JOIN ArmDb.dbo.ArmTradesDetails D (NOLOCK)
        ON C.TradeGroupKey = D.TradeGroupKey
    LEFT JOIN ArmSpecifiedDb..Customer cu (NOLOCK)
        ON D.CustNo = cu.CustNo
    LEFT JOIN ArmSpecifiedDb.dbo.Broker abr (NOLOCK)
        ON D.AcctNo = abr.AcctNo
    LEFT JOIN IDB_Reporting.dbo.IDB_HF_SharedAccounts sa
        ON abr.AcctNo COLLATE DATABASE_DEFAULT = sa.SharedAcctNo_HF COLLATE DATABASE_DEFAULT
       AND CONVERT(varchar(8), B.TradeDate, 112)
               BETWEEN sa.EffectiveStartDate AND sa.EffectiveEndDate
       AND sa.ProductGroup = 'ARMS'
    OUTER APPLY
    (
        SELECT PoolCurrentAmount = SUM(stp.PoolCurrentAmount)
        FROM ArmDb.dbo.ArmTradesPools stp (NOLOCK)
        WHERE stp.TradeDetailsKey = D.TradeDetailsKey
    ) P
WHERE B.TradeDate BETWEEN @tradedate1 AND @tradedate2
  AND D.BrokerName <> 'BALORD';

/* =====================================================================
   5. CMO  -  HF block   (CmoDb)
   proc ref: lines 262-338
   Dealer is two hops: CmoTradesDetails.CustNo -> Broker.AcctNo
                                             -> Customer.CustNo
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     Cusip, SecurityDesc, tradedate, buysell, quantity_orig, tradeprice,
     tw_tradetype, tradetype2, isaggressor, legtype, sectype, trader,
     dealer, dealer_name)
SELECT
    'CMO-HF',
    'HF',
    'CMO',
    CAST(T.TradeNo AS varchar(50)) + D.BorS,
    T.TradePartNo,
    Cusip = D.CusipNo,
    SecurityDesc = ISNULL(CAST(ROUND(S.Coupon,5) AS varchar(15)), '') + ' '
                   + ISNULL(S.Issuer, ''),
    T.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    CurrentQuantity = Par * ISNULL(D.Factor, 1.0),
    TradePrice = T.Price,
    tw_tradetype = 'OUTRIGHT',
    tradetype2   = 'OUTRIGHT',
    IsAggressor  = CASE WHEN T.CustCommissions > 0 THEN 1 ELSE 0 END,
    LegType      = NULL,
    SecType      = NULL,
    TraderName   = B.TraderName,
    Dealer       = B.CustNo,
    DealerName   = C.CustName
FROM CmoDb.dbo.CmoTradesDetails T (NOLOCK)
    INNER JOIN CmoDb.dbo.CmoTrades D (NOLOCK)
        ON T.TradeDate = D.TradeDate AND T.TradeNo = D.TradeNo
    LEFT JOIN CmoDb.dbo.Broker B (NOLOCK)
        ON T.CustNo = B.AcctNo
    LEFT JOIN CmoDb.dbo.Customer C (NOLOCK)
        ON B.CustNo = C.CustNo
    LEFT JOIN CmoDb.dbo.Security S (NOLOCK)
        ON D.CusipNo = S.CusipNo
WHERE T.TradeDate BETWEEN @tradedate1 AND @tradedate2;

/* =====================================================================
   6. CMO  -  RC block   (CmoDb)
   Adds the IDB_HF_CMO_SPEC_Brokers (HFB) overlay + shared accounts.
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     Cusip, SecurityDesc, tradedate, buysell, quantity_orig, tradeprice,
     tw_tradetype, tradetype2, isaggressor, legtype, sectype, trader,
     dealer, dealer_name)
SELECT
    'CMO-RC',
    'RC',
    'CMO',
    CAST(T.TradeNo AS varchar(50)) + D.BorS,
    T.TradePartNo,
    Cusip = D.CusipNo,
    SecurityDesc = ISNULL(CAST(ROUND(S.Coupon,5) AS varchar(15)), '') + ' '
                   + ISNULL(S.Issuer, ''),
    T.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    CurrentQuantity = Par * ISNULL(D.Factor, 1.0),
    TradePrice = T.Price,
    tw_tradetype = 'OUTRIGHT',
    tradetype2   = 'OUTRIGHT',
    IsAggressor  = CASE WHEN T.CustCommissions > 0 THEN 1 ELSE 0 END,
    LegType      = HFB.Source,
    SecType      = NULL,
    TraderName   = B.TraderName,
    Dealer       = B.CustNo,
    DealerName   = C.CustName
FROM CmoDb.dbo.CmoTradesDetails T (NOLOCK)
    INNER JOIN CmoDb.dbo.CmoTrades D (NOLOCK)
        ON T.TradeDate = D.TradeDate AND T.TradeNo = D.TradeNo
    LEFT JOIN IDB_Reporting.dbo.IDB_HF_CMO_SPEC_Brokers HFB (NOLOCK)
        ON T.BrokerName = HFB.BrokerName COLLATE SQL_Latin1_General_CP437_CI_AS
       AND T.TradeDate BETWEEN HFB.EffectiveStartDate AND HFB.EffectiveEndDate
    LEFT JOIN CmoDb.dbo.Broker B (NOLOCK)
        ON T.CustNo = B.AcctNo
    LEFT JOIN CmoDb.dbo.Customer C (NOLOCK)
        ON B.CustNo = C.CustNo
    LEFT JOIN CmoDb.dbo.Security S (NOLOCK)
        ON D.CusipNo = S.CusipNo
    LEFT JOIN IDB_Reporting.dbo.IDB_HF_SharedAccounts sa
        ON B.AcctNo COLLATE DATABASE_DEFAULT = sa.SharedAcctNo_HF COLLATE DATABASE_DEFAULT
       AND CONVERT(varchar(8), T.TradeDate, 112)
               BETWEEN sa.EffectiveStartDate AND sa.EffectiveEndDate
       AND sa.ProductGroup = D.SubDept COLLATE DATABASE_DEFAULT
WHERE T.TradeDate BETWEEN @tradedate1 AND @tradedate2;

/* =====================================================================
   7. MBS-Rttm  -  HF block   (MbsDbRttm)
   proc ref: lines 186-268
   Dealer: MbsccData.Cust -> Broker.BrokerAcct -> Customer.CustNo
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     Cusip, SecurityDesc, tradedate, buysell, quantity_orig, tradeprice,
     tw_tradetype, tradetype2, isaggressor, legtype, sectype, trader,
     dealer, dealer_name)
SELECT
    'MBS-HF',
    'HF',
    'MBS',
    CAST(T.TradeNo AS varchar(50)) + CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    T.TradeNo,
    Cusip = T.Cusip,
    SecurityDesc = T.Descriptor,
    T.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    ParAmount = T.ParAmount,
    TradePrice = T.DollarSpread,
    tw_tradetype = 'OUTRIGHT',
    tradetype2   = 'OUTRIGHT',
    IsAggressor  = IDB_Reporting.dbo.fnTradeAggressorVoice(T.Type, T.CommPayer, D.BorS),
    LegType      = T.Type,
    SecType      = T.SecType,
    TraderName   = B.TraderName,
    Dealer       = B.CustNo,
    DealerName   = C.CustName
FROM MbsDbRttm..MbsTrades T (NOLOCK)
    INNER JOIN MbsDbRttm..MbsccData D (NOLOCK)
        ON T.TradeDate = D.TradeDate AND T.TradeNo = D.TradeNo
    LEFT JOIN MbsDbRttm..Broker B (NOLOCK)
        ON D.Cust = B.BrokerAcct
    LEFT JOIN MbsDbRttm..Customer C (NOLOCK)
        ON B.CustNo = C.CustNo
WHERE T.TradeDate BETWEEN @tradedate1 AND @tradedate2;

/* =====================================================================
   8. MBS-Rttm  -  RC block   (MbsDbRttm)
   proc ref: lines 1271-1391  (Division 200 / RC)
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     TradeKey, TradeGroupKey, TradeDetailsKey, Cusip, SecurityDesc,
     tradedate, buysell, quantity_orig, tradeprice, tw_tradetype,
     tradetype2, isaggressor, legtype, sectype, trader, dealer, dealer_name)
SELECT
    'MBS-RC',
    'RC',
    'MBS',
    CAST(B.TradeNo AS varchar(50)) + D.BorS,
    B.TradeNo,
    B.TradeKey,
    C.TradeGroupKey,
    D.TradeDetailsKey,
    Cusip = C.CusipNo,
    SecurityDesc = CASE WHEN ISNULL(C.TbaType,'') = '' AND D.FICCStatus = 'MULT'
                        THEN ISNULL(sm.Description, C.SecType + ' ' + CAST(C.Coupon AS varchar(15)))
                        ELSE C.SecType + ' ' + CAST(C.Coupon AS varchar(15)) END,
    B.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    Quantity = ISNULL(C.OrigFaceAmount, 0)
               * CASE WHEN sa.Broker_ID_HF IS NOT NULL THEN 0 ELSE 1 END,
    TradePrice = D.Price,
    tw_tradetype = CASE WHEN ISNULL(C.TbaType,'') = 'C' THEN 'OUTRIGHT'
                        WHEN ISNULL(C.TbaType,'') IN ('S1','S2','S3') THEN 'BFLY'
                        ELSE 'OUTRIGHT' END,
    tradetype2   = CASE WHEN ISNULL(C.TbaType,'') = 'C' THEN 'OUTRIGHT'
                        WHEN ISNULL(C.TbaType,'') IN ('S1','S2','S3') THEN 'BFLY'
                        ELSE 'OUTRIGHT' END,
    IsAggressor  = CASE WHEN C.CommissionPayer = D.BorS THEN 1
                        WHEN C.CommissionPayer = 'T' THEN 1 ELSE 0 END,
    LegType      = C.TbaType,
    SecType      = C.SecType,
    TraderName   = abr.TraderName,
    Dealer       = d.CustNo,
    DealerName   = cu.CustName
FROM SpecDb.dbo.SpecifiedTrades B (NOLOCK)
    INNER JOIN SpecDb.dbo.SpecifiedTradesGroup C (NOLOCK)
        ON B.TradeKey = C.TradeKey
    INNER JOIN SpecDb.dbo.SpecifiedTradesDetails D (NOLOCK)
        ON C.TradeGroupKey = D.TradeGroupKey
    LEFT JOIN Instrument..Security_Master sm (NOLOCK)
        ON C.CusipNo COLLATE SQL_Latin1_General_CP437_CI_AS = sm.std_sec_id
       AND sm.sec_id = (SELECT MIN(sec_id) FROM Instrument..Security_Master
                        WHERE std_sec_id = C.CusipNo COLLATE SQL_Latin1_General_CP437_CI_AS)
    LEFT JOIN ArmSpecifiedDb..Customer cu (NOLOCK)
        ON d.CustNo = cu.CustNo
    LEFT JOIN ArmSpecifiedDb.dbo.Broker abr (NOLOCK)
        ON d.AcctNo = abr.AcctNo
    LEFT JOIN IDB_Reporting.dbo.IDB_HF_SharedAccounts sa
        ON d.AcctNo COLLATE DATABASE_DEFAULT = sa.SharedAcctNo_HF COLLATE DATABASE_DEFAULT
       AND CONVERT(varchar(8), B.TradeDate, 112)
               BETWEEN sa.EffectiveStartDate AND sa.EffectiveEndDate
       AND sa.ProductGroup = 'SPECIFIED'
WHERE B.TradeDate BETWEEN @tradedate1 AND @tradedate2
  AND B.Division = 200        /* RC */
  AND D.BrokerName <> 'BALORD';

/* =====================================================================
   MASTER DEALER CODE
   Stamp the canonical dealer code onto every row from its own
   Department. Matches proc lines 1403-1407.
   ===================================================================== */
UPDATE D
SET D.master_dealer_code = S.MasterDealerCode
FROM #COMBINED D
JOIN IDB_Reporting.dbo.IDB_DEALER_MASTER S (NOLOCK)
    ON D.dealer     = S.SourceDealerCode
   AND D.department = S.DealerSource;

/* =====================================================================
   FINAL OUTPUT
   ===================================================================== */
SELECT *
FROM #COMBINED
ORDER BY tradedate, dealer;

IF OBJECT_ID('tempdb..#COMBINED') IS NOT NULL DROP TABLE #COMBINED;
