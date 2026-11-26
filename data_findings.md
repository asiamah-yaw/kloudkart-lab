# Data findings — Kloud Kart

## Summary

I checked the Kloud Kart extract against every rule the current schema does not enforce (no foreign keys, no unique email, no value checks, free-text status). Of 31 checks, **18 found problems** and 13 came back clean. The problems are ranked below by what they do to the numbers Nana and Adwoa actually use, not by how many rows they touch.

The most dangerous fault is the cheapest to fix: **order status is stored in 15 different spellings**. Any report that filters on one spelling silently drops **72% of customer spend** (89,260 completed orders worth 273.1 million). The second is that **stock figures cannot be trusted**: 14 products are below zero (27 units sold that did not exist, the overselling Nana described) and 144 products hold a stock figure their own movement history does not explain (2,553 units, 3.87 million at current prices).

I fixed nothing by rewriting history. Where data is wrong I either work around it in the new reports (and say so), or add a rule that stops new bad rows while leaving the old ones visible for review. Everything here is reproduced on a fresh load by `sql/01_integrity_checks.sql` (counts) and `sql/01b_cost_of_findings.sql` (business cost).

**Assumptions used throughout** (the brief leaves these open, and Nana could not be asked):
- **Extract end = 31 Aug 2026.** Orders run at about 1,000 a day until then, then only 24 scattered orders appear over the following year.
- **"Money spent" = orders whose status means completed or shipped.** Pending orders are not yet fulfilled; cancelled and refunded orders returned the money.
- **`orders.total_amount` is the trusted order value**, for the reasons in F-03.

## Reconciliation

| Stage | Rows | Delta | Reason |
|---|---|---|---|
| categories.csv lines → loaded | 95 → 94 | −1 | Header line |
| products.csv lines → loaded | 4,024 → 4,023 | −1 | Header line |
| customers.csv lines → loaded | 40,421 → 40,420 | −1 | Header line |
| orders.csv lines → loaded | 159,385 → 159,384 | −1 | Header line |
| order_items.csv lines → loaded | 336,560 → 336,559 | −1 | Header line |
| inventory_log.csv lines → loaded | 282,353 → 282,352 | −1 | Header line |
| Orders loaded → within the extract period | 159,384 → 159,360 | −24 | Dated after 31 Aug 2026 (F-06) |
| Within period → counted as spend | 159,360 → 124,180 | −35,180 | Pending, cancelled or refunded (assumption above) |
| Spend orders → linked to a known customer | 124,180 → 124,025 | −155 | Customer does not exist (F-04); shown as "unknown customer", not dropped |
| Customer rows → distinct people (by email) | 40,420 → 39,885 | −535 | Shared email addresses (F-05) |

Nothing was deleted at any stage. Every reduction is a filter in a report, with its reason.

## Findings, ranked by risk

Severity scale: **High** = changes a number Nana decides on, by a lot, today. **Medium** = changes a reported number, or can stop a report working. **Low** = affects detail or history, not the headline figures.

### F-01: Order status stored in 15 spellings — Severity: High

- **What it is:** `orders.status` is free text with no CHECK constraint or lookup table. Five meanings (completed, pending, shipped, cancelled, refunded) are stored as 15 spellings: capitals (`COMPLETED`, `Completed`), spaces (` completed`) and variants (`complete`, `canceled`).
- **How I detected it:** checks D7/D8 (`count(DISTINCT status)` = 15; after `lower(trim())` = 7), then grouping the remaining variants by meaning.
- **Scale:** 159,384 orders. Only 22,091 of the 111,351 completed orders use the exact spelling `completed`.
- **Effect on the client's number:** a report filtering `status = 'completed'` silently misses **89,260 orders worth 273.1 million, 72% of all customer spend**. Every customer's "total spent", the top-100 ranking and the monthly figures would be wrong, with no error message.
- **What I did about it:** added a mapping table (`order_status_map`) that says what each spelling means, and built every report on the meaning, not the spelling. I did **not** rewrite the 159,384 stored values: the application may still write these spellings, and a hard rule would make checkout fail.
- **Residual risk:** a new spelling the map does not know about. A view (`unmapped_order_statuses`) lists any unmapped spelling, so it is caught on the next run instead of silently excluded.

### F-02: Stock figures cannot be trusted — Severity: High

