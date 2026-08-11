/* =====================================================================
   DW_MBS.sql   (5-block version)
   ---------------------------------------------------------------------
   Rebuilds the MBS-family voice-trade dataset from the RAW tables,
   replacing a query against IDB_Reporting.dbo.IDB_DEAL_VOICE (being
   decommissioned). Logic lifted from IDB_Reporting.dbo.LoadVoiceTradeData.

   BLOCKS (5, not 8):
     1. SPECIFIED  HF   (SpecDb, Division 100)   \_ Specified keeps BOTH
     2. SPECIFIED  RC   (SpecDb, Division 200)   /  department blocks
     3. ARMS            (ArmDb)        - single block (HF logic)
     4. CMO             (CmoDb)        - single block; SubDept = productgroup
     5. MBS-Rttm        (MbsDbRttm)    - single block (HF logic)

   The HF/RC split only produces distinct rows for SPECIFIED. Running
   both blocks for ARMS / CMO / MBS double-counted, so those are ONE
   block each now.

   BILLING CONVENTION: rate = 1, so dealer_commission IS the gross fee.
   The final SELECT outputs  dealer_commission AS quantity.

   >>> VERIFY BEFORE PRODUCTION - these become the invoice with rate=1:
       - Spec / ARM dealer_commission -> D.DealerCommission  (if this
         column doesn't exist you'll get Msg 207; the detail table may
         name it CustCommissions or BrokerCommission - swap accordingly)
       - CMO dealer_commission -> T.BrokerCommissions  (CmoTradesDetails
         also has CustCommissions - confirm which is the billable one)
       - MBS dealer_commission -> T.Commissions  (confirmed present on
         MbsTrades)
   ===================================================================== */

SET NOCOUNT ON;

DECLARE @dealer     VARCHAR(8);         -- optional; leave NULL for all dealers
DECLARE @tradedate1 DATETIME,
        @tradedate2 DATETIME;
SET @tradedate1 = '20241201';
SET @tradedate2 = '20241231';

/* ---------------------------------------------------------------------
   Common staging table.
   --------------------------------------------------------------------- */
IF OBJECT_ID('tempdb..#COMBINED') IS NOT NULL DROP TABLE #COMBINED;
CREATE TABLE #COMBINED
(
    source_tag        varchar(16)   NULL,   -- 'SPEC-HF', 'ARMS', SubDept for CMO, etc.
    department        varchar(5)    NULL,   -- 'HF' / 'RC'  (drives master-code join)
    productgroup      varchar(20)   NULL,   -- 'SPECIFIED' / 'ARMS' / ABS|CORP|CMBS|CMO / 'MBS'
    trade_id          varchar(60)   NULL,
    deal_negotiation_id varchar(30) NULL,
    TradeKey          nchar(12)     NULL,
    TradeGroupKey     nchar(14)     NULL,
    TradeDetailsKey   nvarchar(16)  NULL,
    Cusip             varchar(50)   NULL,
    SecurityDesc      varchar(255)  NULL,
    tradedate         datetime      NULL,
    buysell           varchar(5)    NULL,
    quantity_orig     decimal(20,6) NULL,   -- face/par or factored current, per source
    tradeprice        varchar(30)   NULL,
    tw_tradetype      varchar(25)   NULL,
    tradetype2        varchar(25)   NULL,
    isaggressor       char(1)       NULL,
    legtype           varchar(20)   NULL,
    sectype           nvarchar(4)   NULL,
    trader            varchar(50)   NULL,
    dealer            varchar(100)  NULL,   -- CustNo (source dealer number)
    dealer_name       varchar(255)  NULL,   -- CustName
    dealer_commission float         NULL,   -- rate=1 => this is the gross fee
    master_dealer_code varchar(10)  NULL    -- filled by UPDATE at the end
);

