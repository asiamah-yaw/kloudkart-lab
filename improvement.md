# Improvement beyond the brief: stock health and days of cover

**Built in:** `sql/09_stock_health.sql` (runs as part of `sql/run_all.sql`)
**Use it:** `SELECT * FROM stock_count_first;` then `SELECT * FROM stock_health_alerts;`

## The problem

Nana asked for low stock "at a glance", and the rollup (`sql/06_category_rollup.sql`) gives him that with one rule: 5 units or fewer is low. But the same rule treats a slow seller and a best-seller alike. Five units of something that sells once a month is fine. Five units of something that sells ten a day runs out before lunch. So 1,685 products show as "low", and the list doesn't say which ones run out first.

A second problem sits underneath: a "days left" figure is only as good as the stock figure it starts from. Nana said himself that his stock counts no longer match reality closely enough to trust. The diagnosis found why (data_findings F-02): 144 products whose stock figure disagrees with their own movement history, and 14 below zero.

## What I built

**The new part: days of cover.** For every product, the view works out how many units sold in the last 28 days, the average sold per day, and how many days the current stock will last at that rate. Anything still selling with fewer than 7 days left is flagged. This ranks products by how soon they actually run out, which a fixed threshold can't do.

**The foundation that makes it trustworthy: a stock check.** For every product, the view also compares the stock figure with what the movement history adds up to. Where they disagree, the days-of-cover figure can't be trusted, so those products are listed first.

The views:

| View | What it gives |
|---|---|
| `stock_count_first` | The 20 products to count by hand first |
| `stock_health_alerts` | Every product that needs attention, most serious first, then by money at stake, then by fewest days left |
| `stock_health` | One row per product, with every measure plus a yes/no column for each problem, because a product can have more than one |
| `stock_health_summary` | One line per problem type, for the Monday meeting |

**Settings** are kept in `stock_settings`, next to the low-stock threshold of 5: `sales_window_days` = 28 and `min_days_of_cover` = 7. Changing either is one `UPDATE`, with no SQL to edit.

**"Recent" counts back from `report_settings.as_of`** (31 Aug 2026 for this extract), not from today's date. On a static extract, today's date would find no recent sales at all, and the answer would change depending on the day it was run. In normal use `as_of` moves forward, and this moves with it.

## What it found on this extract (4,023 products)

| Problem (most serious shown) | Products | What it means |
|---|---|---|
| 1. Stock figure below zero | 14 | More was sold than existed |
| 2. Stock figure does not match its history | 143 | The figure can't be trusted; together these gaps are worth 3,863,746.54 at selling price |
| 3. Out of stock and still selling | 565 | Sold in the last 28 days, nothing left |
| 4. Under 7 days of cover | 928 | Will run out within a week at the recent rate |
| Fine | 2,373 | |

**How the 157 untrustworthy figures add up.** 144 products disagree with their history, and 14 are below zero. One product is in both groups (product 6295: the figure says −1, the history says 3). So 144 + 14 − 1 = **157 different products**. The **3,865,699.34** unexplained covers all 157. It's the gap in units times the selling price, with each gap counted by its size, so a surplus and a shortfall don't cancel each other out.

**Where to start.** The 20 products in `stock_count_first` hold **88.3%** of that 3.87 million. A physical count of 20 products settles most of the money, even though the full alert list is long.

**The below-zero products.** For 13 of the 14, the movement history also goes below zero: the log itself records more units leaving than arriving. That's **consistent with the overselling** Nana described. It's not proof on its own, because missing restock records would look the same. For the 14th (product 6295), the history says 3 units exist, so that one is a wrong figure, not a recorded oversell.

The yes/no columns also show overlap that a single label hides. For example, 44 of the products whose figure can't be trusted are also out of stock or low on cover.

## What it is worth to Nana

- **A short list instead of a long one.** He starts with 20 counts that settle 88% of the unexplained value, instead of 1,650 alerts.
- **Reorder by urgency, not by a fixed number.** The 565 products still selling with nothing left are lost sales today. The 928 under a week are the next order to place.
- **Knowing which figures to trust** before acting on any stock number, including the low-stock rollup.
- **For Adwoa:** nothing changes in the Monday report. This is Nana's operational list.

## What it cost

- **No extra work on any sale.** These are views: they calculate only when someone opens them. The flash-sale path doesn't touch them.
- **Speed:** 137 ms and 139 ms on two runs for the full alert list on the test laptop, at today's log size of about 282,000 movements. The log grows by thousands of rows a day, so this will rise slowly. The index on `inventory_log(product_id, created_at)` (`sql/07_indexes_and_stats.sql`) keeps the recent-sales lookup fast.

## Limits (what this does not do)

- **The value is at selling price, not cost.** The data has no cost price, so 3.87 million is the most the gaps could be worth, not a loss figure.
- **The currency isn't stated in the data.** Amounts are in whatever currency the shop records.
- **It doesn't say which figure is right,** the stock figure or the history. Only a physical count can. It doesn't change any stock automatically.
- **28 days is a simple average.** It doesn't know about seasons, promotions or a flash sale coming up. A product that hasn't sold in 28 days has no days-of-cover figure (it shows as empty), even if it sells well at other times.
- **The stock history protection has limits.** Edits (UPDATE) and emptying the table (TRUNCATE) are blocked (`sql/08_protect_audit_log.sql`). Deleting rows is still possible for the table owner, because the supplied test deletes its own test rows when it cleans up. In production, the shop application's login should be allowed only to add and read log rows, not to delete them. That permission is part of setting it up.
- **The built-in check** proves every product is assessed exactly once and that each label agrees with its yes/no columns. That the labels match real situations is tested separately (see `verification.md`).