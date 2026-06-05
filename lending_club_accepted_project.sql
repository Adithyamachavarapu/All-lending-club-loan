/* =================================================================================================
   Lending Club Accepted Loans SQL Project
   Dataset: accepted.csv
   SQL Dialect: MySQL 8.0+

   Assumption:
   The accepted.csv file was uploaded through MySQL Workbench Import Wizard
   and the table name is accepted.

   Project Focus:
   Credit risk, vintage analysis, borrower risk tiers, geographic concentration,
   NPA reporting, and monthly charge-off trends.
================================================================================================= */

USE lending_club_data;


/* -------------------------------------------------------------------------------------------------
   0. Create a Clean Working View

   Why this step is needed:
   The Import Wizard may load fields like int_rate, dti, and issue_d as text.
   This view standardizes the important columns once, so the reporting queries stay clean.

   Main charge-off definition used in this project:
   loan_status IN ('Charged Off', 'Default')
------------------------------------------------------------------------------------------------- */

CREATE OR REPLACE VIEW vw_accepted_clean AS
SELECT
    id,
    loan_amnt,
    funded_amnt,
    grade,
    loan_status,
    CAST(REPLACE(int_rate, '%', '') AS DECIMAL(8, 4)) AS int_rate_clean,
    issue_d,
    CAST(SUBSTRING(issue_d, -4) AS UNSIGNED) AS vintage_year,
    STR_TO_DATE(CONCAT('01-', issue_d), '%d-%b-%Y') AS issue_month,
    addr_state,
    CAST(REPLACE(dti, '%', '') AS DECIMAL(10, 4)) AS dti_clean,
    fico_range_low,
    total_pymnt,
    recoveries
FROM accepted
WHERE id IS NOT NULL;


/* ================================================================================================
   Q1. Loan Grade Default Rate vs Portfolio Benchmark

   Business Question:
   Which loan grades perform worse than the total portfolio charge-off benchmark?

   What the query does:
   1. Groups loans by grade.
   2. Calculates charge-off count and charge-off rate.
   3. Uses window functions to calculate the portfolio charge-off benchmark.
   4. Flags grades above or below the benchmark.

   Business Insight:
   The dataset should show a clear risk ladder from A to G.
   In the scan of this accepted.csv file:
   A = 3.28%, B = 7.92%, C = 13.18%, D = 18.82%,
   E = 26.57%, F = 34.67%, G = 37.48%.
   Grade G is the highest-risk grade and is a useful validation check.
================================================================================================ */

WITH grade_summary AS (
    SELECT
        grade,
        COUNT(*) AS total_loans,
        SUM(CASE WHEN loan_status IN ('Charged Off', 'Default') THEN 1 ELSE 0 END) AS charged_off_count,
        AVG(int_rate_clean) AS avg_int_rate,
        AVG(loan_amnt) AS avg_loan_amnt
    FROM vw_accepted_clean
    WHERE grade IN ('A', 'B', 'C', 'D', 'E', 'F', 'G')
    GROUP BY grade
)
SELECT
    grade,
    total_loans,
    charged_off_count,
    ROUND(100 * charged_off_count / total_loans, 2) AS charge_off_rate_pct,
    ROUND(avg_int_rate, 2) AS avg_int_rate,
    ROUND(avg_loan_amnt, 2) AS avg_loan_amnt,
    ROUND(
        100 * SUM(charged_off_count) OVER () / SUM(total_loans) OVER (),
        2
    ) AS portfolio_avg_charge_off_rate,
    CASE
        WHEN charged_off_count / total_loans >
             SUM(charged_off_count) OVER () / SUM(total_loans) OVER ()
        THEN 'Above Benchmark'
        ELSE 'Below Benchmark'
    END AS benchmark_flag
FROM grade_summary
ORDER BY charge_off_rate_pct DESC;