/* =====================================================================
   1. SPECIFIED  -  HF block   (SpecDb, Division 100)
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     TradeKey, TradeGroupKey, TradeDetailsKey, Cusip, SecurityDesc,
     tradedate, buysell, quantity_orig, tradeprice, tw_tradetype,
     tradetype2, isaggressor, legtype, sectype, trader, dealer,
     dealer_name, dealer_commission)
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
    DealerName   = cu.CustName,
    DealerCommission = D.DealerCommission          -- <<< VERIFY column
FROM IDBREPORTS2.SpecDb.dbo.SpecifiedTrades B (NOLOCK)
    INNER JOIN IDBREPORTS2.SpecDb.dbo.SpecifiedTradesGroup C (NOLOCK)
        ON B.TradeKey = C.TradeKey
    INNER JOIN IDBREPORTS2.SpecDb.dbo.SpecifiedTradesDetails D (NOLOCK)
        ON C.TradeGroupKey = D.TradeGroupKey
    LEFT JOIN IDBREPORTS2.SpecDb.dbo.SpecifiedTradesPools P (NOLOCK)
        ON D.TradeDetailsKey = P.TradeDetailsKey
    LEFT JOIN IDBREPORTS2.ArmSpecifiedDb.dbo.Customer cu (NOLOCK)
        ON D.CustNo = cu.CustNo
    LEFT JOIN IDBREPORTS2.ArmSpecifiedDb.dbo.Broker abr (NOLOCK)
        ON D.AcctNo = abr.AcctNo
WHERE B.TradeDate BETWEEN @tradedate1 AND @tradedate2
  AND B.Division = 100        /* HF */
  AND D.BrokerName <> 'BALORD';

/* =====================================================================
   2. SPECIFIED  -  RC block   (SpecDb, Division 200)
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     TradeKey, TradeGroupKey, TradeDetailsKey, Cusip, SecurityDesc,
     tradedate, buysell, quantity_orig, tradeprice, tw_tradetype,
     tradetype2, isaggressor, legtype, sectype, trader, dealer,
     dealer_name, dealer_commission)
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
    DealerName   = cu.CustName,
    DealerCommission = D.DealerCommission          -- <<< VERIFY column
FROM IDBREPORTS2.SpecDb.dbo.SpecifiedTrades B (NOLOCK)
    INNER JOIN IDBREPORTS2.SpecDb.dbo.SpecifiedTradesGroup C (NOLOCK)
        ON B.TradeKey = C.TradeKey
    INNER JOIN IDBREPORTS2.SpecDb.dbo.SpecifiedTradesDetails D (NOLOCK)
        ON C.TradeGroupKey = D.TradeGroupKey
    LEFT JOIN IDBREPORTS2.ArmSpecifiedDb.dbo.Customer cu (NOLOCK)
        ON D.CustNo = cu.CustNo
    LEFT JOIN IDBREPORTS2.ArmSpecifiedDb.dbo.Broker abr (NOLOCK)
        ON D.AcctNo = abr.AcctNo
    LEFT JOIN IDBREPORTS2.IDB_Reporting.dbo.IDB_HF_SharedAccounts sa
        ON abr.AcctNo COLLATE DATABASE_DEFAULT = sa.SharedAcctNo_HF COLLATE DATABASE_DEFAULT
       AND CONVERT(varchar(8), B.TradeDate, 112)
               BETWEEN sa.EffectiveStartDate AND sa.EffectiveEndDate
       AND sa.ProductGroup = 'SPECIFIED'
WHERE B.TradeDate BETWEEN @tradedate1 AND @tradedate2
  AND B.Division = 200        /* RC */
  AND abr.BrokerName <> 'BALORD';

