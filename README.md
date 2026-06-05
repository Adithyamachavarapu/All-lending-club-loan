# All-lending-club-loan
Built an end-to-end SQL analytics project on Lending Club loan data using Views, CTEs, and Window Functions. Analyzed credit risk, charge-off trends, borrower risk tiers, loan vintages, geographic concentration, and NPA metrics to generate actionable lending insights.

A structured SQL project on LendingClub's accepted loan dataset, covering credit risk analysis, borrower segmentation, NPA reporting, and charge-off trend monitoring. Built to demonstrate real-world analytical thinking in a banking and lending context.

---

## Dataset

- **Source:** LendingClub Accepted Loans (`accepted.csv`)
- **Table:** `accepted` (loaded via MySQL Workbench Import Wizard)
- **Database:** `lending_club_data`
- **SQL Dialect:** MySQL 8.0+

---

## Setup

Raw data from the Import Wizard loads `int_rate`, `dti`, and `issue_d` as plain text. To fix this once and keep all queries clean, a base view was created:

```sql
CREATE OR REPLACE VIEW vw_accepted_clean AS
SELECT
    id, loan_amnt, funded_amnt, grade, loan_status,
    CAST(REPLACE(int_rate, '%', '') AS DECIMAL(8,4))  AS int_rate_clean,
    CAST(SUBSTRING(issue_d, -4) AS UNSIGNED)          AS vintage_year,
    STR_TO_DATE(CONCAT('01-', issue_d), '%d-%b-%Y')   AS issue_month,
    ...
FROM accepted WHERE id IS NOT NULL;
```

All six project queries run off this view. No type-casting is repeated anywhere else.

---

## Project Queries & Business Insights

### Q1 — Loan Grade Default Rate vs. Portfolio Benchmark
**Dept:** Risk Analytics

Groups loans by grade (A–G), calculates each grade's charge-off rate, and compares it against the portfolio average using a window function — no subquery needed.

**Approach:** CTE for per-grade aggregation → `AVG() OVER()` in outer query for the portfolio benchmark → `CASE WHEN` to flag grades above or below.

> **Finding:** A clear risk ladder exists from A to G. Grade A charged off at 3.28%, Grade G at 37.48%. Grades D through G are all above the portfolio benchmark of ~11.88%.

---

### Q2 — Loan Vintage Cohort Charge-Off Analysis
**Dept:** Portfolio Risk

Tracks loan performance by origination year ("vintage") to see which years produced the weakest loans. Uses `RANK()` to sort vintages from worst to best.

**Approach:** Two CTEs — first aggregates by `vintage_year` (extracted from `issue_d` string), second applies `RANK() OVER(ORDER BY charge_off_rate DESC)`.

> **Finding:** The 2015 vintage had the worst charge-off rate at ~18.00%, followed by 2014 at ~17.47%. Newer vintages appear healthier but may simply be unseasoned — they haven't had enough time to default yet.

---

### Q3 — Borrower Risk Tiering: DTI × FICO Segmentation
**Dept:** Credit Policy / Underwriting

Segments borrowers into Low, Medium, and High Risk tiers using both FICO score and DTI together. Then checks whether LendingClub's interest rates are pricing that risk adequately.

**Approach:** CTE classifies every borrower with a multi-condition `CASE WHEN`. Outer query aggregates by tier. A scalar subquery pulls the portfolio-wide charge-off rate for benchmarking. `HAVING` removes tiers with fewer than 500 borrowers.

> **Finding:** High Risk borrowers (FICO < 660 or DTI > 30) charged off at 15.23%, but their average interest rate was only 15.10% — barely above the default rate. Low Risk borrowers (FICO ≥ 720 and DTI ≤ 15) charged off at just 5.38% with a 9.30% average rate, suggesting the pricing spread between tiers is not wide enough.

---

### Q4 — State-Level Geographic Risk Concentration
**Dept:** Business Intelligence

Identifies which of the top 10 states by loan exposure also carry above-average default risk — a dual concentration flag.

**Approach:** Two CTEs — first aggregates by state, second applies `SUM() OVER()` for portfolio share and national charge-off rate (both as window functions). `RANK() OVER(ORDER BY funded_amnt DESC)` filters to top 10. Risk flag applied with `CASE WHEN` on the gap between state and national rate.

> **Finding:** California holds ~14.13% of total funded amount. The national charge-off rate is ~11.88%. Among the top 10 states, CA, NY, FL, NJ, PA, OH, and VA all sit above the national rate — but none by more than 5 percentage points, so all are flagged "At Risk" rather than "High Risk."

---

### Q5 — NPA Classification & Collections Recovery Rate
**Dept:** Collections & Recovery

Classifies non-performing loans into the standard NPA buckets (Substandard, Doubtful, Loss) and calculates how much of each bucket's principal has been recovered.

**Approach:** CTE filters NPL loans and assigns NPA bucket via `CASE WHEN` on `loan_status`. Outer query aggregates outstanding principal (`loan_amnt − total_pymnt`), total recoveries, and recovery rate. `NULLIF` prevents division by zero. Custom `ORDER BY CASE WHEN` enforces Loss → Doubtful → Substandard severity order.

> **Finding:** Loss loans (Charged Off + Default) dominate the NPA pool with ~$1.99B in outstanding principal and a recovery rate of only ~7.77%. Doubtful and Substandard buckets show near-zero recoveries in this snapshot, making them the priority for early-stage collections intervention.

---

### Q6 — Monthly Charge-Off Trend with Rolling Average & MoM Change
**Dept:** Executive Risk Committee

Builds a time-series report of monthly charge-off volumes, smoothed with a 3-month rolling average, and tracks month-over-month acceleration in defaults.

**Approach:** Two CTEs — first parses `issue_d` into `YYYY-MM` format and aggregates monthly charge-offs. Second applies three window functions: `AVG() OVER(ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)` for the rolling average, `LAG()` for the prior month's value, and derived MoM % change with `NULLIF` safety.

> **Finding:** March 2016 recorded the highest single-month charge-off count: 10,595 charge-offs from 61,992 loans issued that month (~17.1% rate). The rolling average smooths the noise and makes structural trends in credit quality clearly visible over time.

---

## SQL Concepts Covered

| Concept | Used In |
|---|---|
| CTEs (single and chained) | Q2, Q3, Q4, Q5, Q6 |
| Window functions — `AVG/SUM OVER()` | Q1, Q4 |
| Window functions — `RANK()`, `LAG()` | Q2, Q4, Q6 |
| Rolling window — `ROWS BETWEEN` | Q6 |
| `CASE WHEN` (classification + custom sort) | Q1, Q3, Q4, Q5 |
| Conditional aggregation — `SUM(CASE WHEN...)` | Q2, Q3, Q5, Q6 |
| Scalar subquery in `SELECT` | Q3 |
| `HAVING` clause filtering | Q3 |
| String-to-date parsing — `STR_TO_DATE` | View, Q6 |
| `NULLIF` for division safety | Q5, Q6 |
| Percentage of total via window function | Q4 |

---