/* ================================================================================================
   Q2. Loan Vintage Cohort Charge-Off Analysis

   Business Question:
   Which origination years produced the weakest loan performance?

   What the query does:
   1. Extracts the issue year from issue_d.
   2. Aggregates total loans, funded amount, and charge-offs by vintage year.
   3. Uses RANK() to rank vintages from worst to best by charge-off rate.

   Business Insight:
   In this dataset scan, 2015 had the worst vintage charge-off rate at about 18.00%,
   followed by 2014 at about 17.47%.
   Newer vintages can look safer because they may not be fully seasoned yet.
================================================================================================ */

WITH vintage_summary AS (
    SELECT
        vintage_year,
        COUNT(*) AS total_loans,
        SUM(funded_amnt) AS total_funded_amnt,
        SUM(CASE WHEN loan_status IN ('Charged Off', 'Default') THEN 1 ELSE 0 END) AS charged_off_count
    FROM vw_accepted_clean
    WHERE vintage_year IS NOT NULL
    GROUP BY vintage_year
),
vintage_ranked AS (
    SELECT
        vintage_year,
        total_loans,
        total_funded_amnt,
        charged_off_count,
        ROUND(100 * charged_off_count / total_loans, 2) AS charge_off_rate_pct,
        RANK() OVER (ORDER BY charged_off_count / total_loans DESC) AS worst_vintage_rank
    FROM vintage_summary
)
SELECT
    vintage_year,
    total_loans,
    ROUND(total_funded_amnt, 2) AS total_funded_amnt,
    charged_off_count,
    charge_off_rate_pct,
    worst_vintage_rank
FROM vintage_ranked
ORDER BY vintage_year ASC;


/* ================================================================================================
   Q3. Borrower Risk Tiering - DTI x FICO Cross-Segmentation

   Business Question:
   Is LendingClub pricing borrower risk properly?

   Risk Tier Logic:
   Low Risk    = FICO >= 720 AND DTI <= 15
   High Risk   = FICO < 660 OR DTI > 30
   Medium Risk = everyone else

   What the query does:
   1. Classifies borrowers using FICO and DTI together.
   2. Calculates average DTI, FICO, interest rate, and charge-off rate.
   3. Adds the total portfolio charge-off rate using a scalar subquery.
   4. Removes small/unreliable groups using HAVING.

   Business Insight:
   In this accepted.csv scan:
   Low Risk charge-off rate is about 5.38% with 9.30% average interest.
   Medium Risk charge-off rate is about 12.24% with 13.29% average interest.
   High Risk charge-off rate is about 15.23% with 15.10% average interest.
   The High Risk tier is the main pricing question because its average interest rate is close
   to its observed charge-off rate.
================================================================================================ */

WITH borrower_tiers AS (
    SELECT
        id,
        loan_status,
        dti_clean,
        fico_range_low,
        int_rate_clean,
        CASE
            WHEN fico_range_low >= 720 AND dti_clean <= 15 THEN 'Low Risk'
            WHEN fico_range_low < 660 OR dti_clean > 30 THEN 'High Risk'
            ELSE 'Medium Risk'
        END AS risk_tier
    FROM vw_accepted_clean
    WHERE fico_range_low IS NOT NULL
      AND dti_clean IS NOT NULL
)
SELECT
    risk_tier,
    COUNT(*) AS borrower_count,
    ROUND(AVG(dti_clean), 2) AS avg_dti,
    ROUND(AVG(fico_range_low), 2) AS avg_fico_score,
    ROUND(AVG(int_rate_clean), 2) AS avg_int_rate,
    ROUND(100 * AVG(CASE WHEN loan_status IN ('Charged Off', 'Default') THEN 1 ELSE 0 END), 2) AS tier_charge_off_rate_pct,
    (
        SELECT
            ROUND(100 * AVG(CASE WHEN loan_status IN ('Charged Off', 'Default') THEN 1 ELSE 0 END), 2)
        FROM vw_accepted_clean
    ) AS portfolio_charge_off_rate_pct
