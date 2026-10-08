# Credit risk analysis on Lending Club loans (PostgreSQL + Python)

I built this to learn SQL properly and to practise the kind of work a bank's risk analytics team does. I took a raw Lending Club loan file, loaded it into PostgreSQL, designed a schema for it, analysed default rates in SQL, and then built a logistic regression model that estimates each loan's probability of default (PD) in Python.

I started this with no SQL background, so the repo also includes the mistakes I hit along the way (see "What went wrong").

## What's in the repo

```
sql/
  01_create_tables.sql      schema: staging table, customers, loans
  02_load_data.sql          CSV import and the transform into clean tables
  03_analysis_queries.sql   validation checks and default-rate analysis
python/
  pd_model.ipynb            PD model, evaluation, threshold and cost analysis
```

The raw CSV isn't included (about 1.1 GB, and not my data).

## The data

Lending Club loan data from Kaggle: [adarshsng/lending-club-loan-data-csv](https://www.kaggle.com/datasets/adarshsng/lending-club-loan-data-csv). It has 2,260,668 loans and 145 columns.

One thing to know about this version: the `id` and `member_id` columns are empty for every row. The usual redistribution anonymisation seems to have stripped them. That means there's no way to tell whether two loans belong to the same person, so I couldn't build a real customer-to-loans relationship.

## Database design

- **`staging_loans`**: every raw column as `TEXT`, no constraints. This catches the CSV without a single odd value stopping the import.
- **`customers`** and **`loans`**: the cleaned tables, linked by a foreign key.

I put fields that are measured again at each application (income, debt-to-income, delinquencies, employment length) in `loans`, since a second application could show different values. Only `home_ownership`, `zip_code` and `addr_state` stayed in `customers`.

Because `id` and `member_id` were unusable, both tables use generated (`SERIAL`) keys. To make sure each customer row lines up with its loan row, I added a row-number column to the staging table and used that same number as `customer_id` in both inserts. Two independently generated sequences wouldn't guarantee a match.

In practice this means `customers` has one row per loan, so the data can't tell me anything about repeat borrowers.

## Loading the data

The first import failed with `unterminated CSV quoted field`. I assumed the file was malformed and spent a while cleaning it with pandas. The real cause was pgAdmin's import settings: the escape character was an apostrophe instead of a double quote, which broke on values like `"Waiter, Maitre D'"`. Setting it to `"` fixed it, and the pandas step wasn't needed.

I also found `dti = -1` in two rows (an impossible value being used as "missing") and set those to `NULL`.

## Defining a default

- **Default (1):** `Charged Off`, `Default`, and the "Does not meet the credit policy" version of `Charged Off`.
- **Not default (0):** `Fully Paid`, and the matching "Does not meet the credit policy" version.
- **Excluded:** `Current`, `In Grace Period`, `Late (16-30 days)` and `Late (31-120 days)`. These loans haven't reached an outcome, so labelling them either way would be a guess.

## What the SQL showed

Default rate among resolved loans:

- **By grade:** rises steadily from 6.1% (A) to 49.8% (G).
- **By home ownership:** rent 23.4%, own 20.8%, mortgage 17.3%.
- **By purpose:** small business is highest at 29.9%, wedding lowest at 12.4%.
- **By year:** 26.2% in 2007, about 14% in 2009, then rising from 15.6% in 2013 to 24.3% in 2016. The 2017 and 2018 figures aren't reliable, because only about 36% and 10% of those loans have resolved. Resolved loans from recent years are the ones that settled quickly, which biases the default rate down.

**Income verification** was the finding I found most interesting. Verified loans defaulted more than unverified ones (23.9% against 14.8%). I checked two possible explanations:

- *Loan age.* Restricting to loans issued before 2016 shrank the gap only slightly (21.3% against 13.5%).
- *Grade.* Comparing within each grade, the gap was much smaller at low grades. By my rough calculation, grade accounts for about 60% of the raw difference. Lending Club seems to have verified riskier-grade loans more often.

Verified loans were still somewhat riskier within every grade, and I can't say why from this data.

## The default model

**Training data:** resolved loans issued before 2016 (about 825,500). I stopped at 2015 because later loans are mostly unresolved.

**Split:** by time. The model trains on 2007-2014 loans (452,133) and is tested on 2015 loans (373,408). A bank uses a model on future loans, so a random split would let it see the future.

**Features:** loan amount, term, interest rate, grade, purpose, debt-to-income, delinquencies, income, employment length (plus a flag for when it's missing, since those loans defaulted at 23.7% against 18.2%), home ownership and verification status. I left out anything only known after a loan starts, like payments received, which would leak the answer. Numeric columns are standardised, using statistics from the training set only.

**Results** (ROC-AUC on the 2015 test loans):

| Model | ROC-AUC |
|---|---|
| With `grade` and `int_rate` | 0.726 |
| Without them | 0.686 |

I treat the version without them as the main model. `grade` is Lending Club's own risk score, and `int_rate` is largely set from it, so leaving them out shows what borrower and loan details predict independently. It keeps about 83% of the full model's improvement over a coin flip (0.5).

The coefficients matched what the SQL found: small business and educational loans carried the most risk, weddings the least, and income reduced it. Adding grade to a verification-only model cut the verification coefficient by about two thirds, and with all features it was close to zero.

**Calibration:** the model that includes grade predicted an average default rate of 16.6% on the 2015 loans, while the actual rate was 20.2%. The training period's rate was 17.1%. The model ranks loans reasonably well, but its probabilities run low, so they shouldn't be read as literal default rates.

## Choosing a cut-off

At a cut-off of 0.5 the model flags almost nothing (recall 1.2%, precision 62.6%). At 0.2, recall is 55.6% with precision 36.9%.

To pick a cut-off I estimated the cost of each mistake from the loans' own outcomes, using pre-2016 loans:

- **Approving a loan that defaults:** about $5,985 on average (unpaid principal less recoveries and the interest earned before default).
- **Rejecting a loan that would have been repaid:** at most about $2,691, the average interest on a fully repaid loan. That's before funding and servicing costs, which this data doesn't have.

Since the second figure is an upper bound, I tried it at 100%, 50% and 25% of the gross interest. The cost-minimising cut-off was 0.25, 0.15 and 0.10, which would reject 19%, 47% and 69% of applicants. The right cut-off therefore depends on an assumption the data can't settle. I ran the cut-off and cost analysis on the model that includes grade, and haven't repeated it on the other one.

## Limitations

- This is Lending Club data, not a bank's, and the cost figures are rough.
- Funding and servicing costs aren't included, and every loan is treated as average-sized.
- The model's probabilities run low, as described above.
- Loans from 2016 onwards were excluded because their outcomes are mostly unknown.
- Only origination-time features I chose were used. The raw file has more (for example `revol_util`, `inq_last_6mths`) that I didn't try.

## Running it

1. Download the CSV from Kaggle and put it somewhere outside the repo.
2. Create a database called `credit_risk_db` in PostgreSQL and run `sql/01_create_tables.sql`.
3. Import the CSV into `staging_loans` (pgAdmin's Import tool, or the `\copy` command in `02_load_data.sql`). Set both the quote and escape characters to `"`.
4. Run the rest of `sql/02_load_data.sql`.
5. Open `python/pd_model.ipynb`. It asks for your Postgres password when it runs and doesn't save it.

Python libraries: pandas, SQLAlchemy, psycopg2-binary, scikit-learn.

## What I'd do next

- Add more origination-time features and see how much of the gap to the grade model closes.
- Recalibrate the probabilities.
- Estimate loss given default and exposure per loan, to move from "will it default" to expected loss.
- Build a Tableau dashboard from the SQL results.
