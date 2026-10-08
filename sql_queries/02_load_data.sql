-- ============================================================
-- 02_load_data.sql
-- Load the raw Lending Club CSV into staging_loans, then transform it
-- into the clean customers and loans tables.
--
-- Dataset: Lending Club Loan Data (Kaggle, adarshsng/lending-club-loan-data-csv)
-- Raw file is NOT stored in this repo (about 1.1 GB, not our data).
-- Expected row count after load: 2,260,668
-- ============================================================


-- ------------------------------------------------------------
-- STEP 1: Load the raw CSV into staging_loans
-- ------------------------------------------------------------
-- Done with pgAdmin's Import/Export tool (right-click staging_loans),
-- or the equivalent psql command below. Replace the path with your own.
--
-- IMPORTANT: Escape must be a double quote ("), matching the Quote
-- character. pgAdmin was originally set to an apostrophe ('), which made
-- PostgreSQL misread values ending in an apostrophe before the closing
-- quote (e.g. "Waiter, Maitre D'") and fail with
-- "unterminated CSV quoted field".
--
-- \copy staging_loans FROM 'C:/path/to/loan.csv' WITH (FORMAT csv, DELIMITER ',', HEADER, QUOTE '"', ESCAPE '"');
--
-- Note: the successful load used a copy of the file re-saved through pandas
-- (read with dtype=str, written back with to_csv). The escape setting was
-- the real cause of the earlier failure, so the original file may load fine
-- with the corrected setting too, but that has not been tested.
-- The Excel/pandas detour is not needed for any other step.
--
-- If a failed load left partial rows behind, clear them first:
-- TRUNCATE TABLE staging_loans;

-- Verify the load
SELECT COUNT(*) FROM staging_loans;   -- expect 2260668


-- ------------------------------------------------------------
-- STEP 2: Add a row number to staging_loans
-- ------------------------------------------------------------
-- id and member_id are 100% NULL in this dataset, so there is no usable key.
-- rn gives every staging row a permanent label. Using the same rn as
-- customer_id in BOTH inserts below guarantees each customer row matches
-- its loan row. Two independently generated SERIAL columns would not
-- guarantee this, because insert processing order is not guaranteed.
ALTER TABLE staging_loans ADD COLUMN rn SERIAL;


-- ------------------------------------------------------------
-- STEP 3: Populate customers
-- ------------------------------------------------------------
-- customer_id is SERIAL, but we explicitly supply rn to override the default.
INSERT INTO customers (customer_id, home_ownership, zip_code, addr_state)
SELECT rn, home_ownership, zip_code, addr_state
FROM staging_loans;


-- ------------------------------------------------------------
-- STEP 4: Populate loans (with type casting from TEXT)
-- ------------------------------------------------------------
-- loan_id is left out so SERIAL generates it. customer_id comes from rn.
-- ::DECIMAL / ::INTEGER cast text to numbers; TO_DATE parses 'Dec-2015' style text.
INSERT INTO loans (customer_id, loan_amnt, term, int_rate, grade, sub_grade, purpose,
                   issue_d, loan_status, dti, delinq_2yrs, annual_inc,
                   verification_status, emp_title, emp_length)
SELECT
    rn,
    loan_amnt::DECIMAL,
    term,
    int_rate::DECIMAL,
    grade,
    sub_grade,
    purpose,
    TO_DATE(issue_d, 'Mon-YYYY'),
    loan_status,
    dti::DECIMAL,
    delinq_2yrs::INTEGER,
    annual_inc::DECIMAL,
    verification_status,
    emp_title,
    emp_length
FROM staging_loans;


-- ------------------------------------------------------------
-- STEP 5: Verify (see 03_analysis_queries.sql, Section 1, for the full checks)
-- ------------------------------------------------------------
SELECT
    (SELECT COUNT(*) FROM staging_loans) AS staging_count,
    (SELECT COUNT(*) FROM customers)     AS customers_count,
    (SELECT COUNT(*) FROM loans)         AS loans_count;
-- all three should equal 2260668