FROM borrower_tiers
GROUP BY risk_tier
HAVING COUNT(*) >= 500
ORDER BY tier_charge_off_rate_pct DESC;


/* ================================================================================================
   Q4. State-Level Geographic Risk Concentration Alert

   Business Question:
   Which large-exposure states have above-average charge-off risk?

   What the query does:
   1. Groups loans by addr_state.
   2. Calculates state loan count, funded amount, and charge-off rate.
   3. Uses SUM() OVER() to calculate portfolio funded share and national charge-off rate.
   4. Returns only the top 10 states by funded amount.
   5. Adds a simple geographic risk flag.

   Risk Flag Logic:
   High Risk = state charge-off rate is more than 5 percentage points above national rate.
   At Risk   = state charge-off rate is above national rate, but within 5 percentage points.
   Healthy   = state charge-off rate is at or below national rate.

   Business Insight:
   California is the largest exposure state at about 14.13% of funded amount.
   The national charge-off rate is about 11.88%.
   Among the top exposure states, CA, NY, FL, NJ, PA, OH, and VA sit above the national rate,
   but not by more than 5 percentage points.
================================================================================================ */

WITH state_summary AS (
    SELECT
        addr_state,
        COUNT(*) AS total_loans,
        SUM(funded_amnt) AS total_funded_amnt,
        SUM(CASE WHEN loan_status IN ('Charged Off', 'Default') THEN 1 ELSE 0 END) AS charged_off_count
    FROM vw_accepted_clean
    WHERE addr_state IS NOT NULL
    GROUP BY addr_state
),
state_benchmark AS (
    SELECT
        addr_state,
        total_loans,
        total_funded_amnt,
        charged_off_count,
        100 * total_funded_amnt / SUM(total_funded_amnt) OVER () AS portfolio_share_pct,
        100 * charged_off_count / total_loans AS state_charge_off_rate_pct,
        100 * SUM(charged_off_count) OVER () / SUM(total_loans) OVER () AS national_charge_off_rate_pct,
        RANK() OVER (ORDER BY total_funded_amnt DESC) AS funded_amount_rank
    FROM state_summary
)
SELECT
    addr_state,
    total_loans,
    ROUND(total_funded_amnt, 2) AS total_funded_amnt,
    ROUND(portfolio_share_pct, 2) AS portfolio_share_pct,
    ROUND(state_charge_off_rate_pct, 2) AS state_charge_off_rate_pct,
    ROUND(national_charge_off_rate_pct, 2) AS national_charge_off_rate_pct,
    CASE
        WHEN state_charge_off_rate_pct > national_charge_off_rate_pct + 5 THEN 'High Risk'
        WHEN state_charge_off_rate_pct > national_charge_off_rate_pct THEN 'At Risk'
        ELSE 'Healthy'
    END AS risk_flag
FROM state_benchmark
WHERE funded_amount_rank <= 10
ORDER BY total_funded_amnt DESC;


/* ================================================================================================
   Q5. NPA Classification and Collections Recovery Rate Report

   Business Question:
   How are non-performing loans distributed by severity, and how much has been recovered?

   NPA Logic:
   Substandard = Late (16-30 days)
   Doubtful    = Late (31-120 days)
   Loss        = Charged Off or Default

   What the query does:
   1. Filters only non-performing loans.
   2. Classifies each loan into an NPA bucket.
   3. Aggregates loan count, outstanding principal, recoveries, recovery rate, and interest rate.
   4. Sorts the result manually by severity.

   Business Insight:
   Loss loans dominate the NPA pool.
   In this accepted.csv scan, Loss loans have about $1.99B outstanding principal and about 7.77%
   recovery rate. Doubtful and Substandard buckets show zero recoveries in this snapshot, so those
   buckets are more useful for early collections prioritization.
================================================================================================ */

