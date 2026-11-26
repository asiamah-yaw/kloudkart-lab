-- =====================================================================
-- 06_category_rollup.sql
-- Nana's 3rd ask: low-stock visibility at a glance, rolled up through
-- the nested category tree (Electronics > Phones > Phone Accessories >
-- Cases), in a couple of seconds. The brief forbids hard-coding how
-- deep the tree goes: marketing keeps adding levels.
--
--   stock_settings          one row: what "low stock" means (a number)
--   category_tree           every category with its depth and full path
--   low_stock_by_category   per category: products and low-stock
--                           products ANYWHERE beneath it (incl. itself)
--   low_stock_products      the actual products that are low, with path
--   low_stock_summary       top-level totals + "not in the tree" groups
--
-- PLAIN views, not stored: stock changes with every sale, so this must
-- always show the live figure. It is small (about 4,000 products, 94
-- categories), so it is fast without being stored.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. What "low stock" means. ASSUMPTION (no reorder level exists in the
-- data): 5 units or fewer. A typical product sells about 24 units a
-- month, about 6 a week, so 5 units is roughly one week of cover. Out
-- of stock (0 or below) counts as low too, and is also shown separately.
-- One number in a table: changing the rule needs no code change.
-- ---------------------------------------------------------------------
CREATE TABLE stock_settings (
    only_row             boolean PRIMARY KEY DEFAULT true CHECK (only_row),
    low_stock_threshold  integer NOT NULL CHECK (low_stock_threshold >= 0)
);
INSERT INTO stock_settings (low_stock_threshold) VALUES (5);

COMMENT ON TABLE stock_settings IS
    'Single-row stock settings. low_stock_threshold: a product with this many units or fewer is "low stock".';

-- ---------------------------------------------------------------------
-- 2. The tree, walked DOWN from the top categories to any depth.
-- Recursive CTE: the first part picks the top categories (no parent);
-- the second part repeatedly adds the children of the rows found in the
-- previous round, until a round finds nothing.
-- Two guards, because nothing in the data prevents a loop (finding F-07):
--   * CYCLE ... SET is_cycle: notices a category it has already visited
--     on this path and stops following it (and marks it).
--   * depth < 50: a hard stop no real catalogue will reach.
-- Categories never reached from a top category (loops, missing parent)
-- are kept with in_tree = false instead of silently disappearing.
-- ---------------------------------------------------------------------
CREATE VIEW category_tree AS
WITH RECURSIVE down (category_id, depth, path) AS (
    SELECT category_id, 1, category_name
    FROM   categories
    WHERE  parent_id IS NULL
  UNION ALL
    SELECT c.category_id, d.depth + 1, d.path || ' > ' || c.category_name
    FROM   down d
    JOIN   categories c ON c.parent_id = d.category_id
    WHERE  d.depth < 50
) CYCLE category_id SET is_cycle USING visited
SELECT c.category_id,
       c.category_name,
       c.parent_id,
       d.depth,
       coalesce(d.path, c.category_name || ' (not connected to a top category)') AS path,
       (d.category_id IS NOT NULL)                                             AS in_tree
FROM   categories c
LEFT   JOIN down d ON d.category_id = c.category_id AND NOT d.is_cycle;

COMMENT ON VIEW category_tree IS
    'Every category with its depth and full path from the top. in_tree = false: the category is cut off '
    '(its parent is missing or it is part of a loop) -- see data_findings F-07.';

