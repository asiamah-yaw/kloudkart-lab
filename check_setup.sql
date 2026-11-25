-- check_setup.sql: version is 18, max_connections is 500, all 6 tables loaded.
SELECT version();
SHOW max_connections;
SELECT 'categories'    AS table_name, count(*) AS row_count FROM categories
UNION ALL SELECT 'products',      count(*) FROM products
UNION ALL SELECT 'customers',     count(*) FROM customers
UNION ALL SELECT 'orders',        count(*) FROM orders
UNION ALL SELECT 'order_items',   count(*) FROM order_items
UNION ALL SELECT 'inventory_log', count(*) FROM inventory_log
ORDER BY table_name;