/* =====================================================================
   3. ARMS   (ArmDb)   - single block
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     TradeKey, TradeGroupKey, TradeDetailsKey, Cusip, SecurityDesc,
     tradedate, buysell, quantity_orig, tradeprice, tw_tradetype,
     tradetype2, isaggressor, legtype, sectype, trader, dealer,
     dealer_name, dealer_commission)
SELECT
    'ARMS',
    'HF',                                  -- single block; department not
                                           -- critical for ARMS (see notes)
    'ARMS',
    CAST(B.TradeNo AS varchar(50)) + D.BorS,
    B.TradeNo,
    B.TradeKey,
    C.TradeGroupKey,
    D.TradeDetailsKey,
    Cusip = (SELECT MAX(stp.PoolCusipNo)
             FROM IDBREPORTS2.ArmDb.dbo.ArmTradesPools stp (NOLOCK)
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
    DealerName   = cu.CustName,
    DealerCommission = D.DealerCommission          -- <<< VERIFY column
FROM IDBREPORTS2.ArmDb.dbo.ArmTrades B (NOLOCK)
    INNER JOIN IDBREPORTS2.ArmDb.dbo.ArmTradesGroup C (NOLOCK)
        ON B.TradeKey = C.TradeKey
    INNER JOIN IDBREPORTS2.ArmDb.dbo.ArmTradesDetails D (NOLOCK)
        ON C.TradeGroupKey = D.TradeGroupKey
    LEFT JOIN IDBREPORTS2.ArmSpecifiedDb.dbo.Customer cu (NOLOCK)
        ON D.CustNo = cu.CustNo
    LEFT JOIN IDBREPORTS2.ArmSpecifiedDb.dbo.Broker abr (NOLOCK)
        ON D.AcctNo = abr.AcctNo
    OUTER APPLY
    (
        SELECT PoolCurrentAmount = SUM(stp.PoolCurrentAmount),
               PoolPrincipal     = SUM(stp.PoolPrincipal),
               PoolInterest      = SUM(stp.PoolInterest)
        FROM IDBREPORTS2.ArmDb.dbo.ArmTradesPools stp (NOLOCK)
        WHERE stp.TradeDetailsKey = D.TradeDetailsKey
    ) P
WHERE B.TradeDate BETWEEN @tradedate1 AND @tradedate2
  AND D.BrokerName <> 'BALORD';

/* =====================================================================
   4. CMO   (CmoDb)   - single block
   SubDept (ABS / CORP / CMBS / CMO) is the product group AND source_tag.
   Dealer is two hops: CmoTradesDetails.CustNo -> Broker.AcctNo
                                              -> Customer.CustNo
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     Cusip, SecurityDesc, tradedate, buysell, quantity_orig, tradeprice,
     tw_tradetype, tradetype2, isaggressor, legtype, sectype, trader,
     dealer, dealer_name, dealer_commission)
SELECT
    ISNULL(D.SubDept, 'CMO'),              -- source_tag = SubDept
    'HF',                                  -- department not critical for CMO
    ISNULL(D.SubDept, 'CMO'),              -- productgroup = SubDept
    CAST(T.TradeNo AS varchar(50)) + T.BorS,
    T.TradePartNo,
    Cusip = D.CusipNo,
    SecurityDesc = ISNULL(CAST(ROUND(S.Coupon,5) AS varchar(15)), '') + ' '
                   + ISNULL(S.Issuer, ''),
    T.TradeDate,
    BorS = CASE T.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    CurrentQuantity = T.Par * ISNULL(D.Factor, 1.0),
    TradePrice = T.Price,
    tw_tradetype = 'OUTRIGHT',
    tradetype2   = 'OUTRIGHT',
    IsAggressor  = CASE WHEN T.CustCommissions > 0 THEN 1 ELSE 0 END,
    LegType      = NULL,
    SecType      = NULL,
    TraderName   = B.TraderName,
    Dealer       = B.CustNo,
    DealerName   = C.CustName,
    DealerCommission = T.BrokerCommissions         -- <<< VERIFY: Broker vs Cust
FROM IDBREPORTS2.CmoDb.dbo.CmoTradesDetails T (NOLOCK)
    INNER JOIN IDBREPORTS2.CmoDb.dbo.CmoTrades D (NOLOCK)
        ON T.TradeDate = D.TradeDate AND T.TradeNo = D.TradeNo
    LEFT JOIN IDBREPORTS2.CmoDb.dbo.Broker B (NOLOCK)
        ON T.CustNo = B.AcctNo
    LEFT JOIN IDBREPORTS2.CmoDb.dbo.Customer C (NOLOCK)
        ON B.CustNo = C.CustNo
    LEFT JOIN IDBREPORTS2.CmoDb.dbo.Security S (NOLOCK)
        ON D.CusipNo = S.CusipNo
WHERE T.TradeDate BETWEEN @tradedate1 AND @tradedate2;

/* =====================================================================
   5. MBS-Rttm   (MbsDbRttm)   - single block
   Dealer: MbsccData.Cust -> Broker.BrokerAcct -> Customer.CustNo
   fnTradeAggressorVoice inlined (functions not permitted).
   ===================================================================== */