WITH npa_loans AS (
    SELECT
        id,
        loan_status,
        loan_amnt,
        total_pymnt,
        recoveries,
        int_rate_clean,
        CASE
            WHEN loan_status IN ('Charged Off', 'Default') THEN 'Loss'
            WHEN loan_status = 'Late (31-120 days)' THEN 'Doubtful'
            WHEN loan_status = 'Late (16-30 days)' THEN 'Substandard'
        END AS npa_bucket
    FROM vw_accepted_clean
    WHERE loan_status IN ('Charged Off', 'Default', 'Late (31-120 days)', 'Late (16-30 days)')
)
SELECT
    npa_bucket,
    COUNT(*) AS loan_count,
    ROUND(SUM(loan_amnt - total_pymnt), 2) AS total_outstanding_principal,
    ROUND(SUM(recoveries), 2) AS total_recoveries,
    ROUND(100 * SUM(recoveries) / NULLIF(SUM(loan_amnt), 0), 2) AS recovery_rate_pct,
    ROUND(AVG(int_rate_clean), 2) AS avg_int_rate
FROM npa_loans
GROUP BY npa_bucket
ORDER BY
    CASE
        WHEN npa_bucket = 'Loss' THEN 1
        WHEN npa_bucket = 'Doubtful' THEN 2
        WHEN npa_bucket = 'Substandard' THEN 3
    END;


/* ================================================================================================
   Q6. Monthly Charge-Off Trend with 3-Month Rolling Average and MoM Change

   Business Question:
   Are charge-offs increasing month over month, or is a spike just short-term noise?

   What the query does:
   1. Parses issue_d into a real month value.
   2. Aggregates loans issued and charge-offs by month.
   3. Calculates monthly charge-off rate.
   4. Uses a 3-month rolling average to smooth the trend.
   5. Uses LAG() to calculate month-over-month change.

   Business Insight:
   This is the strongest time-series query in the project.
   In the accepted.csv scan, March 2016 had the highest charged-off count by issue month,
   with 10,595 charge-offs from 61,992 issued loans.
================================================================================================ */

WITH monthly_base AS (
    SELECT
        DATE_FORMAT(issue_month, '%Y-%m') AS loan_month,
        COUNT(*) AS total_loans_issued,
        SUM(CASE WHEN loan_status IN ('Charged Off', 'Default') THEN 1 ELSE 0 END) AS charged_off_count
    FROM vw_accepted_clean
    WHERE issue_month IS NOT NULL
    GROUP BY DATE_FORMAT(issue_month, '%Y-%m')
),
monthly_with_windows AS (
    SELECT
        loan_month,
        total_loans_issued,
        charged_off_count,
        ROUND(100 * charged_off_count / total_loans_issued, 2) AS charge_off_rate_pct,
        ROUND(
            AVG(charged_off_count) OVER (
                ORDER BY loan_month
                ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
            ),
            2
        ) AS rolling_3mo_avg_chargeoffs,
        LAG(charged_off_count, 1) OVER (ORDER BY loan_month) AS prev_month_chargeoffs
    FROM monthly_base
)
SELECT
    loan_month,
    total_loans_issued,
    charged_off_count,
    charge_off_rate_pct,
    rolling_3mo_avg_chargeoffs,
    prev_month_chargeoffs,
    ROUND(
        100 * (charged_off_count - prev_month_chargeoffs) / NULLIF(prev_month_chargeoffs, 0),
        2
    ) AS mom_change_pct
FROM monthly_with_windows
ORDER BY loan_month ASC;


/* =================================================================================================
   Final Notes

   1. This script is written for accepted.csv only.
   2. The expected table name is accepted.
   3. If your database name is different, only change the USE statement at the top.
   4. The main project stories are:
      - loan grade risk benchmark,
      - vintage performance,
      - borrower risk pricing,
      - state concentration risk,
      - NPA recovery,
      - monthly charge-off trend.
================================================================================================= */
