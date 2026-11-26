# ADR-005: Stop new bad data with rules; keep the existing bad data visible

- **Status:** Accepted
- **Date:** 2026-11-26
- **Decision owner:** Yaw Asiamah

## Context

The diagnosis found ten kinds of fault (data_findings.md): 15 spellings of order status, stock below zero and out of step with its history, orders for customers who do not exist, shared email addresses, a loop in the category tree, and more. The schema has no foreign keys, no unique email, no value checks. The brief says Nana is not precious about the schema but his team lives with it, and warns that effort spent fixing what was never broken counts against the work.

## Decision

I added rules that stop **new** bad rows (foreign keys, `stock >= 0`, positive quantities, safe ID numbering), using PostgreSQL's `NOT VALID` option wherever existing rows already break the rule, so the rule applies to every new insert and update while the old rows stay in place for review. I did **not** rewrite or delete existing data. Where reports must work around bad data, they do it in one visible place: `order_status_map` maps every status spelling to its meaning; `spend_orders` keeps orders for missing customers under "unknown customer"; the rollup shows cut-off categories in their own group.

## Alternatives considered

### Alternative A: Clean the data in place (merge duplicates, rewrite statuses, fix totals)

- **How it would work:** update the 159,384 statuses to one spelling, merge customers sharing an email, recompute order totals from lines.
- **Why it is attractive:** the data looks clean afterwards, and queries get simpler.
- **Why rejected:** several "fixes" cannot be checked. Two real people can share an email (a family, a shop); for 1,594 orders it is unknown whether the total or the lines are right; the application may keep writing the old status spellings. A wrong fix is worse than a visible fault, and it destroys the evidence an auditor might need.

### Alternative B: Delete the bad rows

- **How it would work:** remove orphan orders, orphan lines, future-dated orders.
- **Why it is attractive:** foreign keys could then be fully validated straight away.
- **Why rejected:** the 155 orphan orders hold 427,669 of real spend; deleting them would make totals wrong on purpose. Nothing is deleted.

### Alternative C: Add no rules; only report the faults

- **How it would work:** leave the schema as it is and hand Nana the findings.
- **Why it is attractive:** zero risk of breaking the application today.
- **Why rejected:** the faults keep arriving. Every new order for a non-existent customer, every new status spelling, every negative stock would add to the list.

### Alternative D: A hard rule on status spellings (a CHECK listing the five allowed values)

- **How it would work:** refuse any status that is not one of five exact words.
- **Why it is attractive:** the free-text problem would end at once.
- **Why rejected:** the application currently writes 15 spellings; the first order written as `COMPLETED` would fail at checkout. The mapping table makes reports correct now without risking sales; the hard rule can follow once the application is changed.

## Consequences

- **What this buys:** problems stop growing from today; every report is correct despite the old data; nothing is lost, so every finding can still be checked.
- **What this costs:** the old faults remain until someone reviews them. Reports carry small workarounds (the status map, "unknown customer", "not connected" groups), each documented.
- **What it costs the client if I am wrong:** if the application relies on writing data these rules now refuse (an order for a customer created later, a negative stock adjustment), it will get an error until changed. Rules were tested against the supplied test, which still passes.
- **What would make me revisit this:** a human review of the 533 shared emails (then merge and add a unique rule); a physical stock count (then correct the 144 products with correction rows); the application writing one status spelling (then replace the map with a hard rule); old orphans resolved (then `VALIDATE CONSTRAINT` to check the history too).

**Assumptions:** extract end = 31 Aug 2026 (orders run at about 1,000 a day until then; 24 scattered orders follow); negative movements in the log are stock going out, not errors; a stock-take with a change of zero means the count matched.

## What this survives

- **Flash-sale volume:** the rules are checked per row in microseconds; the foreign keys are backed by indexes (ADR-002), so deletes and checks stay fast.
- **The supplied test:** passes with every rule in place, including its own cleanup.
- **Nana's team maintaining it:** each rule is named and commented in `02_schema_changes.sql`; the status map is a seven-row table a non-developer can read.
