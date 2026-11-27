"""
Kloud Kart dashboard: stock and sales at a glance, for people who don't write SQL.

OPTIONAL and READ-ONLY. It is not part of the graded solution and is not run by
reset.ps1. It only reads the views the SQL solution already builds
(sql/05, 06, 09), so every figure here is the same figure as in the reports.

Run (from the kloudkart-lab folder, after reset.ps1):
    python -m pip install -r dashboard/requirements.txt
    $env:DATABASE_URL="postgresql://postgres:kloudkart@localhost:5432/lab"
    python -m streamlit run dashboard/app.py
Then open the address it prints (usually http://localhost:8501).
"""
import os

import pandas as pd
import psycopg2
import streamlit as st

st.set_page_config(page_title="Kloud Kart at a glance", layout="wide")


# ---------------------------------------------------------------------------
# Database access
# ---------------------------------------------------------------------------
def load_env_file(path=".env"):
    """Read KEY=value lines from a .env file in the folder you run from, if it
    exists, so DATABASE_URL need not be typed in every new terminal.
    A value already set in the terminal wins. The .env file is listed in
    .gitignore, so it is never uploaded; .env.example shows what goes in it."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


load_env_file()


@st.cache_resource
def get_connection():
    """One connection for the app, opened READ ONLY.

    default_transaction_read_only=on: the database itself refuses any change
    made through this connection, so a bug in the dashboard can never alter
    stock or orders. statement_timeout: no screen can hang the database.
    """
    url = os.environ.get("DATABASE_URL")
    if not url:
        st.error(
            "DATABASE_URL is not set. Either copy .env.example to .env in the kloudkart-lab folder, "
            "or in PowerShell run:\n\n"
            '$env:DATABASE_URL="postgresql://postgres:kloudkart@localhost:5432/lab"\n\n'
            "then start the dashboard again (from the kloudkart-lab folder)."
        )
        st.stop()
    conn = psycopg2.connect(
        url, options="-c default_transaction_read_only=on -c statement_timeout=15000"
    )
    conn.autocommit = True
    return conn


@st.cache_data(ttl=300, show_spinner=False)
def query(sql, params=None):
    """Run a SELECT and return a DataFrame. Results are kept for 5 minutes,
    so moving between tabs does not re-ask the database each time."""
    with get_connection().cursor() as cur:
        cur.execute(sql, params)
        columns = [c.name for c in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=columns)


def to_number(df, cols):
    """PostgreSQL numeric arrives as Python Decimal; charts need floats."""
    for c in cols:
        df[c] = pd.to_numeric(df[c])
    return df


def money(x):
    return f"{float(x):,.0f}"


# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
settings = query(
    """SELECT r.as_of, s.low_stock_threshold, s.sales_window_days, s.min_days_of_cover
       FROM report_settings r CROSS JOIN stock_settings s"""
).iloc[0]

st.title("Kloud Kart at a glance")
st.caption(
    f"Sales figures up to {settings['as_of']:%d %B %Y} (the Monday report's end date). "
    "Stock figures are live. Amounts are in the currency the shop records; the data does not state it. "
    "This screen only reads data; it cannot change anything."
)

tab_overview, tab_report, tab_low, tab_health, tab_problems = st.tabs(
    ["Overview", "Monday report", "Low stock", "Stock health", "Data problems"]
)

# ---------------------------------------------------------------------------
# 1. Overview
# ---------------------------------------------------------------------------
with tab_overview:
    k = query(
        """SELECT (SELECT sum(total_spent) FROM monday_report_summary)                          AS total_sales,
                  (SELECT count(*) FROM monday_report_summary
                    WHERE customer_known AND order_count > 0)                                   AS buying_customers,
                  (SELECT sum(low_stock) FROM low_stock_summary)                                AS low_stock,
                  (SELECT sum(out_of_stock) FROM low_stock_summary)                             AS out_of_stock,
                  (SELECT count(*) FROM stock_health_alerts)                                    AS needs_attention,
                  (SELECT count(*) FROM stock_health WHERE is_below_zero OR figure_mismatch)    AS untrusted"""
    ).iloc[0]

    c1, c2, c3, c4 = st.columns(4)
    c1.metric("Sales (completed + shipped)", money(k["total_sales"]))
    c2.metric("Customers who bought", f"{int(k['buying_customers']):,}")
    c3.metric(f"Products at {settings['low_stock_threshold']} units or fewer",
              f"{int(k['low_stock']):,}", help=f"{int(k['out_of_stock']):,} of them have none left.")
    c4.metric("Stock figures to check", f"{int(k['untrusted']):,}",
              help="Stock figure disagrees with its record of stock in and out, or is below zero.")

    st.subheader("Sales per month")
    monthly = to_number(
        query("""SELECT month, sum(month_spend) AS sales, sum(month_orders) AS orders
                 FROM monday_report GROUP BY month ORDER BY month"""),
        ["sales", "orders"],
    )
    monthly["month"] = pd.to_datetime(monthly["month"]).dt.strftime("%Y-%m")
    st.bar_chart(monthly, x="month", y="sales")
    st.caption("Completed and shipped orders only, last 12 months of the report.")

# ---------------------------------------------------------------------------
# 2. Monday report
# ---------------------------------------------------------------------------
with tab_report:
    st.subheader("Top 100 customers by total spent")
    show_names = st.toggle(
        "Show customer names and cities", value=False,
        help="Off by default, so the screen can be shared without showing personal details.",
    )
    top = to_number(
        query("""SELECT spend_rank, customer_id, full_name, city, total_spent,
                        order_count, spend_last_12_months
                 FROM top_100_customers ORDER BY spend_rank, customer_id"""),
        ["total_spent", "order_count", "spend_last_12_months"],
    )
    if not show_names:
        top = top.drop(columns=["full_name", "city"])
    st.dataframe(
        top, hide_index=True,
        column_config={
            "spend_rank": "Rank", "customer_id": "Customer", "full_name": "Name", "city": "City",
            "total_spent": st.column_config.NumberColumn("Total spent", format="%.2f"),
            "order_count": st.column_config.NumberColumn("Orders", format="%d"),
            "spend_last_12_months": st.column_config.NumberColumn("Last 12 months", format="%.2f"),
        },
    )
    st.caption("Equal totals share a rank, so the list can be slightly longer than 100. "
               "Orders whose customer is missing from the customer list are counted in sales but never ranked.")

    st.subheader("One customer, month by month")
    default_id = int(top["customer_id"].iloc[0]) if len(top) else 0
    cust = st.number_input("Customer number", min_value=0, value=default_id, step=1)
    one = query(
        """SELECT month, month_spend, running_total, total_spent, order_count, spend_rank
           FROM monday_report WHERE customer_id = %s ORDER BY month""",
        (int(cust),),
    )
    if one.empty:
        st.info("No customer with that number in the report.")
    else:
        one = to_number(one, ["month_spend", "running_total", "total_spent", "order_count"])
        one["month"] = pd.to_datetime(one["month"]).dt.strftime("%Y-%m")
        r = one.iloc[-1]
        a, b, c = st.columns(3)
        a.metric("Total spent", money(r["total_spent"]))
        b.metric("Orders", f"{int(r['order_count']):,}")
        c.metric("Rank", "not ranked" if pd.isna(r["spend_rank"]) else f"{int(r['spend_rank']):,}")
        left, right = st.columns(2)
        with left:
            st.caption("Spent each month")
            st.bar_chart(one, x="month", y="month_spend")
        with right:
            st.caption("Running total (lifetime spend up to the end of each month)")
            st.line_chart(one, x="month", y="running_total")

# ---------------------------------------------------------------------------
# 3. Low stock through the category tree
# ---------------------------------------------------------------------------
with tab_low:
    st.subheader(f"Products at {settings['low_stock_threshold']} units or fewer, by top category")
    summary = to_number(query("SELECT area, products, low_stock, out_of_stock FROM low_stock_summary"),
                        ["products", "low_stock", "out_of_stock"])
    st.bar_chart(summary, x="area", y=["low_stock", "out_of_stock"])
    st.dataframe(summary, hide_index=True,
                 column_config={"area": "Category", "products": "Products",
                                "low_stock": "Low (incl. none left)", "out_of_stock": "None left"})

    st.subheader("Look inside a category")
    areas = [a for a in summary["area"] if summary.loc[summary["area"] == a, "products"].iloc[0] > 0]
    area = st.selectbox("Category", areas)
    if area.startswith("Not connected") or area == "No category":
        st.info("These products are not under any top category (see data finding F-07), "
                "so they are listed directly below.")
        cats = None
        prods = query(
            """SELECT product_id, product_name, stock_quantity, category_path
               FROM low_stock_products
               WHERE NOT category_in_tree
                 AND (category_path = '(no category)') = (%s = 'No category')
               ORDER BY stock_quantity, product_name""",
            (area,),
        )
    else:
        cats = query(
            """SELECT path, depth, products_beneath, low_stock_beneath, out_of_stock_beneath
               FROM low_stock_by_category
               WHERE in_tree AND (path = %s OR path LIKE %s)
               ORDER BY path""",
            (area, area + " > %"),
        )
        st.dataframe(cats, hide_index=True,
                     column_config={"path": "Category", "depth": "Level",
                                    "products_beneath": "Products (incl. sub-categories)",
                                    "low_stock_beneath": "Low", "out_of_stock_beneath": "None left"})
        prods = query(
            """SELECT product_id, product_name, stock_quantity, category_path
               FROM low_stock_products
               WHERE category_path = %s OR category_path LIKE %s
               ORDER BY stock_quantity, product_name""",
            (area, area + " > %"),
        )
    st.caption(f"{len(prods):,} low-stock products here, fewest units first.")
    st.dataframe(prods, hide_index=True,
                 column_config={"product_id": "Product", "product_name": "Name",
                                "stock_quantity": "Units left", "category_path": "Category"})

# ---------------------------------------------------------------------------
# 4. Stock health (the improvement)
# ---------------------------------------------------------------------------
with tab_health:
    st.subheader("How much each product's stock can be trusted, and how soon it runs out")
    health = to_number(query("SELECT health, products, units_unexplained, value_unexplained FROM stock_health_summary"),
                       ["products", "units_unexplained", "value_unexplained"])
    health["problem"] = health["health"].str.slice(2)   # drop the "1 " sort prefix
    st.bar_chart(health, x="problem", y="products")
    st.caption(
        f"Days of cover = how many days the stock lasts at the last {settings['sales_window_days']} days' sales. "
        f"Flagged when under {settings['min_days_of_cover']} days."
    )

    st.subheader("Count these 20 products first")
    first = to_number(query("SELECT * FROM stock_count_first"),
                      ["value_unexplained", "percent_of_top_20"])
    total_gap = float(health["value_unexplained"].sum())
    share = float(first["value_unexplained"].sum()) / total_gap * 100 if total_gap else 0
    st.metric("Share of all unexplained stock value held by these 20", f"{share:.1f}%")
    st.dataframe(
        first, hide_index=True,
        column_config={"product_id": "Product", "product_name": "Name", "category_path": "Category",
                       "stock_figure": "Stock figure", "stock_per_history": "Per its record",
                       "difference": "Difference",
                       "value_unexplained": st.column_config.NumberColumn("Value of the gap (selling price)", format="%.2f"),
                       "percent_of_top_20": st.column_config.NumberColumn("% of these 20", format="%.1f")},
    )
    st.caption("Value is at selling price, so it is the most the gap could be worth, not a loss figure. "
               "Only a physical count shows which figure is right.")

    st.subheader("All products that need attention")
    choice = st.selectbox("Problem", list(health.loc[health["health"] != "5 ok", "health"]))
    alerts = query(
        """SELECT product_id, product_name, category_path, stock_figure, sold_recently,
                  days_of_cover, value_unexplained
           FROM stock_health_alerts WHERE health = %s""",
        (choice,),
    )
    st.dataframe(alerts, hide_index=True,
                 column_config={"product_id": "Product", "product_name": "Name", "category_path": "Category",
                                "stock_figure": "Stock", "sold_recently": "Sold recently",
                                "days_of_cover": "Days of cover", "value_unexplained": "Value of gap"})

# ---------------------------------------------------------------------------
# 5. Data problems (counted live; explained in data_findings.md)
# ---------------------------------------------------------------------------
with tab_problems:
    st.subheader("Problems found in the data, counted live")
    problems = query(
        """SELECT 'Ways the order status is spelled (5 real statuses)' AS problem,
                  (SELECT count(DISTINCT status) FROM orders)::bigint AS count, 'F-01' AS finding
           UNION ALL
           SELECT 'Products below zero stock',
                  (SELECT count(*) FROM products WHERE stock_quantity < 0), 'F-02'
           UNION ALL
           SELECT 'Products whose stock disagrees with its record',
                  (SELECT count(*) FROM stock_health WHERE figure_mismatch), 'F-02'
           UNION ALL
           SELECT 'Orders for customers missing from the customer list',
                  (SELECT count(*) FROM orders o
                    WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id)), 'F-04'
           UNION ALL
           SELECT 'Email addresses shared by more than one account',
                  (SELECT count(*) FROM (SELECT 1 FROM customers GROUP BY lower(trim(email))
                                         HAVING count(*) > 1) x), 'F-05'
           UNION ALL
           SELECT 'Orders dated after the end of the data',
                  (SELECT count(*) FROM orders WHERE order_date > (SELECT as_of FROM report_settings)), 'F-06'
           UNION ALL
           SELECT 'New status spellings the report does not recognise',
                  (SELECT count(*) FROM unmapped_order_statuses), 'F-01'"""
    )
    st.dataframe(problems, hide_index=True,
                 column_config={"problem": "Problem", "count": "Count", "finding": "Details in data_findings.md"})
    st.caption("The last line should stay at 0. If it rises, the shop has started writing a new status "
               "spelling and someone should add it to the status list.")