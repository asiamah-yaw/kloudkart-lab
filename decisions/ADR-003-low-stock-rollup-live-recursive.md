# ADR-003: Roll low stock up the category tree with a live, guarded recursive view

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Yaw Asiamah

## Context

Nana wants low stock at a glance, rolled up through nested categories (Electronics > Phones > Phone Accessories > Cases), in a couple of seconds. The tree is four levels deep today and marketing keeps adding levels; the brief forbids hard-coding the depth. Nothing in the schema stops a category pointing at a parent that does not exist or at itself in a loop, and the data has both (data_findings F-07). There is no reorder level in the data.

## Decision

I built the rollup as **plain (live) views** using a **recursive query** that pairs every category with itself and every category above it, then counts each product once for each category on its own path upwards. Two guards stop loops: PostgreSQL's `CYCLE` clause and a 50-level limit. Products in cut-off categories, and products with no category, are shown in their own groups instead of disappearing. "Low stock" is **5 units or fewer**, stored as one number in `stock_settings`.

## Alternatives considered

### Alternative A: Join the categories table to itself four times

- **How it would work:** fixed joins for level 1, 2, 3, 4.
- **Why it is attractive:** simple to read, fast, no recursion.
- **Why rejected:** forbidden by the brief, and it silently stops being right the week marketing adds a fifth level; no error would show it.

### Alternative B: Store each category's full path (or use the `ltree` extension)

- **How it would work:** keep a precomputed "Electronics/Phones/Cases" column and match on prefixes.
- **Why it is attractive:** very fast reads on large catalogues, simpler queries.
- **Why rejected:** every time marketing adds or moves a category, the stored paths of everything beneath must be rewritten, which is one more thing to keep in step. With 94 categories the recursive query already runs in milliseconds.

### Alternative C: Store the rollup (a materialized view, like the Monday report)

- **How it would work:** calculate the rollup on a schedule and read the stored copy.
- **Why it is attractive:** instant reads, same pattern as the Monday report.
- **Why rejected:** stock changes with every sale. A stored copy would be wrong within seconds, and this is the figure staff sell against. A live view is fast enough: 8.6 ms on the test laptop.

### Alternative D: A per-product threshold instead of one number

- **How it would work:** "low" when a product has less than, say, one week of its own sales left.
- **Why it is attractive:** a fast seller and a slow seller are not equally urgent at 5 units.
- **Why rejected for the rollup itself:** the data has no reorder levels, and the rollup should be explainable as one rule. Days of cover is provided separately in the stock health check (`stock_health`, the improvement), so both views exist.

## Consequences

- **What this buys:** works for any depth with no code change; live figures; measured 8.6 ms for the whole summary. A built-in check stops the load if the summary does not add up to the whole catalogue (4,023 products, 1,685 low stock), which proves there is no double counting and nothing is lost.
- **What this costs:** recalculated every time it is opened (cheap at this size). The threshold is one number for every product.
- **What it costs the client if I am wrong:** if 5 units is too high, 42% of products show as low and the list stops being useful; if too low, real shortages are missed. Either way it is one number to change.
- **What would make me revisit this:** a catalogue of tens of thousands of categories (consider stored paths), reorder levels becoming available (use them), the low-stock list being ignored because it is too long.

**Assumptions:** low stock = 5 units or fewer (in the latest month, August 2026, a typical product sold about 22 to 23 units, so 5 units is roughly a week of cover); out of stock counts as low; each product belongs to one category (the schema allows only one).

## What this survives

- **Marketing adding levels:** yes, no depth in the code.
- **A loop in the category data:** yes, the guard stops it and the loop is reported, not followed forever. (Without the guard the view would never finish; the data already contains one loop.)
- **Flash-sale volume:** the view reads stock at the moment it is opened; sales do no extra work for it.
- **Cut-off or uncategorised products:** shown in their own rows ("Not connected to a top category", "No category"), not silently dropped.