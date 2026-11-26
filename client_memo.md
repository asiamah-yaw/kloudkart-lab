# Memo: your orders, stock and Monday report

**To:** Nana Adjei, Operations  **From:** Yaw Asiamah  **Date:** 26 November 2026\
*Figures cover orders to 31 August 2026, the end of the data. No currency is stated.*\
**In short:** overselling is blocked for every sale through the new ordering step. The Monday report opens in 0.15 seconds once its rebuild is scheduled.

## What I found

- **Order status is written 15 ways for 5 real statuses.** A report looking only for "completed" misses 273 million of 381 million in sales (completed plus shipped): 72%. I didn't see whether Adwoa's report does this; mine read every spelling.
- **157 products' stock figures don't match their record of stock in and out**: gaps worth up to 3.87 million at selling price, 88% of it in 20 products, and 14 below zero.
- **2,426 order totals don't match their items.** The totals come to 3.48 million less than their items, mostly by exactly 10% or 25%. I used the totals, *assuming* they are what customers paid.
- **Smaller:** 155 sales orders (0.1% of sales value) have no matching customer; up to 535 accounts may be duplicates, which could change the top 100.

## What I built (measured results in the measurement report)

| You asked for | Status |
|----|---------------|
| No overselling | Done in the database: in every test exactly one buyer got the last unit; 400 buyers for 50 units bought exactly 50. Live once the website uses it. Not instant in a rush: with 400 at once, the last waited up to 6.3 seconds. |
| Fast Monday report | Opens in 0.15 seconds (I didn't have your 40-minute report; my slow version took about 3.5 hours). **Trade-off:** it reads a stored summary, so newer orders show only after the next rebuild (about 7 seconds). The rebuild still needs scheduling. |
| Low stock by category | Done: any number of levels, under 0.01 seconds. "Low" means 5 units or fewer. |
| Stock movement trail | Done: every change recorded automatically; old entries can't be edited. |

**Earlier suggestions:** a "trigger" (automatic check) can't make two orders arriving together take turns; I used one for the trail. A bigger server wouldn't fix how the report asked questions.

## What I recommend

1. **Count the 20 products** on the new "count first" list; record each as a correction.
2. **Your developers:** schedule the report rebuild for early Monday.
3. **Your developers:** route all sales and stock changes through the new ordering step; remove the website's right to delete the trail.
4. **Finance:** confirm shipped orders are sales, and whether totals or items are right.
5. **Review shared emails** before merging accounts. New bad records are refused.

## What I could not stand behind

- That the **website uses the new ordering step everywhere**. The rush test ran **on a laptop**, single-product orders only.
- **Which stock figure is right** (only a count can tell), or that nobody with full access deletes trail entries.