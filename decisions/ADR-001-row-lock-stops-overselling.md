# ADR-001: Lock the product row inside `place_order` to stop overselling

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Yaw Asiamah

## Context

Last month two orders took the same last unit, twice. Nobody wrote a bug: each order read the stock (1), decided it could sell, and took it. Under PostgreSQL's default isolation level (Read Committed), readers do not block each other, so two orders arriving together can both read 1 and both sell. The data shows the result: 14 products below zero, and for 13 of them the movement history itself goes below zero.

The supplied `race_test.py` fixes the contract: a function `place_order(customer, product, quantity)` called inside a `SELECT`, returning `(success, order_id, message)`; a refusal must say "out of stock"; no error may reach the caller; stock may never go below zero; the order and its stock movement must be one unit of work. Marketing expects flash sales of about 400 orders in ten seconds on one product.

Nana was told triggers might fix this.

## Decision

I built `place_order` as a single PL/pgSQL **function** that locks the product's row with `SELECT ... FOR UPDATE`, checks the stock it read under the lock, and only then creates the order, the order line and the stock decrement (whose movement row the audit trigger writes), all in the caller's one transaction. A `CHECK (stock_quantity >= 0)` rule sits underneath as a safety net.

## Alternatives considered

### Alternative A: One conditional update (`UPDATE ... SET stock = stock - q WHERE product_id = p AND stock >= q RETURNING ...`)

- **How it would work:** the check and the decrement happen in one statement. A second buyer waits on the row, then PostgreSQL re-checks the `WHERE` against the new stock and updates nothing; no row back means "out of stock".
- **Why it is attractive:** one statement, so the lock is held for the shortest possible time. Also correct.
- **Why rejected:** the difference in lock time is microseconds (both versions hold the lock until commit), and the measured flash sale already finishes in 4.3 to 8.1 seconds. My version reads stock and price under one lock, so it can tell "product not found" from "out of stock", and reads top to bottom as lock, check, decide for Nana's team. If contention ever became a measured problem, this is the change I would make first.

### Alternative B: Raise the isolation level to Serializable and retry

- **How it would work:** PostgreSQL aborts one of two conflicting transactions; the loser retries.
- **Why it is attractive:** no explicit lock to reason about; PostgreSQL guarantees the outcome is as if orders ran one at a time.
- **Why rejected:** the test calls the function in its own auto-committed transaction, so the isolation level is fixed before the function starts, and a retry inside the same transaction still sees the same old snapshot. The abort would reach the client as an error, which the test counts as a failure. With 400 buyers on one product, most attempts would abort.

### Alternative C: A trigger on stock alone (the suggestion Nana heard)

- **How it would work:** a trigger checks stock whenever an order line is written.
- **Why it is attractive:** it runs automatically for every writer, so it cannot be forgotten.
- **Why rejected:** each buyer's trigger runs inside that buyer's own transaction and cannot see the other buyer's unfinished change, so both still see 1 left and both pass. A trigger is the right tool for writing the stock trail (ADR-004), not for making buyers take turns.

### Alternative D: The `CHECK (stock >= 0)` rule alone

- **How it would work:** let both buyers try; the second update breaks the rule and fails.
- **Why it is attractive:** the database enforces it for every writer, even a manual update.
- **Why rejected:** it refuses with an error, not a clean "out of stock", and the error would reach the client. Kept as the safety net, not the mechanism.

## Consequences

- **What this buys:** exactly one buyer gets the last unit, every time. Measured on the test laptop: `race_test.py` passed 11 runs out of 11 (25/25 two-buyer rounds each; exactly 50 of 400 sold with 0 errors; oversell refused; trail intact). The same flash sale with the lock removed took **400 orders for 50 units** and left the stock showing 48.
- **What this costs:** during a flash sale buyers queue on one row. Measured: all 400 answered in 4.3 to 8.1 seconds (median 6.2 s after the indexes). Stock-and-order logic now lives in the database, so the shop application must call this function rather than update stock itself.
- **What it costs the client if I am wrong:** if the application keeps an old code path that updates stock directly, that path can still oversell (the CHECK rule stops it going below zero, but with an error at checkout, not a clean message).
- **What would make me revisit this:** multi-product orders (lock products in ascending `product_id` order so two orders cannot deadlock); measured lock waits becoming visible to customers (switch to Alternative A, and add a short `lock_timeout` with a clear "please try again"); the database's default isolation level being changed from Read Committed.

## What this survives

- **400 buyers in ten seconds on one product:** yes, tested. 4.3 to 8.1 seconds on a 2016 laptop (see measurement_report.md), no errors, no overselling. The slowest runs leave under 2 seconds of margin, so re-measure on the real server before the first flash sale.
- **Two buyers at the same instant, repeated:** yes, 275 rounds across 11 runs, one winner each time.
- **A manual stock update in a terminal:** cannot push stock below zero (CHECK rule), and is still logged (ADR-004). It is not protected by the lock unless it uses the function.
- **Nana's team maintaining it:** one commented function; the lock, the check and the decision are each a few lines.