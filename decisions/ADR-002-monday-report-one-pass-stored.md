# ADR-002: Rewrite the Monday report as one pass and store the result

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Yaw Asiamah

## Context

Adwoa's Monday customer-spending report takes about 40 minutes and sometimes does not finish, so Nana decides without it. Someone has priced a bigger server. The report needs, per customer: total spent, order count, monthly spend for the trailing 12 months, a running total, and a top-100 ranking, "in seconds on an ordinary laptop".

Adwoa's real query was not supplied. A representative stand-in written the common way (one small query per figure, per customer: about 600,000 queries) took 15.5 s for 50 customers, about **3.5 hours** for all 40,420.

## Decision

I rewrote the report to read the orders **once**, grouping them by customer and month, with the running total and ranking calculated by window functions in the same statement, and stored the result as a materialized view (`monday_report`) refreshed without blocking readers (`refresh_monday_report()`). "Money spent" is defined once, in `spend_orders`, and every report reads it. Four indexes and a statistics refresh were added only where measurement showed a gain (`sql/07_indexes_and_stats.sql`).

## Alternatives considered

### Alternative A: A bigger server (the suggestion Nana heard)

- **How it would work:** same query, faster machine.
- **Why it is attractive:** no code changes, no risk to the figures.
- **Why rejected:** a monthly bill the brief rules out, and it attacks the wrong cause. The time comes from running hundreds of thousands of small queries; even the same query **with** indexes still needs about 1.3 hours. A faster machine might halve that, never reach seconds.

### Alternative B: Keep the old query and only add indexes

- **How it would work:** index `orders(customer_id, order_date)` so each small query finds its rows faster.
- **Why it is attractive:** smallest change; the report's logic is untouched.
- **Why rejected:** measured: 3.5 hours became about 1.3 hours. Better, still not "seconds". The indexes were kept anyway because they help other lookups.

### Alternative C: The same one-pass query as a plain view (not stored)

- **How it would work:** `CREATE VIEW` instead of `CREATE MATERIALIZED VIEW`; calculated every time it is opened.
- **Why it is attractive:** always up to the minute, with no refresh job and no stale figures. It also meets the target: building the report takes about 2.9 seconds.
- **Why rejected:** every person who opens it waits about 3 seconds and repeats the same work; the stored version reads in 0.15 s. The work grows with about 4,000 orders a day. A weekly report can tolerate figures a few hours old. This was a close call: if same-day figures matter more than speed, switch to this; it is a one-word change.

### Alternative D: A summary table updated on every order

- **How it would work:** a table of spend per customer per month, increased by a trigger each time an order completes.
- **Why it is attractive:** always current and instant to read.
- **Why rejected:** adds work to every order, including the flash sale, and the summary can drift out of step with the orders (a missed status change, a manual fix) with nothing to show it. The stored report is rebuilt from the orders each time, so it cannot drift.

## Consequences

- **What this buys:** measured on the test laptop: reading the top 100 takes **0.15 s** instead of an estimated 3.5 hours; one customer's 12 months 0.7 ms; rebuilding 2.9 s on a fresh load and 7.1 s as a non-blocking refresh. A built-in check stops the load if the report does not add up exactly to all spend (380,517,831.49), every customer, 12 months each.
- **What this costs:** the figures are only as fresh as the last refresh. The refresh must be scheduled (for example, Monday 06:00). 4 indexes use about 22 MB and add a small amount of work to each new order (not measurable at 2,000 orders; the flash sale's median moved from 4.4 s to 5.6 s (4 runs after, from 5.0 to 6.3 s), partly run-to-run variation; see measurement_report.md).
- **What it costs the client if I am wrong:** if the refresh job is forgotten, Adwoa reads last week's figures without being told. If the definition of "spent" is wrong (assumptions below), every total is wrong in the same way, though it is fixed in one place.
- **Found afterwards, by reading the query plans:** the top-100 view does not use the rank index, because it picks one row per customer before filtering on rank. Reading the ranked rows directly was tested on a scratch copy (same 100 rows; 1.8 ms instead of 134 ms, medians of 5 runs on the test laptop) and **not applied**, because 0.15 s already meets the target. Details: measurement_report.md, plan 01.
- **What would make me revisit this:** Nana needing same-day figures (Alternative C, or refresh more often); the refresh time growing past a minute as orders accumulate; Adwoa needing a different definition of spend; the top-100 read exceeding about 1 second, or the stored report growing to about ten times today's size (then apply the tested rank-index read).

**Assumptions I made, which the brief left open:**
- **Spend** = orders whose status means completed or shipped. Pending is not yet fulfilled; cancelled and refunded orders returned the money. Stored as one column in `order_status_map`, so changing it is one update.
- **Order value** = `orders.total_amount`, not the sum of its lines (the lines contain duplicated rows and missing prices; data_findings F-03).
- **The 12 months end at `report_settings.as_of`**, 31 Aug 2026 for this extract, the last day of normal trading. For the extract that month is complete. In production, set it to the end of the last complete month, or the newest month will be partial.
- **Running total** = lifetime spend up to the end of each month, including spend before the 12-month window.
- **Ranking** uses `rank()`: customers with exactly equal spend share a place, so the list can exceed 100 rather than drop someone arbitrarily. Orders for customers who do not exist are kept in the totals ("unknown customer") but not ranked.

## What this survives

- **Flash-sale volume:** the report does no work during sales; it is rebuilt on a schedule. The sales path only maintains the 4 indexes.
- **Growth:** at about 4,000 orders a day the yearly volume roughly doubles the rebuild time; still seconds. Re-measure after a few months.
- **People reading during a refresh:** yes, `CONCURRENTLY` keeps the old figures readable until the new ones are ready.
- **Nana's team maintaining it:** one file, commented; settings in tables, not code; a self-check that fails loudly.