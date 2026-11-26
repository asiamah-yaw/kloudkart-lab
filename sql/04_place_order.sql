-- =====================================================================
-- 04_place_order.sql
-- Nana's 1st ask: two customers racing for the last unit -- exactly one
-- gets it, the other gets an instant, clear "out of stock", every time.
--
-- Contract (fixed by race_test.py, which stands in for the shop app):
--   place_order(p_customer_id bigint, p_product_id bigint, p_quantity integer)
--   RETURNS TABLE (success boolean, order_id bigint, message text)
--
-- Why a FUNCTION, not a PROCEDURE: the app (and the test) calls it inside
-- a SELECT and reads rows back. Procedures are called with CALL and
-- cannot be used in a SELECT. A function runs inside the caller's
-- transaction, so everything below succeeds or fails as ONE unit.
--
-- How overselling is prevented (row lock, under the default
-- READ COMMITTED isolation level):
--   1. SELECT ... FOR UPDATE locks the product's row.
--   2. A second buyer reaching the same line WAITS there.
--   3. When the first commits, the second re-reads the row, sees the
--      new stock (e.g. 0), and is refused cleanly.
-- 400 buyers on one product form a queue on that one row; the lock is
-- held only for the few statements below, so the queue moves fast.
-- One product per call means locks are always taken on one row, so two
-- calls can never deadlock on products.
-- =====================================================================

CREATE OR REPLACE FUNCTION place_order(
    p_customer_id bigint,
    p_product_id  bigint,
    p_quantity    integer
)
RETURNS TABLE (success boolean, order_id bigint, message text)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
    v_stock    integer;
    v_price    numeric(12,2);
    v_order_id bigint;
BEGIN
    -- 1. Reject nonsense input before touching anything.
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Order refused: quantity must be a positive whole number.';
        RETURN;
    END IF;

    -- 2. Unknown customer: answer cleanly instead of letting the foreign
    --    key raise an error at the client.
    IF NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = p_customer_id) THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Order refused: unknown customer.';
        RETURN;
    END IF;

    -- 3. Lock the product row and read its stock. Other buyers of this
    --    product wait here until we commit; buyers of OTHER products are
    --    not affected (row lock, not table lock).
    SELECT p.stock_quantity, p.price
      INTO v_stock, v_price
      FROM products p
     WHERE p.product_id = p_product_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RETURN QUERY SELECT false, NULL::bigint, 'Order refused: product not found.';
        RETURN;
    END IF;

    -- 4. Decide, using the value read UNDER the lock (nobody can change it
    --    between this check and our update).
    IF v_stock IS NULL OR v_stock < p_quantity THEN
        RETURN QUERY SELECT false, NULL::bigint,
            format('Sorry, out of stock: %s available, %s requested.',
                   greatest(coalesce(v_stock, 0), 0), p_quantity);
        RETURN;
    END IF;

    -- 5. Create the order and its line. The ID comes from the identity
    --    sequence, which never hands two callers the same number.
    INSERT INTO orders (customer_id, order_date, status, total_amount)
    VALUES (p_customer_id, now(), 'pending', v_price * p_quantity)
    RETURNING orders.order_id INTO v_order_id;

    INSERT INTO order_items (order_id, product_id, quantity, unit_price)
    VALUES (v_order_id, p_product_id, p_quantity, v_price);

    -- 6. Take the stock. The audit trigger writes the inventory_log row,
    --    labelled with these transaction-local settings.
    PERFORM set_config('kloudkart.stock_reason', 'sale', true);
    PERFORM set_config('kloudkart.stock_note', 'order ' || v_order_id, true);

    UPDATE products
       SET stock_quantity = stock_quantity - p_quantity
     WHERE product_id = p_product_id;

    -- Clear the label so a later change in the same transaction is not
    -- mislabelled as this sale.
    PERFORM set_config('kloudkart.stock_reason', '', true);
    PERFORM set_config('kloudkart.stock_note', '', true);

    RETURN QUERY SELECT true, v_order_id, 'Order placed.';
END $$;

COMMENT ON FUNCTION place_order(bigint, bigint, integer) IS
    'Places a single-product order. Locks the product row (FOR UPDATE) so concurrent buyers '
    'queue; refuses with "out of stock" when stock is insufficient. Order, order line, stock '
    'decrement and inventory_log row are one transaction. Requires READ COMMITTED (the default).';