-- ---------------------------------------------------------------------
-- 3. The rollup.
-- Step A (ancestors): walk UP from every category, pairing it with
--   itself and every category above it. Each product is then counted
--   once for each category on its own path upwards -- never twice for
--   the same category, so there is no double counting.
-- Step B: join products to those pairs and count per ancestor.
-- Same two guards against loops as above.
-- ---------------------------------------------------------------------
CREATE VIEW low_stock_by_category AS
WITH RECURSIVE ancestors (category_id, ancestor_id, hops) AS (
    SELECT category_id, category_id, 0
    FROM   categories
  UNION ALL
    SELECT a.category_id, c.parent_id, a.hops + 1
    FROM   ancestors a
    JOIN   categories c ON c.category_id = a.ancestor_id
    WHERE  c.parent_id IS NOT NULL
      AND  a.hops < 50
) CYCLE ancestor_id SET is_cycle USING visited,
threshold AS (
    SELECT low_stock_threshold AS t FROM stock_settings
),
counts AS (
    SELECT a.ancestor_id                                          AS category_id,
           count(*)                                               AS products_beneath,
           count(*) FILTER (WHERE p.stock_quantity <= th.t)       AS low_stock_beneath,
           count(*) FILTER (WHERE p.stock_quantity <= 0)          AS out_of_stock_beneath,
           count(*) FILTER (WHERE p.stock_quantity <= th.t AND a.hops = 0) AS low_stock_directly_in
    FROM   ancestors a
    JOIN   products p ON p.category_id = a.category_id
    CROSS  JOIN threshold th
    WHERE  NOT a.is_cycle
    GROUP  BY a.ancestor_id
)
SELECT t.category_id,
       t.category_name,
       t.depth,
       t.path,
       t.in_tree,
       coalesce(k.products_beneath, 0)       AS products_beneath,
       coalesce(k.low_stock_beneath, 0)      AS low_stock_beneath,
       coalesce(k.out_of_stock_beneath, 0)   AS out_of_stock_beneath,
       coalesce(k.low_stock_directly_in, 0)  AS low_stock_directly_in
FROM   category_tree t
LEFT   JOIN counts k ON k.category_id = t.category_id;

COMMENT ON VIEW low_stock_by_category IS
    'Per category: products and low-stock products anywhere beneath it, including itself '
    '(low_stock_directly_in = only those placed directly in it). Live figures; works for any tree depth.';

-- ---------------------------------------------------------------------
-- 4. The products behind the numbers (what to reorder).
-- ---------------------------------------------------------------------
CREATE VIEW low_stock_products AS
SELECT p.product_id,
       p.product_name,
       p.stock_quantity,
       coalesce(t.path, '(no category)')  AS category_path,
       coalesce(t.in_tree, false)         AS category_in_tree
FROM   products p
LEFT   JOIN category_tree t ON t.category_id = p.category_id
WHERE  p.stock_quantity <= (SELECT low_stock_threshold FROM stock_settings)
ORDER  BY p.stock_quantity, category_path, p.product_name;

-- ---------------------------------------------------------------------
-- 5. The one-screen summary: each top category, plus the two groups that
-- a rollup would otherwise silently lose (finding F-07).
-- ---------------------------------------------------------------------
CREATE VIEW low_stock_summary AS
SELECT path               AS area,
       products_beneath   AS products,
       low_stock_beneath  AS low_stock,
       out_of_stock_beneath AS out_of_stock
FROM   low_stock_by_category
WHERE  depth = 1
UNION ALL
SELECT 'Not connected to a top category (see F-07)',
       count(*),
       count(*) FILTER (WHERE p.stock_quantity <= s.low_stock_threshold),
       count(*) FILTER (WHERE p.stock_quantity <= 0)
FROM   products p
JOIN   category_tree t ON t.category_id = p.category_id AND NOT t.in_tree
CROSS  JOIN stock_settings s
UNION ALL
SELECT 'No category',
       count(*),
       count(*) FILTER (WHERE p.stock_quantity <= s.low_stock_threshold),
       count(*) FILTER (WHERE p.stock_quantity <= 0)
FROM   products p
CROSS  JOIN stock_settings s
WHERE  p.category_id IS NULL;

-- ---------------------------------------------------------------------
-- 6. Self-check: no double counting, nothing lost. The rows of the
-- summary must add up to exactly the number of products, and of
-- low-stock products, in the whole catalogue.
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_products_all   bigint := (SELECT count(*) FROM products);
    v_low_all        bigint := (SELECT count(*) FROM products
                                WHERE stock_quantity <= (SELECT low_stock_threshold FROM stock_settings));
    v_products_sum   bigint := (SELECT sum(products)  FROM low_stock_summary);
    v_low_sum        bigint := (SELECT sum(low_stock) FROM low_stock_summary);
BEGIN
    IF v_products_sum <> v_products_all OR v_low_sum <> v_low_all THEN
        RAISE EXCEPTION 'Low-stock rollup does not add up: products % vs %, low stock % vs %',
                        v_products_sum, v_products_all, v_low_sum, v_low_all;
    END IF;
    RAISE NOTICE 'Low-stock rollup adds up: % products, % low stock, no double counting.',
                 v_products_all, v_low_all;
END $$;