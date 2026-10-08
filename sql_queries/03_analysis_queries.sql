-- ============================================================
-- 03_analysis_queries.sql
-- Credit risk analysis on Lending Club loan data (PostgreSQL)
-- Tables: customers, loans  (staging_loans = raw landing table)
--
-- Default flag definition used throughout:
--   1 (default)     = Charged Off, Default,
--                     Does not meet the credit policy. Status:Charged Off
--   0 (not default) = Fully Paid,
--                     Does not meet the credit policy. Status:Fully Paid
--   NULL (excluded) = Current, In Grace Period, Late (16-30 days),
--                     Late (31-120 days)  -> outcome not yet resolved
-- AVG() ignores NULLs, so averaging the flag gives the default rate
-- among resolved loans only.
-- ============================================================


-- ------------------------------------------------------------
-- SECTION 1: DATA VALIDATION AND CLEANING
-- ------------------------------------------------------------

-- Row counts across all three tables should match (2,260,668)
SELECT
    (SELECT COUNT(*) FROM staging_loans) AS staging_count,
    (SELECT COUNT(*) FROM customers)     AS customers_count,
    (SELECT COUNT(*) FROM loans)         AS loans_count;

-- Spot-check that customer_id links back to the right raw staging row
-- (c, l, s are table aliases)
SELECT
    c.customer_id,
    c.home_ownership,
    l.loan_amnt,
    l.grade,
    s.rn,
    s.home_ownership AS staging_home_ownership,
    s.loan_amnt      AS staging_loan_amnt
FROM customers c
JOIN loans l ON l.customer_id = c.customer_id
JOIN staging_loans s ON s.rn = c.customer_id
LIMIT 5;

-- Sanity-check casts did not produce nonsense values
SELECT COUNT(*) FROM loans WHERE issue_d IS NULL;

SELECT MIN(loan_amnt), MAX(loan_amnt),
       MIN(int_rate),  MAX(int_rate),
       MIN(annual_inc), MAX(annual_inc)
FROM loans;

SELECT MIN(dti), MAX(dti), MIN(delinq_2yrs), MAX(delinq_2yrs)
FROM loans;

-- Finding: dti contained -1 in 2 rows (a sentinel value for "missing").
-- Checked how widespread it was, then replaced with a real NULL.
SELECT COUNT(*) FROM loans WHERE dti = -1;
SELECT COUNT(*) FROM loans WHERE dti < 0;

UPDATE loans
SET dti = NULL
WHERE dti = -1;

SELECT MIN(dti), MAX(dti) FROM loans;

-- Housekeeping: row-number helper column no longer needed
-- ALTER TABLE staging_loans DROP COLUMN rn;


-- ------------------------------------------------------------
-- SECTION 2: EXPLORING loan_status
-- ------------------------------------------------------------

-- All distinct loan_status values and their counts
-- (used to decide how to build the default flag)
SELECT loan_status, COUNT(*)
FROM loans
GROUP BY loan_status;

-- Loans that were late but unresolved at the time of data capture
-- Finding: 3,737 loans Late (16-30 days); 21,897 loans Late (31-120 days)
SELECT loan_status, COUNT(*) AS num_loans
FROM loans
WHERE loan_status IN ('Late (16-30 days)', 'Late (31-120 days)')
GROUP BY loan_status;

-- The default flag as a row-level column (SELECT does not store it)
SELECT
    loan_status,
    CASE
        WHEN loan_status IN ('Charged Off', 'Default', 'Does not meet the credit policy. Status:Charged Off') THEN 1
        WHEN loan_status IN ('Fully Paid', 'Does not meet the credit policy. Status:Fully Paid') THEN 0
        ELSE NULL
    END AS is_default
FROM loans;


-- ------------------------------------------------------------
-- SECTION 3: DEFAULT RATE ANALYSIS
-- ------------------------------------------------------------

-- Number of loans per grade
SELECT grade, COUNT(*) AS num_loans
FROM loans
GROUP BY grade;