- **What it is:** `products.stock_quantity` has no rule stopping it going below zero, and nothing ties it to `inventory_log`. The stock figure and the movement history are written separately, so they can drift apart.
- **How I detected it:** C1 (`stock_quantity < 0`) and D2 (stock figure compared with the sum of `change_qty` per product).
- **Scale:** 14 products below zero; 144 products whose figure differs from their history (122 show less than the history says, 22 show more).
- **Effect on the client's number:** the negative stock is **27 units sold that did not exist (20,628 at current prices)**, the overselling Nana described, each one a refund and an apology. The drift is **2,553 units (3.87 million at current prices) that the records cannot explain**, about 1% of stock on hand. Low-stock alerts and the flash-sale stock limit are only as good as this figure.
- **What I did about it:** new orders can no longer push stock below zero: `place_order` refuses, and a `CHECK (stock_quantity >= 0)` rule is added as a safety net, checking new changes only, so the 14 existing rows stay visible. Every stock change now writes its own movement row. A reconciliation view lists products where the two figures disagree.
- **Residual risk:** I cannot tell which figure is right for the 144 products. That needs a physical stock count. Until then, low-stock alerts for those products may be wrong.

### F-03: Order total disagrees with its own lines — Severity: Medium

- **What it is:** each order's value is stored twice: `orders.total_amount` (written at checkout) and the sum of `quantity × unit_price` across its lines. Nothing forces them to agree.
- **How I detected it:** D1, then testing each possible cause (Cost 6 and 6b).
- **Scale:** 2,426 orders with a combined gap of 5.21 million. **537** contain the same product on two lines; counting each product once makes most of them match the total. **295** have a line with a missing or zero price; filling in the product's price makes most of them match. The other **1,594** are exactly 0.75, 0.90, 1.10 or 1.25 times their lines.
- **Effect on the client's number:** "total spent" depends on which figure a report reads. Reading the lines would add 936 duplicated units (F-09) and lose the value of 300 lines with no price.
- **What I did about it:** every report reads `total_amount`. The evidence favours it: where the cause can be identified, the lines are broken and the total is right.
- **Residual risk:** the 1,594 exact-percentage orders could be discounts or fees the lines do not record, or an error in the checkout total. I could not tell which (see "Could not verify").

### F-04: Orders for customers that do not exist — Severity: Medium

- **What it is:** no foreign key from `orders.customer_id` to `customers`.
- **How I detected it:** A5, an anti-join (`LEFT JOIN customers ... WHERE customer IS NULL`).
- **Scale:** 210 orders pointing at 190 customer IDs that do not exist; 155 of them are spend orders.
- **Effect on the client's number:** a normal join silently drops them, so **427,669 of spend disappears** from the Monday report with no error (0.11% of spend). Small in total, but it is exactly the quiet kind of failure: nobody would know the figure was short.
- **What I did about it:** the Monday report keeps these orders under "unknown customer", so totals still add up. A foreign key now stops new orders for non-existent customers, added as "check new rows only" so the 210 old ones remain for review.
- **Residual risk:** the 190 missing customers cannot be recovered from this extract.

### F-05: One email address on several customer rows — Severity: Medium

- **What it is:** `customers.email` was never unique.
- **How I detected it:** B1/B2/B3, grouping on `lower(trim(email))`.
- **Scale:** 533 email addresses are shared by 1,068 customer rows; 234 of these only match once capitals and spaces are ignored.
- **Effect on the client's number:** the customer count is **overstated by 535** (40,420 rows, 39,885 distinct emails). A person split across two rows has their spend split too: in the current top-100, **1 real customer is missing** because their spend is divided between two accounts.
- **What I did about it:** nothing automatic. I did not merge rows, because two real people can share an email (a family or a shop). The report ranks by customer account, as the data defines it.
- **Residual risk:** the ranking may undercount people with split accounts. A merge needs a human review of the 533 groups first; after that, a unique rule on the normalised email can be added.

### F-06: Orders and movements dated after the extract end — Severity: Medium

- **What it is:** dates are not checked.
- **How I detected it:** D3/D6, plus orders per month (about 1,000 a day until 31 Aug 2026, then 24 scattered over the next year).
- **Scale:** 24 orders (68,040) dated 6 Sep 2026 to 20 Aug 2027, and 40 stock movements.
- **Effect on the client's number:** "monthly spend for the trailing 12 months" depends on where the 12 months end. A report ending at "the latest order" would end in August 2027 and show almost a year of empty months.
- **What I did about it:** the report's 12-month window ends at a stated date (31 Aug 2026 for this extract; today's date in normal use), and orders after it are left out.
- **Residual risk:** if some of these are genuine orders with a wrong clock, their value is missing from the window.