INSERT INTO #COMBINED
    (source_tag, department, productgroup, trade_id, deal_negotiation_id,
     Cusip, SecurityDesc, tradedate, buysell, quantity_orig, tradeprice,
     tw_tradetype, tradetype2, isaggressor, legtype, sectype, trader,
     dealer, dealer_name, dealer_commission)
SELECT
    'MBS',
    'HF',                                  -- department not critical for MBS
    'MBS',
    CAST(T.TradeNo AS varchar(50)) + D.BorS,
    T.TradeNo,
    Cusip = T.Cusip,
    SecurityDesc = T.Descriptor,
    T.TradeDate,
    BorS = CASE D.BorS WHEN 'B' THEN 'S' WHEN 'S' THEN 'B' END,
    ParAmount = T.ParAmount,
    TradePrice = T.DollarSpread,
    tw_tradetype = 'OUTRIGHT',
    tradetype2   = 'OUTRIGHT',
    IsAggressor  = CASE
                     WHEN T.Type IN ('S1','R1','S3','R3','C') AND T.CommPayer <> D.BorS THEN 0
                     WHEN T.Type IN ('S2','R2')              AND T.CommPayer =  D.BorS THEN 0
                     ELSE 1
                   END,
    LegType      = T.Type,
    SecType      = T.SecType,
    TraderName   = B.TraderName,
    Dealer       = B.CustNo,
    DealerName   = C.CustName,
    DealerCommission = T.Commissions               -- confirmed on MbsTrades
FROM IDBREPORTS2.MbsDbRttm.dbo.MbsTrades T (NOLOCK)
    INNER JOIN IDBREPORTS2.MbsDbRttm.dbo.MbsccData D (NOLOCK)
        ON T.TradeDate = D.TradeDate AND T.TradeNo = D.TradeNo
    LEFT JOIN IDBREPORTS2.MbsDbRttm.dbo.Broker B (NOLOCK)
        ON D.Cust = B.BrokerAcct
    LEFT JOIN IDBREPORTS2.MbsDbRttm.dbo.Customer C (NOLOCK)
        ON B.CustNo = C.CustNo
WHERE T.TradeDate BETWEEN @tradedate1 AND @tradedate2;

/* =====================================================================
   MASTER DEALER CODE
   Stamp the canonical dealer code from each row's own Department.
   For SPECIFIED this resolves HF vs RC correctly; for the single-block
   products it uses the 'HF' literal above (see notes).
   ===================================================================== */
UPDATE D
SET D.master_dealer_code = S.MasterDealerCode
FROM #COMBINED D
JOIN IDBREPORTS2.IDB_Reporting.dbo.IDB_DEALER_MASTER S (NOLOCK)
    ON D.dealer     = S.SourceDealerCode
   AND D.department = S.DealerSource;

/* =====================================================================
   FINAL OUTPUT
   rate = 1, so dealer_commission is surfaced AS quantity.
   Optional dealer filter applied here (leave @dealer NULL for all).
   ===================================================================== */
SELECT dealer_commission AS quantity, *
FROM #COMBINED
WHERE (@dealer IS NULL OR @dealer = dealer)
ORDER BY tradedate, dealer;

IF OBJECT_ID('tempdb..#COMBINED') IS NOT NULL DROP TABLE #COMBINED;
