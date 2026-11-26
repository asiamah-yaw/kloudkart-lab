# ADR-004: Record every stock change with a trigger, and keep the log append-only

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Yaw Asiamah

## Context

Nana wants a trail of every stock movement (sale, restock, correction) that an auditor could walk through afterwards. Today the stock figure and the movement log are written separately, and 144 products already disagree with their own history (data_findings F-02). The supplied test requires that every successful sale, including sales under contention, leaves a movement behind, and it deletes its own test rows when it cleans up.

## Decision

A **trigger on `products`** writes an `inventory_log` row for every change to `stock_quantity`, whoever makes it, in the same transaction as the change. The caller labels the change (for example "sale, order 659385") through two transaction-local settings; an unlabelled change is still logged, as `manual_change` with the database user's name. A new product's starting stock is logged as `opening_stock`. A second pair of triggers refuses `UPDATE` and `TRUNCATE` on the log, so history can be added to but not rewritten.

## Alternatives considered

### Alternative A: Write the log row inside `place_order` only

- **How it would work:** the order function inserts the movement itself.
- **Why it is attractive:** simple, explicit, no trigger to know about.
- **Why rejected:** only sales would be logged. A restock screen or a manual update in a terminal would change stock with no trail, which is exactly how the figure and the history drifted apart.

### Alternative B: Stop storing stock and calculate it from the log every time

- **How it would work:** stock = the sum of every movement for the product.
- **Why it is attractive:** the figure and the history can never disagree.
- **Why rejected:** summing a product's whole history on every sale is slow, and it brings the race back (two buyers sum the same history at once). The stored figure stays the authority; the stock health check compares it with the log instead.

### Alternative C: Block DELETE on the log as well (strictly append-only)

- **How it would work:** a trigger refuses every delete.
- **Why it is attractive:** nobody could remove an embarrassing movement.
- **Why rejected:** `race_test.py`, which must run unmodified, deletes the movements it creates when it cleans up; blocking DELETE would make it fail. Deletes should instead be limited by permissions: the shop application's login should not be allowed to delete from the log.

### Alternative D: Write "opening correction" rows now for the 144 products that disagree

- **How it would work:** add a correction per product so figure and history balance from today.
- **Why it is attractive:** the reconciliation would show zero differences from now on.
- **Why rejected:** I cannot tell which of the two figures is right. If the history was right, the correction would record the wrong figure as true. A physical count should come first; the stock health check lists the products in order of value.

## Consequences

- **What this buys:** every stock change has a matching movement row, labelled with why and by whom, rolled back together if the change fails. Old movements cannot be edited, only corrected by a new row. Tested: a manual update, a labelled restock and a sale each produced the right row; `race_test.py` Test 4 passes (every sale under contention left a movement).
- **What this costs:** one extra row written per stock change (part of the measured flash-sale time). Anyone changing stock should set the reason label, or the change shows as `manual_change`.
- **What it costs the client if I am wrong:** a database administrator can still switch triggers off or delete log rows. The trail is automatic, not tamper-proof.
- **What would make me revisit this:** an auditor requiring tamper-proof records (separate permissions for the application, or copying the log to a separate store); a high-volume restock process where per-row logging becomes measurable.

## What this survives

- **Flash-sale volume:** yes. Test 4 under 12 concurrent buyers and the 400-buyer sale both log every unit sold.
- **A manual change in a terminal:** still logged, with the user's name.
- **A failed sale:** the movement row disappears with it; the trail never shows a sale that did not happen.
- **Someone trying to "tidy" the history:** an UPDATE or TRUNCATE is refused with a message explaining how to record a correction.