### F-07: Category tree has a loop and a missing parent — Severity: Medium

- **What it is:** `categories.parent_id` points at its own table with no foreign key.
- **How I detected it:** A3 (anti-join) and A4 (walking up the tree with PostgreSQL's `CYCLE` clause).
- **Scale:** 2 categories point at each other and 1 points at a parent that does not exist, so 3 categories and the 6 products in them are cut off from every top-level category. Separately, 37 products have no category at all.
- **Effect on the client's number:** small in rows, but a loop makes an unguarded rollup **run forever**, so the low-stock view Nana asked for would never return. The 43 cut-off or uncategorised products would also be missing from every category total.
- **What I did about it:** the rollup has a loop guard and shows cut-off and uncategorised products in their own "not in the tree" group, so nothing silently disappears. A foreign key now stops new parents pointing at nothing.
- **Residual risk:** I do not know where the 3 cut-off categories belong. Marketing needs to say.

### F-08: Order lines and stock movements pointing at nothing — Severity: Low

- **What it is:** no foreign keys from `order_items` or `inventory_log`.
- **How I detected it:** A7 and A9 (anti-joins).
- **Scale:** 692 order lines (968 units, 826,328) belong to 689 orders that do not exist; 120 stock movements belong to 111 products that do not exist.
- **Effect on the client's number:** none on the Monday report, which starts from orders. They do distort any "units sold per product" figure built from lines, and the audit trail contains movements nobody can trace.
- **What I did about it:** foreign keys stop new ones; the existing rows are left in place and reported.
- **Residual risk:** history built from order lines alone is unreliable for these rows.

### F-09: Same product twice on one order — Severity: Low

- **What it is:** no rule stops a product appearing on two lines of the same order.
- **How I detected it:** B5.
- **Scale:** 616 cases, 936 extra units if counted from lines.
- **Effect on the client's number:** inflates units sold per product if read from lines. Order totals ignore the duplicate (F-03), so spend is not affected.
- **What I did about it:** reports use order totals, not lines. New orders from `place_order` write one line per product.
- **Residual risk:** product sales analysis from lines must remove duplicates first.

### F-10: City and name written in many ways — Severity: Low

- **What it is:** `customers.city` and `customers.full_name` are free text with no rule.
- **How I detected it:** seen in the top-100 output: `accra`, `Accra`, `ACCRA`; names in capitals, lower case, or with leading spaces.
- **Scale:** affects grouping and display, not counts.
- **Effect on the client's number:** none on spend or stock. Any "spend per city" figure would split Accra into several cities.
- **What I did about it:** nothing; no report Nana asked for groups by city.
- **Residual risk:** a future city report must normalise (`initcap(trim(city))`) first.

## Looked wrong, is not wrong

| Apparent problem | Why it looks wrong | Why it is actually fine |
|---|---|---|
| Negative `change_qty` in inventory_log (262,646 rows) | Quantities are usually positive | It is how stock going out is recorded: every `sale` and `damage` row is negative, every `restock` and `return` row positive. The schema comment says so |
| 90 movements with `change_qty = 0` | A movement of nothing | All are `stock_take`: staff counted the shelf and it matched the records, so nothing changed. A mismatch is logged as `correction` instead |
| `correction` rows in both directions | Mixed signs | A correction can find more or less stock than recorded |
| 4,116 order lines priced differently from the product's current price | Looks like a pricing error | Prices change over time; the line keeps the price paid on the day |
| Customers who never ordered | Data for inactive people | Registered and not yet bought; normal for a shop |
| All customers registered and products created before the first order | Suspicious timing | The extract covers orders from Aug 2025 onwards; customers and products are older. No order is dated before its customer registered (check D5 = 0) |

## Could not verify

- **The 1,594 orders worth exactly 0.75, 0.90, 1.10 or 1.25 times their lines.** They could be discounts and fees the lines do not record, or checkout errors. Settling it needs the checkout system's discount and fee rules.
- **Which stock figure is right for the 144 drifted products.** Needs a physical stock count.
- **Whether shared emails belong to the same person.** Needs a human review of the 533 groups.
- **Where the 3 cut-off categories belong.** Needs marketing.
- **The extract end date.** Inferred from the data (activity stops on 31 Aug 2026), not stated by anyone.
- **Whether the 24 future-dated orders are real orders with a wrong clock, or test data.**