-- Average interest rate per grade
SELECT grade, AVG(int_rate) AS average_g
FROM loans
GROUP BY grade;

-- Default rate by grade
-- Finding: rises steadily from ~6.1% (A) to ~49.8% (G), confirming the
-- grading system is risk-ordered. Grade is known at origination, so it is
-- not outcome leakage, but it is a proxy for Lending Club's own risk model.
SELECT
    grade,
    ROUND(AVG(
        CASE
            WHEN loan_status IN ('Charged Off', 'Default', 'Does not meet the credit policy. Status:Charged Off') THEN 1
            WHEN loan_status IN ('Fully Paid', 'Does not meet the credit policy. Status:Fully Paid') THEN 0
            ELSE NULL
        END
    ), 4) AS default_rate
FROM loans
GROUP BY grade
ORDER BY grade;

-- Default rate by home ownership (needs a JOIN: home_ownership is in customers)
-- Finding: RENT highest at ~23.4%, MORTGAGE lowest of the large groups at ~17.3%.
-- OWN (~20.8%) sits above MORTGAGE. NONE is likely a tiny category.
SELECT
    c.home_ownership,
    ROUND(AVG(
        CASE
            WHEN l.loan_status IN ('Charged Off', 'Default', 'Does not meet the credit policy. Status:Charged Off') THEN 1
            WHEN l.loan_status IN ('Fully Paid', 'Does not meet the credit policy. Status:Fully Paid') THEN 0
            ELSE NULL
        END
    ), 4) AS default_rate_home_ownership
FROM loans l
JOIN customers c ON l.customer_id = c.customer_id
GROUP BY c.home_ownership
ORDER BY c.home_ownership;

-- Default rate by loan purpose
-- Finding: small_business highest (~29.9%), wedding lowest (~12.4%),
-- car ~14.7%. debt_consolidation sits near the overall average (~21.3%).
SELECT
    purpose,
    ROUND(AVG(
        CASE
            WHEN loan_status IN ('Charged Off', 'Default', 'Does not meet the credit policy. Status:Charged Off') THEN 1
            WHEN loan_status IN ('Fully Paid', 'Does not meet the credit policy. Status:Fully Paid') THEN 0
            ELSE NULL
        END
    ), 4) AS default_rate_purpose
FROM loans
GROUP BY purpose
ORDER BY purpose;

-- Default rate by income verification status, with volumes
-- Finding: Not Verified ~14.8%, Source Verified ~21.1%, Verified ~23.9%.
-- Verified loans default MORE, consistent with a selection effect (riskier
-- loans were verified more often) and possibly a loan-vintage effect.
-- num_loans counts all rows; num_resolved counts only loans used in the rate.
-- Only ~58% of the dataset is resolved (Current/Late/Grace loans excluded).
SELECT
    verification_status,
    ROUND(AVG(
        CASE
            WHEN loan_status IN ('Charged Off', 'Default', 'Does not meet the credit policy. Status:Charged Off') THEN 1
            WHEN loan_status IN ('Fully Paid', 'Does not meet the credit policy. Status:Fully Paid') THEN 0
            ELSE NULL
        END
    ), 4) AS default_rate,
    COUNT(*) AS num_loans,
    COUNT(
        CASE
            WHEN loan_status IN ('Charged Off', 'Default', 'Does not meet the credit policy. Status:Charged Off') THEN 1
            WHEN loan_status IN ('Fully Paid', 'Does not meet the credit policy. Status:Fully Paid') THEN 0
            ELSE NULL
        END
    ) AS num_resolved
FROM loans
GROUP BY verification_status
ORDER BY verification_status;


-- ------------------------------------------------------------
-- TO ADD (remaining Phase 4 queries)
-- ------------------------------------------------------------
-- 1. Default rate and volume by issue year (EXTRACT(YEAR FROM issue_d))
-- 2. Multi-column breakdown (e.g. grade and home_ownership together)
