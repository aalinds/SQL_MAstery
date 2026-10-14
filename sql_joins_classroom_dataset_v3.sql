-- =====================================================================
-- SQL JOIN + DATABASE CONCEPTS CLASSROOM DATASET  (v3)
-- PostgreSQL
--
-- Built so that (a) every JOIN type returns something different, and
-- (b) every code sample in the "Database Concepts for Analysts" PDF runs.
--
-- WHERE TO PRACTISE EACH JOIN
--   INNER JOIN       orders o  JOIN customers c        ON o.cust_id = c.customer_id
--   LEFT JOIN        customers c LEFT JOIN orders o    ON ...   (never ordered: WHERE o.order_id IS NULL)
--   RIGHT JOIN       products p RIGHT JOIN order_items i ON p.product_id = i.product_id
--   FULL OUTER JOIN  customers c FULL JOIN orders o    ON ...   (customers with no orders AND guest orders)
--                    stores s FULL JOIN employees e    ON ...   (stores with no staff AND unassigned employees)
--                    core.dim_brand b FULL JOIN products p ON ... (brands with no products AND unbranded products)
--                    products.suppliers s FULL JOIN products p ON ...
--   SELF JOIN        employees e JOIN employees m      ON e.manager_id = m.employee_id
--                    employees e1 JOIN employees e2    ON e1.dept_id = e2.dept_id AND e1.employee_id < e2.employee_id
--                    customers c LEFT JOIN customers r ON c.referred_by = r.customer_id
--                    finance.transfer_log t JOIN customers.wallets f/w ON from_account / to_account (two joins to one table)
--   CROSS JOIN       core.dim_color CROSS JOIN core.dim_storage   (5 x 4 = 20 variants)
--   NON-EQUI JOIN    products p JOIN core.dim_price_band b ON p.price BETWEEN b.min_price AND b.max_price
--   ANTI / SEMI      LEFT JOIN ... WHERE right.pk IS NULL ; NOT EXISTS ; EXISTS
--   MULTI-TABLE      customers -> orders -> order_items -> products -> dim_brand / suppliers
--
-- WHAT THE PDF NEEDS (all included)
--   order 1001 with 3 items (Laptop, Mouse x2, Cable)        -> SELECT ... FROM sales.order_items WHERE order_id = 1001
--   sales.orders.gross_total / discount_amount / net_total   -> SUM(net_total); denormalization lab
--   order_items.unit_price differs from today's price        -> "historical snapshot, not redundancy"
--   products.category = 'Electronics' (20 products)          -> BEGIN; UPDATE ... price * 1.10 ...
--   products.suppliers + products.supplier_id                -> "only the FK, JOIN for supplier details"
--   products.promotions                                      -> FK target for the promotion_products junction table
--   customers first_name / last_name / phone                 -> v_orders_with_customer view, "customer_id -> first_name, email, phone"
--   stores.employees first_name + email                      -> e.first_name, s.city join; "email lives in stores.employees"
--   customers.wallets + finance.transfer_log (cust 101, 202) -> wallet-to-wallet transfer transaction
--   finance.expenses                                         -> practice problem 4 (store_name argument)
--   finance.revenue_summary                                  -> "fully denormalized, derived from orders"
--   Cancelled orders before 2024 (4 orders)                  -> practice problem 7 (safe DELETE in a transaction)
--   CHECK (price > 0), CHECK (balance >= 0)                  -> Consistency demo: bad UPDATEs are rejected
--
-- NOT CREATED ON PURPOSE (the PDF asks you to design/create them yourself)
--   products.promotion_products  (junction table task)  |  employee skills junction (practice problem 3)
--
-- SCHEMA CHANGES vs. the original file
--   customers.customers : customer_name -> first_name, last_name (customer_name still exists, auto-built); + phone, referred_by
--   stores.employees    : employee_name -> first_name, last_name (auto-built); job_title -> role; + email, dept_id, manager_id; store_id nullable
--   products.products   : prod_id -> product_id; category now broad, new sub_category holds the old values;
--                         + supplier_id; brand_id nullable; CHECK (price > 0)
--   sales.order_items   : prod_id -> product_id; child tables of orders use ON DELETE CASCADE
--   sales.orders        : total_amount -> gross_total, discount_amount, net_total; cust_id nullable
--   NEW tables          : core.dim_department, dim_color, dim_storage, dim_price_band, products.suppliers, products.promotions,
--                         customers.wallets, finance.transfer_log, finance.expenses, finance.revenue_summary
--
-- EXPECTED RESULTS (verified on PostgreSQL 16)
--   INNER  orders-customers ............ 65 rows
--   LEFT   customers-orders ............ 84 rows  (19 customers have no orders)
--   RIGHT  customers-orders ............ 71 rows  (6 guest orders have no customer)
--   FULL   customers-orders ............ 90 rows
--   FULL   stores-employees ............ 80 rows  (20 stores w/o staff, 8 staff w/o store)
--   FULL   dim_brand-products .......... 65 rows  (5 brands w/o products, 5 unbranded products)
--   FULL   suppliers-products .......... 62 rows  (2 suppliers w/o products, 2 products w/o supplier)
--   SELF   employee -> manager ......... 57 matched, 3 have no manager, 3 earn more than their manager
--   SELF   same-department pairs ....... 215 pairs
--   SELF   customer -> referrer ........ 36 customers were referred by another customer
--   SELF   same-category product pairs . 480 pairs (category) / 190 pairs (sub_category)
--   CROSS  color x storage ............. 20 rows
--   Departments w/o employees .......... 2   |  Employees w/o department ... 2
--   Products never sold ................ 11   |  Draft orders with no items ... 8
--   Orders with no payment ............. 21   |  Orders with >1 payment ....... 6
--   Orders with no shipment ............ 33   |  Orders with >1 shipment ...... 4
--   Electronics products ............... 17   |  Cancelled orders before 2024 . 4
--   Customers without a wallet ......... 20   |  SUM(net_total) since 2025 .... 7,724,929
--   Order items priced differently from today's price: 34
-- =====================================================================

DROP SCHEMA IF EXISTS finance CASCADE;
DROP SCHEMA IF EXISTS sales CASCADE;
DROP SCHEMA IF EXISTS customers CASCADE;
DROP SCHEMA IF EXISTS products CASCADE;
DROP SCHEMA IF EXISTS stores CASCADE;
DROP SCHEMA IF EXISTS core CASCADE;

CREATE SCHEMA customers;
CREATE SCHEMA sales;
CREATE SCHEMA products;
CREATE SCHEMA stores;
CREATE SCHEMA core;
CREATE SCHEMA finance;


-- =========================
-- 1. TABLE DEFINITIONS
-- =========================

CREATE TABLE core.dim_brand (
    brand_id INT PRIMARY KEY,
    brand_name VARCHAR(100) NOT NULL,
    country VARCHAR(50)
);

CREATE TABLE core.dim_department (
    dept_id INT PRIMARY KEY,
    dept_name VARCHAR(50) NOT NULL
);

CREATE TABLE core.dim_color (
    color_id INT PRIMARY KEY,
    color_name VARCHAR(30) NOT NULL
);

CREATE TABLE core.dim_storage (
    storage_id INT PRIMARY KEY,
    storage_size VARCHAR(30) NOT NULL
);

CREATE TABLE core.dim_price_band (
    band_id INT PRIMARY KEY,
    band_name VARCHAR(30) NOT NULL,
    min_price NUMERIC(10,2) NOT NULL,
    max_price NUMERIC(10,2) NOT NULL
);

CREATE TABLE stores.stores (
    store_id INT PRIMARY KEY,
    store_name VARCHAR(100) NOT NULL,
    city VARCHAR(50),
    state VARCHAR(50)
);

CREATE TABLE customers.customers (
    customer_id INT PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    customer_name VARCHAR(101) GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
    city VARCHAR(50),
    state VARCHAR(50),
    email VARCHAR(120),
    phone VARCHAR(15),
    referred_by INT REFERENCES customers.customers(customer_id)   -- self join
);

CREATE TABLE stores.employees (
    employee_id INT PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    employee_name VARCHAR(101) GENERATED ALWAYS AS (first_name || ' ' || last_name) STORED,
    email VARCHAR(120),
    store_id INT REFERENCES stores.stores(store_id),              -- NULL = unassigned
    dept_id INT REFERENCES core.dim_department(dept_id),          -- NULL = no department
    role VARCHAR(50),
    salary INT,
    manager_id INT REFERENCES stores.employees(employee_id)       -- self join
);

CREATE TABLE products.suppliers (
    supplier_id INT PRIMARY KEY,
    supplier_name VARCHAR(100) NOT NULL,
    city VARCHAR(50),
    contact_email VARCHAR(120)
);

CREATE TABLE products.promotions (
    promo_id INT PRIMARY KEY,
    promo_name VARCHAR(100) NOT NULL,
    start_date DATE,
    end_date DATE,
    discount_pct NUMERIC(5,2)
);

CREATE TABLE products.products (
    product_id INT PRIMARY KEY,
    product_name VARCHAR(150) NOT NULL,
    category VARCHAR(50),                                         -- broad: Computers / Mobiles / Electronics / Accessories
    sub_category VARCHAR(50),                                     -- specific: Laptop, TV, Mouse ...
    brand_id INT REFERENCES core.dim_brand(brand_id),             -- NULL = unbranded
    supplier_id INT REFERENCES products.suppliers(supplier_id),   -- NULL = no supplier on record
    price NUMERIC(10,2) CHECK (price > 0)                         -- Consistency (the C in ACID)
);

CREATE TABLE sales.orders (
    order_id INT PRIMARY KEY,
    cust_id INT REFERENCES customers.customers(customer_id),      -- NULL = guest checkout
    store_id INT NOT NULL REFERENCES stores.stores(store_id),
    order_date DATE NOT NULL,
    order_status VARCHAR(30),
    gross_total NUMERIC(12,2),                                    -- denormalized: SUM(quantity*unit_price)
    discount_amount NUMERIC(12,2),                                -- denormalized
    net_total NUMERIC(12,2)                                       -- denormalized: gross_total - discount_amount
);

CREATE TABLE sales.order_items (
    order_item_id INT PRIMARY KEY,
    order_id INT NOT NULL REFERENCES sales.orders(order_id) ON DELETE CASCADE,
    product_id INT NOT NULL REFERENCES products.products(product_id),
    quantity INT NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL                             -- price AT TIME OF PURCHASE (historical snapshot)
);

CREATE TABLE sales.payments (
    payment_id INT PRIMARY KEY,
    order_id INT NOT NULL REFERENCES sales.orders(order_id) ON DELETE CASCADE,
    payment_date DATE NOT NULL,
    payment_method VARCHAR(30),
    payment_status VARCHAR(30),
    amount NUMERIC(12,2)
);

CREATE TABLE sales.shipments (
    shipment_id INT PRIMARY KEY,
    order_id INT NOT NULL REFERENCES sales.orders(order_id) ON DELETE CASCADE,
    shipment_date DATE,
    delivery_date DATE,
    carrier VARCHAR(50),
    shipment_status VARCHAR(30)
);

CREATE TABLE customers.wallets (
    cust_id INT PRIMARY KEY REFERENCES customers.customers(customer_id),
    balance NUMERIC(12,2) NOT NULL CHECK (balance >= 0),
    last_updated TIMESTAMP
);

CREATE TABLE finance.transfer_log (
    transfer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account INT NOT NULL REFERENCES customers.wallets(cust_id),
    to_account INT NOT NULL REFERENCES customers.wallets(cust_id),
    amount NUMERIC(12,2) NOT NULL,
    transferred_at TIMESTAMP,
    status VARCHAR(20)
);

CREATE TABLE finance.expenses (
    expense_id INT PRIMARY KEY,
    store_id INT NOT NULL REFERENCES stores.stores(store_id),
    expense_date DATE,
    expense_type VARCHAR(30),
    amount NUMERIC(12,2)
);

CREATE TABLE finance.revenue_summary (                           -- fully derived from sales.orders
    summary_month DATE PRIMARY KEY,
    order_count INT,
    gross_revenue NUMERIC(14,2),
    total_discount NUMERIC(14,2),
    net_revenue NUMERIC(14,2)
);

-- =========================
-- 2. DATA
-- =========================


INSERT INTO core.dim_brand VALUES (1, 'Apple', 'USA');
INSERT INTO core.dim_brand VALUES (2, 'Samsung', 'South Korea');
INSERT INTO core.dim_brand VALUES (3, 'Dell', 'USA');
INSERT INTO core.dim_brand VALUES (4, 'HP', 'USA');
INSERT INTO core.dim_brand VALUES (5, 'Lenovo', 'China');
INSERT INTO core.dim_brand VALUES (6, 'Sony', 'Japan');
INSERT INTO core.dim_brand VALUES (7, 'OnePlus', 'China');
INSERT INTO core.dim_brand VALUES (8, 'Xiaomi', 'China');
INSERT INTO core.dim_brand VALUES (9, 'LG', 'South Korea');
INSERT INTO core.dim_brand VALUES (10, 'Asus', 'Taiwan');
INSERT INTO core.dim_brand VALUES (11, 'Acer', 'Taiwan');
INSERT INTO core.dim_brand VALUES (12, 'Boat', 'India');
INSERT INTO core.dim_brand VALUES (13, 'JBL', 'USA');
INSERT INTO core.dim_brand VALUES (14, 'Canon', 'Japan');
INSERT INTO core.dim_brand VALUES (15, 'Nikon', 'Japan');
INSERT INTO core.dim_brand VALUES (16, 'Logitech', 'Switzerland');
INSERT INTO core.dim_brand VALUES (17, 'Microsoft', 'USA');
INSERT INTO core.dim_brand VALUES (18, 'Google', 'USA');
INSERT INTO core.dim_brand VALUES (19, 'Realme', 'China');
INSERT INTO core.dim_brand VALUES (20, 'Vivo', 'China');
INSERT INTO core.dim_brand VALUES (21, 'Motorola', 'USA');
INSERT INTO core.dim_brand VALUES (22, 'Nothing', 'UK');
INSERT INTO core.dim_brand VALUES (23, 'Panasonic', 'Japan');
INSERT INTO core.dim_brand VALUES (24, 'Philips', 'Netherlands');
INSERT INTO core.dim_brand VALUES (25, 'Bose', 'USA');

INSERT INTO core.dim_department VALUES (1, 'Sales');
INSERT INTO core.dim_department VALUES (2, 'Customer Support');
INSERT INTO core.dim_department VALUES (3, 'Inventory & Logistics');
INSERT INTO core.dim_department VALUES (4, 'Finance');
INSERT INTO core.dim_department VALUES (5, 'Store Operations');
INSERT INTO core.dim_department VALUES (6, 'Human Resources');
INSERT INTO core.dim_department VALUES (7, 'IT');
INSERT INTO core.dim_department VALUES (8, 'Marketing');
INSERT INTO core.dim_department VALUES (9, 'Legal');
INSERT INTO core.dim_department VALUES (10, 'Research & Development');

INSERT INTO core.dim_color VALUES (1, 'Black');
INSERT INTO core.dim_color VALUES (2, 'Silver');
INSERT INTO core.dim_color VALUES (3, 'Blue');
INSERT INTO core.dim_color VALUES (4, 'Red');
INSERT INTO core.dim_color VALUES (5, 'White');

INSERT INTO core.dim_storage VALUES (1, '128 GB');
INSERT INTO core.dim_storage VALUES (2, '256 GB');
INSERT INTO core.dim_storage VALUES (3, '512 GB');
INSERT INTO core.dim_storage VALUES (4, '1 TB');

INSERT INTO core.dim_price_band VALUES (1, 'Budget', 0, 9999.99);
INSERT INTO core.dim_price_band VALUES (2, 'Mid-range', 10000, 29999.99);
INSERT INTO core.dim_price_band VALUES (3, 'Premium', 30000, 59999.99);
INSERT INTO core.dim_price_band VALUES (4, 'Flagship', 60000, 999999.99);

INSERT INTO stores.stores VALUES (1, 'TechMart Delhi 1', 'Delhi', 'Delhi');
INSERT INTO stores.stores VALUES (2, 'TechMart Noida 2', 'Noida', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (3, 'TechMart Gurgaon 3', 'Gurgaon', 'Haryana');
INSERT INTO stores.stores VALUES (4, 'TechMart Jaipur 4', 'Jaipur', 'Rajasthan');
INSERT INTO stores.stores VALUES (5, 'TechMart Lucknow 5', 'Lucknow', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (6, 'TechMart Pune 6', 'Pune', 'Maharashtra');
INSERT INTO stores.stores VALUES (7, 'TechMart Mumbai 7', 'Mumbai', 'Maharashtra');
INSERT INTO stores.stores VALUES (8, 'TechMart Bengaluru 8', 'Bengaluru', 'Karnataka');
INSERT INTO stores.stores VALUES (9, 'TechMart Chandigarh 9', 'Chandigarh', 'Chandigarh');
INSERT INTO stores.stores VALUES (10, 'TechMart Hyderabad 10', 'Hyderabad', 'Telangana');
INSERT INTO stores.stores VALUES (11, 'TechMart Delhi 11', 'Delhi', 'Delhi');
INSERT INTO stores.stores VALUES (12, 'TechMart Noida 12', 'Noida', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (13, 'TechMart Gurgaon 13', 'Gurgaon', 'Haryana');
INSERT INTO stores.stores VALUES (14, 'TechMart Jaipur 14', 'Jaipur', 'Rajasthan');
INSERT INTO stores.stores VALUES (15, 'TechMart Lucknow 15', 'Lucknow', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (16, 'TechMart Pune 16', 'Pune', 'Maharashtra');
INSERT INTO stores.stores VALUES (17, 'TechMart Mumbai 17', 'Mumbai', 'Maharashtra');
INSERT INTO stores.stores VALUES (18, 'TechMart Bengaluru 18', 'Bengaluru', 'Karnataka');
INSERT INTO stores.stores VALUES (19, 'TechMart Chandigarh 19', 'Chandigarh', 'Chandigarh');
INSERT INTO stores.stores VALUES (20, 'TechMart Hyderabad 20', 'Hyderabad', 'Telangana');
INSERT INTO stores.stores VALUES (21, 'TechMart Delhi 21', 'Delhi', 'Delhi');
INSERT INTO stores.stores VALUES (22, 'TechMart Noida 22', 'Noida', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (23, 'TechMart Gurgaon 23', 'Gurgaon', 'Haryana');
INSERT INTO stores.stores VALUES (24, 'TechMart Jaipur 24', 'Jaipur', 'Rajasthan');
INSERT INTO stores.stores VALUES (25, 'TechMart Lucknow 25', 'Lucknow', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (26, 'TechMart Pune 26', 'Pune', 'Maharashtra');
INSERT INTO stores.stores VALUES (27, 'TechMart Mumbai 27', 'Mumbai', 'Maharashtra');
INSERT INTO stores.stores VALUES (28, 'TechMart Bengaluru 28', 'Bengaluru', 'Karnataka');
INSERT INTO stores.stores VALUES (29, 'TechMart Chandigarh 29', 'Chandigarh', 'Chandigarh');
INSERT INTO stores.stores VALUES (30, 'TechMart Hyderabad 30', 'Hyderabad', 'Telangana');
INSERT INTO stores.stores VALUES (31, 'TechMart Delhi 31', 'Delhi', 'Delhi');
INSERT INTO stores.stores VALUES (32, 'TechMart Noida 32', 'Noida', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (33, 'TechMart Gurgaon 33', 'Gurgaon', 'Haryana');
INSERT INTO stores.stores VALUES (34, 'TechMart Jaipur 34', 'Jaipur', 'Rajasthan');
INSERT INTO stores.stores VALUES (35, 'TechMart Lucknow 35', 'Lucknow', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (36, 'TechMart Pune 36', 'Pune', 'Maharashtra');
INSERT INTO stores.stores VALUES (37, 'TechMart Mumbai 37', 'Mumbai', 'Maharashtra');
INSERT INTO stores.stores VALUES (38, 'TechMart Bengaluru 38', 'Bengaluru', 'Karnataka');
INSERT INTO stores.stores VALUES (39, 'TechMart Chandigarh 39', 'Chandigarh', 'Chandigarh');
INSERT INTO stores.stores VALUES (40, 'TechMart Hyderabad 40', 'Hyderabad', 'Telangana');
INSERT INTO stores.stores VALUES (41, 'TechMart Delhi 41', 'Delhi', 'Delhi');
INSERT INTO stores.stores VALUES (42, 'TechMart Noida 42', 'Noida', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (43, 'TechMart Gurgaon 43', 'Gurgaon', 'Haryana');
INSERT INTO stores.stores VALUES (44, 'TechMart Jaipur 44', 'Jaipur', 'Rajasthan');
INSERT INTO stores.stores VALUES (45, 'TechMart Lucknow 45', 'Lucknow', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (46, 'TechMart Pune 46', 'Pune', 'Maharashtra');
INSERT INTO stores.stores VALUES (47, 'TechMart Mumbai 47', 'Mumbai', 'Maharashtra');
INSERT INTO stores.stores VALUES (48, 'TechMart Bengaluru 48', 'Bengaluru', 'Karnataka');
INSERT INTO stores.stores VALUES (49, 'TechMart Chandigarh 49', 'Chandigarh', 'Chandigarh');
INSERT INTO stores.stores VALUES (50, 'TechMart Hyderabad 50', 'Hyderabad', 'Telangana');
INSERT INTO stores.stores VALUES (51, 'TechMart Delhi 51', 'Delhi', 'Delhi');
INSERT INTO stores.stores VALUES (52, 'TechMart Noida 52', 'Noida', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (53, 'TechMart Gurgaon 53', 'Gurgaon', 'Haryana');
INSERT INTO stores.stores VALUES (54, 'TechMart Jaipur 54', 'Jaipur', 'Rajasthan');
INSERT INTO stores.stores VALUES (55, 'TechMart Lucknow 55', 'Lucknow', 'Uttar Pradesh');
INSERT INTO stores.stores VALUES (56, 'TechMart Pune 56', 'Pune', 'Maharashtra');
INSERT INTO stores.stores VALUES (57, 'TechMart Mumbai 57', 'Mumbai', 'Maharashtra');
INSERT INTO stores.stores VALUES (58, 'TechMart Bengaluru 58', 'Bengaluru', 'Karnataka');
INSERT INTO stores.stores VALUES (59, 'TechMart Chandigarh 59', 'Chandigarh', 'Chandigarh');
INSERT INTO stores.stores VALUES (60, 'TechMart Hyderabad 60', 'Hyderabad', 'Telangana');

INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (1, 'Ankit', 'Mishra', 'Delhi', 'Delhi', 'ankit1@example.com', '9800007919', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (2, 'Rahul', 'Arora', 'Noida', 'Uttar Pradesh', 'rahul2@example.com', '9800015838', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (3, 'Priya', 'Khanna', 'Gurgaon', 'Haryana', 'priya3@example.com', '9800023757', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (4, 'Aman', 'Dubey', 'Jaipur', 'Rajasthan', 'aman4@example.com', '9800031676', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (5, 'Neha', 'Pandey', 'Lucknow', 'Uttar Pradesh', 'neha5@example.com', '9800039595', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (6, 'Rohit', 'Menon', 'Pune', 'Maharashtra', 'rohit6@example.com', '9800047514', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (7, 'Sneha', 'Tiwari', 'Mumbai', 'Maharashtra', 'sneha7@example.com', '9800055433', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (8, 'Vikas', 'Shah', 'Bengaluru', 'Karnataka', 'vikas8@example.com', '9800063352', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (9, 'Pooja', 'Bhatia', 'Chandigarh', 'Chandigarh', 'pooja9@example.com', '9800071271', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (10, 'Arjun', 'Patel', 'Hyderabad', 'Telangana', 'arjun10@example.com', '9800079190', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (11, 'Karan', 'Joshi', 'Delhi', 'Delhi', 'karan11@example.com', NULL, NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (12, 'Simran', 'Desai', 'Noida', 'Uttar Pradesh', 'simran12@example.com', '9800095028', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (13, 'Aditya', 'Saxena', 'Gurgaon', 'Haryana', 'aditya13@example.com', '9800102947', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (14, 'Nisha', 'Rao', 'Jaipur', 'Rajasthan', 'nisha14@example.com', '9800110866', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (15, 'Varun', 'Kapoor', 'Lucknow', 'Uttar Pradesh', 'varun15@example.com', '9800118785', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (16, 'Kavya', 'Mishra', 'Pune', 'Maharashtra', 'kavya16@example.com', '9800126704', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (17, 'Manish', 'Arora', 'Mumbai', 'Maharashtra', 'manish17@example.com', '9800134623', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (18, 'Riya', 'Khanna', 'Bengaluru', 'Karnataka', 'riya18@example.com', '9800142542', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (19, 'Saurabh', 'Dubey', 'Chandigarh', 'Chandigarh', 'saurabh19@example.com', '9800150461', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (20, 'Isha', 'Pandey', 'Hyderabad', 'Telangana', 'isha20@example.com', '9800158380', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (21, 'Mohit', 'Menon', 'Delhi', 'Delhi', 'mohit21@example.com', '9800166299', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (22, 'Shreya', 'Tiwari', 'Noida', 'Uttar Pradesh', 'shreya22@example.com', NULL, 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (23, 'Nitin', 'Shah', 'Gurgaon', 'Haryana', 'nitin23@example.com', '9800182137', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (24, 'Anjali', 'Bhatia', 'Jaipur', 'Rajasthan', 'anjali24@example.com', '9800190056', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (25, 'Deepak', 'Patel', 'Lucknow', 'Uttar Pradesh', 'deepak25@example.com', '9800197975', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (26, 'Meera', 'Joshi', 'Pune', 'Maharashtra', 'meera26@example.com', '9800205894', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (27, 'Abhishek', 'Desai', 'Mumbai', 'Maharashtra', 'abhishek27@example.com', '9800213813', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (28, 'Tanya', 'Saxena', 'Bengaluru', 'Karnataka', 'tanya28@example.com', '9800221732', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (29, 'Yash', 'Rao', 'Chandigarh', 'Chandigarh', 'yash29@example.com', '9800229651', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (30, 'Aditi', 'Kapoor', 'Hyderabad', 'Telangana', 'aditi30@example.com', '9800237570', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (31, 'Ravi', 'Mishra', 'Delhi', 'Delhi', 'ravi31@example.com', '9800245489', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (32, 'Sakshi', 'Arora', 'Noida', 'Uttar Pradesh', 'sakshi32@example.com', '9800253408', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (33, 'Harsh', 'Khanna', 'Gurgaon', 'Haryana', 'harsh33@example.com', NULL, 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (34, 'Muskan', 'Dubey', 'Jaipur', 'Rajasthan', 'muskan34@example.com', '9800269246', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (35, 'Akash', 'Pandey', 'Lucknow', 'Uttar Pradesh', 'akash35@example.com', '9800277165', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (36, 'Divya', 'Menon', 'Pune', 'Maharashtra', 'divya36@example.com', '9800285084', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (37, 'Gaurav', 'Tiwari', 'Mumbai', 'Maharashtra', 'gaurav37@example.com', '9800293003', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (38, 'Komal', 'Shah', 'Bengaluru', 'Karnataka', 'komal38@example.com', '9800300922', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (39, 'Ayush', 'Bhatia', 'Chandigarh', 'Chandigarh', 'ayush39@example.com', '9800308841', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (40, 'Preeti', 'Patel', 'Hyderabad', 'Telangana', 'preeti40@example.com', '9800316760', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (41, 'Vivek', 'Joshi', 'Delhi', 'Delhi', 'vivek41@example.com', '9800324679', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (42, 'Swati', 'Desai', 'Noida', 'Uttar Pradesh', 'swati42@example.com', '9800332598', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (43, 'Rakesh', 'Saxena', 'Gurgaon', 'Haryana', 'rakesh43@example.com', '9800340517', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (44, 'Pallavi', 'Rao', 'Jaipur', 'Rajasthan', 'pallavi44@example.com', NULL, NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (45, 'Sumit', 'Kapoor', 'Lucknow', 'Uttar Pradesh', 'sumit45@example.com', '9800356355', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (46, 'Tanvi', 'Mishra', 'Pune', 'Maharashtra', 'tanvi46@example.com', '9800364274', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (47, 'Rajat', 'Arora', 'Mumbai', 'Maharashtra', 'rajat47@example.com', '9800372193', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (48, 'Mansi', 'Khanna', 'Bengaluru', 'Karnataka', 'mansi48@example.com', '9800380112', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (49, 'Aakash', 'Dubey', 'Chandigarh', 'Chandigarh', 'aakash49@example.com', '9800388031', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (50, 'Kirti', 'Pandey', 'Hyderabad', 'Telangana', 'kirti50@example.com', '9800395950', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (51, 'Aarav', 'Menon', 'Delhi', 'Delhi', 'aarav51@example.com', '9800403869', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (52, 'Ananya', 'Tiwari', 'Noida', 'Uttar Pradesh', 'ananya52@example.com', '9800411788', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (53, 'Dev', 'Shah', 'Gurgaon', 'Haryana', 'dev53@example.com', '9800419707', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (54, 'Ishita', 'Bhatia', 'Jaipur', 'Rajasthan', 'ishita54@example.com', '9800427626', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (55, 'Kabir', 'Patel', 'Lucknow', 'Uttar Pradesh', 'kabir55@example.com', NULL, 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (56, 'Navya', 'Joshi', 'Pune', 'Maharashtra', 'navya56@example.com', '9800443464', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (57, 'Rohan', 'Desai', 'Mumbai', 'Maharashtra', 'rohan57@example.com', '9800451383', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (58, 'Sanya', 'Saxena', 'Bengaluru', 'Karnataka', 'sanya58@example.com', '9800459302', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (59, 'Varun', 'Rao', 'Chandigarh', 'Chandigarh', 'varun59@example.com', '9800467221', 8);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (60, 'Zoya', 'Kapoor', 'Hyderabad', 'Telangana', 'zoya60@example.com', '9800475140', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (101, 'Priya', 'Sharma', 'Mumbai', 'Maharashtra', 'priya.sharma101@example.com', '9876543210', NULL);
INSERT INTO customers.customers (customer_id, first_name, last_name, city, state, email, phone, referred_by) VALUES (202, 'Rahul', 'Verma', 'Delhi', 'Delhi', 'rahul.verma202@example.com', '9123456789', NULL);

INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (1, 'Manish', 'Kumar', 'manish.kumar1@retailmart.com', 1, 5, 'General Manager', 150000, NULL);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (2, 'Riya', 'Yadav', 'riya.yadav2@retailmart.com', 2, 5, 'Regional Manager', 70000, 1);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (3, 'Saurabh', 'Nair', 'saurabh.nair3@retailmart.com', 3, 5, 'Regional Manager', 72500, 1);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (4, 'Isha', 'Verma', 'isha.verma4@retailmart.com', 4, 5, 'Regional Manager', 75000, 1);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (5, 'Mohit', 'Mehta', 'mohit.mehta5@retailmart.com', 5, 5, 'Regional Manager', 77500, 1);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (6, 'Shreya', 'Chopra', 'shreya.chopra6@retailmart.com', 6, 5, 'Regional Manager', 80000, 1);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (7, 'Nitin', 'Iyer', 'nitin.iyer7@retailmart.com', 7, 1, 'Sales Executive', 43000, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (8, 'Anjali', 'Gupta', 'anjali.gupta8@retailmart.com', 8, 2, 'Support Executive', 45500, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (9, 'Deepak', 'Agarwal', 'deepak.agarwal9@retailmart.com', 9, 3, 'Inventory Associate', 48000, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (10, 'Meera', 'Malhotra', 'meera.malhotra10@retailmart.com', 10, 4, 'Cashier', 50500, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (11, 'Abhishek', 'Bansal', 'abhishek.bansal11@retailmart.com', 11, 1, 'Sales Executive', 28000, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (12, 'Tanya', 'Singh', 'tanya.singh12@retailmart.com', 12, 2, 'Support Executive', 30500, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (13, 'Yash', 'Jain', 'yash.jain13@retailmart.com', 13, 5, 'Store Manager', 33000, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (14, 'Aditi', 'Reddy', 'aditi.reddy14@retailmart.com', 14, 6, 'HR Executive', 35500, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (15, 'Ravi', 'Sharma', 'ravi.sharma15@retailmart.com', 15, 7, 'IT Support Engineer', 38000, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (16, 'Sakshi', 'Kumar', 'sakshi.kumar16@retailmart.com', 16, 8, 'Marketing Executive', 40500, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (17, 'Harsh', 'Yadav', 'harsh.yadav17@retailmart.com', 17, 1, 'Sales Executive', 43000, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (18, 'Muskan', 'Nair', 'muskan.nair18@retailmart.com', 18, 2, 'Support Executive', 45500, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (19, 'Akash', 'Verma', 'akash.verma19@retailmart.com', 19, 3, 'Inventory Associate', 48000, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (20, 'Divya', 'Mehta', 'divya.mehta20@retailmart.com', 20, 4, 'Cashier', 80000, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (21, 'Gaurav', 'Chopra', 'gaurav.chopra21@retailmart.com', 21, 1, 'Sales Executive', 28000, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (22, 'Komal', 'Iyer', 'komal.iyer22@retailmart.com', 22, 2, 'Support Executive', 30500, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (23, 'Ayush', 'Gupta', 'ayush.gupta23@retailmart.com', 23, 5, 'Store Manager', 33000, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (24, 'Preeti', 'Agarwal', 'preeti.agarwal24@retailmart.com', 24, 6, 'HR Executive', 35500, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (25, 'Vivek', 'Malhotra', 'vivek.malhotra25@retailmart.com', 25, 7, 'IT Support Engineer', 38000, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (26, 'Swati', 'Bansal', 'swati.bansal26@retailmart.com', 26, 8, 'Marketing Executive', 40500, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (27, 'Rakesh', 'Singh', 'rakesh.singh27@retailmart.com', 27, 1, 'Sales Executive', 43000, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (28, 'Pallavi', 'Jain', 'pallavi.jain28@retailmart.com', 28, 2, 'Support Executive', 45500, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (29, 'Sumit', 'Reddy', 'sumit.reddy29@retailmart.com', 29, 3, 'Inventory Associate', 48000, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (30, 'Tanvi', 'Sharma', 'tanvi.sharma30@retailmart.com', 30, 4, 'Cashier', 50500, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (31, 'Rajat', 'Kumar', 'rajat.kumar31@retailmart.com', 31, 1, 'Sales Executive', 28000, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (32, 'Mansi', 'Yadav', 'mansi.yadav32@retailmart.com', 32, 2, 'Support Executive', 30500, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (33, 'Aakash', 'Nair', 'aakash.nair33@retailmart.com', 33, 5, 'Store Manager', 80000, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (34, 'Kirti', 'Verma', 'kirti.verma34@retailmart.com', 34, 6, 'HR Executive', 35500, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (35, 'Aarav', 'Mehta', 'aarav.mehta35@retailmart.com', 35, 7, 'IT Support Engineer', 38000, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (36, 'Ananya', 'Chopra', 'ananya.chopra36@retailmart.com', 36, 8, 'Marketing Executive', 40500, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (37, 'Dev', 'Iyer', 'dev.iyer37@retailmart.com', 37, 1, 'Sales Executive', 43000, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (38, 'Ishita', 'Gupta', 'ishita.gupta38@retailmart.com', 38, 2, 'Support Executive', 45500, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (39, 'Kabir', 'Agarwal', 'kabir.agarwal39@retailmart.com', 39, 3, 'Inventory Associate', 48000, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (40, 'Navya', 'Malhotra', 'navya.malhotra40@retailmart.com', 40, 4, 'Cashier', 50500, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (41, 'Rohan', 'Bansal', 'rohan.bansal41@retailmart.com', 1, 1, 'Sales Executive', 28000, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (42, 'Sanya', 'Singh', 'sanya.singh42@retailmart.com', 2, 2, 'Support Executive', 30500, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (43, 'Varun', 'Jain', 'varun.jain43@retailmart.com', 3, 5, 'Store Manager', 33000, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (44, 'Zoya', 'Reddy', 'zoya.reddy44@retailmart.com', 4, 6, 'HR Executive', 35500, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (45, 'Ankit', 'Sharma', 'ankit.sharma45@retailmart.com', 5, 7, 'IT Support Engineer', 38000, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (46, 'Rahul', 'Kumar', 'rahul.kumar46@retailmart.com', 6, 8, 'Marketing Executive', 40500, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (47, 'Priya', 'Yadav', 'priya.yadav47@retailmart.com', 7, 1, 'Sales Executive', 80000, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (48, 'Aman', 'Nair', 'aman.nair48@retailmart.com', 8, 2, 'Support Executive', 45500, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (49, 'Neha', 'Verma', 'neha.verma49@retailmart.com', 9, 3, 'Inventory Associate', 48000, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (50, 'Rohit', 'Mehta', 'rohit.mehta50@retailmart.com', 10, 4, 'Cashier', 50500, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (51, 'Sneha', 'Chopra', 'sneha.chopra51@retailmart.com', 11, 1, 'Sales Executive', 28000, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (52, 'Vikas', 'Iyer', 'vikas.iyer52@retailmart.com', 12, 2, 'Support Executive', 30500, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (53, 'Pooja', 'Gupta', 'pooja.gupta53@retailmart.com', NULL, 5, 'Store Manager', 33000, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (54, 'Arjun', 'Agarwal', 'arjun.agarwal54@retailmart.com', NULL, 6, 'HR Executive', 35500, 4);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (55, 'Karan', 'Malhotra', 'karan.malhotra55@retailmart.com', NULL, 7, 'IT Support Engineer', 38000, 5);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (56, 'Simran', 'Bansal', 'simran.bansal56@retailmart.com', NULL, 8, 'Marketing Executive', 40500, 6);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (57, 'Aditya', 'Singh', 'aditya.singh57@retailmart.com', NULL, 1, 'Sales Executive', 43000, 2);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (58, 'Nisha', 'Jain', 'nisha.jain58@retailmart.com', NULL, 2, 'Support Executive', 45500, 3);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (59, 'Varun', 'Reddy', 'varun.reddy59@retailmart.com', NULL, NULL, 'Contract Consultant', 48000, NULL);
INSERT INTO stores.employees (employee_id, first_name, last_name, email, store_id, dept_id, role, salary, manager_id) VALUES (60, 'Kavya', 'Sharma', 'kavya.sharma60@retailmart.com', NULL, NULL, 'Contract Consultant', 50500, NULL);

INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (1, 'Ingram Micro India', 'Mumbai', 'sales@ingrammicro.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (2, 'Redington India', 'Chennai', 'orders@redington.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (3, 'Rashi Peripherals', 'Mumbai', 'care@rashi.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (4, 'Supertron Electronics', 'Delhi', 'trade@supertron.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (5, 'Savex Technologies', 'Mumbai', 'b2b@savex.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (6, 'Compuage Infocom', 'Mumbai', 'info@compuage.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (7, 'Iris Global Services', 'Gurgaon', 'sales@irisglobal.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (8, 'Cadence Distribution', 'Bengaluru', 'orders@cadence.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (9, 'Pioneer Distributors', 'Jaipur', 'trade@pioneer.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (10, 'Neo Wholesale Traders', 'Pune', 'hello@neowholesale.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (11, 'Zenith Imports', 'Hyderabad', 'imports@zenith.example.com');
INSERT INTO products.suppliers (supplier_id, supplier_name, city, contact_email) VALUES (12, 'Orbit Trading Co.', 'Lucknow', 'sales@orbit.example.com');

INSERT INTO products.promotions (promo_id, promo_name, start_date, end_date, discount_pct) VALUES (1, 'Diwali Dhamaka', '2025-10-15', '2025-11-05', 15);
INSERT INTO products.promotions (promo_id, promo_name, start_date, end_date, discount_pct) VALUES (2, 'New Year Sale', '2025-12-26', '2026-01-05', 10);
INSERT INTO products.promotions (promo_id, promo_name, start_date, end_date, discount_pct) VALUES (3, 'Republic Day Offer', '2026-01-22', '2026-01-28', 12);
INSERT INTO products.promotions (promo_id, promo_name, start_date, end_date, discount_pct) VALUES (4, 'Summer Clearance', '2026-04-01', '2026-05-31', 20);
INSERT INTO products.promotions (promo_id, promo_name, start_date, end_date, discount_pct) VALUES (5, 'Back to School', '2026-06-01', '2026-06-30', 8);
INSERT INTO products.promotions (promo_id, promo_name, start_date, end_date, discount_pct) VALUES (6, 'Monsoon Mega Deal', '2026-07-15', '2026-08-15', 18);
INSERT INTO products.promotions (promo_id, promo_name, start_date, end_date, discount_pct) VALUES (7, 'Festive Preview', '2026-09-20', '2026-10-10', 5);
INSERT INTO products.promotions (promo_id, promo_name, start_date, end_date, discount_pct) VALUES (8, 'Black Friday', '2026-11-27', '2026-11-30', 25);

INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (1, 'MacBook Air M3 1', 'Computers', 'Laptop', 1, 2, 99999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (2, 'Galaxy S24 2', 'Mobiles', 'Mobile', 2, 3, 74999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (3, 'Dell Inspiron 15 3', 'Computers', 'Laptop', 3, 4, 58999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (4, 'HP Pavilion 14 4', 'Computers', 'Laptop', 4, 5, 64999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (5, 'Lenovo IdeaPad 3 5', 'Computers', 'Laptop', 5, 6, 47999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (6, 'Sony WH-1000XM5 6', 'Electronics', 'Headphones', 6, 7, 29999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (7, 'OnePlus 12 7', 'Mobiles', 'Mobile', 7, 8, 64999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (8, 'Redmi Note 14 8', 'Mobiles', 'Mobile', 8, 9, 24999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (9, 'LG UltraGear 27 9', 'Computers', 'Monitor', 9, 10, 28999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (10, 'Asus Vivobook 15 10', 'Computers', 'Laptop', 10, 1, 55999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (11, 'Acer Aspire 7 11', 'Computers', 'Laptop', 11, 2, 62999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (12, 'Boat Rockerz 550 12', 'Electronics', 'Headphones', 12, 3, 1999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (13, 'JBL Tune 770NC 13', 'Electronics', 'Headphones', 13, 4, 5999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (14, 'Canon EOS 1500D 14', 'Electronics', 'Camera', 14, 5, 41999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (15, 'Nikon D3500 15', 'Electronics', 'Camera', 15, 6, 45999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (16, 'Logitech MX Keys 16', 'Accessories', 'Keyboard', 16, 7, 8999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (17, 'Microsoft Surface Go 17', 'Computers', 'Tablet', 17, 8, 49999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (18, 'Google Pixel 9 18', 'Mobiles', 'Mobile', 18, 9, 79999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (19, 'Realme GT 6 19', 'Mobiles', 'Mobile', 19, 10, 39999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (20, 'Vivo V40 20', 'Mobiles', 'Mobile', 20, 1, 34999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (21, 'Samsung 55 OLED 21', 'Electronics', 'TV', 2, 2, 109999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (22, 'LG 50 4K TV 22', 'Electronics', 'TV', 9, 3, 59999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (23, 'Apple Watch Series 10 23', 'Electronics', 'Smartwatch', 1, 4, 46999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (24, 'Galaxy Watch 7 24', 'Electronics', 'Smartwatch', 2, 5, 34999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (25, 'Xiaomi Pad 7 25', 'Computers', 'Tablet', 8, 6, 29999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (26, 'OnePlus Pad 2 26', 'Computers', 'Tablet', 7, 7, 39999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (27, 'Dell 24 Monitor 27', 'Computers', 'Monitor', 3, 8, 13999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (28, 'HP 24 Monitor 28', 'Computers', 'Monitor', 4, 9, 12999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (29, 'Lenovo Legion 5 29', 'Computers', 'Laptop', 5, 10, 89999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (30, 'Asus ROG Strix 30', 'Computers', 'Laptop', 10, 1, 129999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (31, 'Sony Bravia 55 31', 'Electronics', 'TV', 6, 2, 89999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (32, 'Samsung Galaxy Tab 32', 'Computers', 'Tablet', 2, 3, 44999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (33, 'Boat Airdopes 141 33', 'Electronics', 'Headphones', 12, 4, 1299);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (34, 'JBL Flip 6 34', 'Electronics', 'Headphones', 13, 5, 10999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (35, 'Canon Pixma Printer 35', 'Computers', 'Printer', 14, 6, 8999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (36, 'Logitech G502 36', 'Accessories', 'Mouse', 16, 7, 6999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (37, 'Microsoft Surface Mouse 37', 'Accessories', 'Mouse', 17, 8, 4999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (38, 'Apple Magic Mouse 38', 'Accessories', 'Mouse', 1, 9, 7999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (39, 'OnePlus Nord CE 39', 'Mobiles', 'Mobile', 7, 10, 24999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (40, 'Samsung A55 40', 'Mobiles', 'Mobile', 2, 1, 36999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (41, 'Xiaomi 14 41', 'Mobiles', 'Mobile', 8, 2, 69999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (42, 'Realme 13 Pro 42', 'Mobiles', 'Mobile', 19, 3, 29999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (43, 'Vivo T3 43', 'Mobiles', 'Mobile', 20, 4, 21999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (44, 'Acer Nitro V 44', 'Computers', 'Laptop', 11, 5, 74999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (45, 'HP Victus 45', 'Computers', 'Laptop', 4, 6, 84999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (46, 'Lenovo LOQ 46', 'Computers', 'Laptop', 5, 7, 79999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (47, 'Dell G15 47', 'Computers', 'Laptop', 3, 8, 91999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (48, 'Asus TUF Gaming 48', 'Computers', 'Laptop', 10, 9, 89999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (49, 'LG Ultrawide 49', 'Computers', 'Monitor', 9, 10, 31999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (50, 'Samsung Smart Monitor 50', 'Computers', 'Monitor', 2, 1, 36999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (51, 'Sony WH-CH720N 51', 'Electronics', 'Headphones', 6, 2, 9999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (52, 'Boat Nirvana 52', 'Electronics', 'Headphones', 12, 3, 2499);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (53, 'JBL Live 660NC 53', 'Electronics', 'Headphones', 13, 4, 11999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (54, 'Canon EOS R50 54', 'Electronics', 'Camera', 14, 5, 72999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (55, 'Nikon Z30 55', 'Electronics', 'Camera', 15, 6, 65999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (56, 'Generic HDMI Cable', 'Accessories', 'Cable', NULL, 7, 499);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (57, 'Generic USB-C Hub', 'Accessories', 'Hub', NULL, 8, 1499);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (58, 'Unbranded Laptop Stand', 'Accessories', 'Stand', NULL, 9, 999);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (59, 'Generic Webcam Cover', 'Accessories', 'Cover', NULL, NULL, 199);
INSERT INTO products.products (product_id, product_name, category, sub_category, brand_id, supplier_id, price) VALUES (60, 'Generic Phone Tripod', 'Accessories', 'Tripod', NULL, NULL, 799);

INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (1, 8, 1, '2026-01-05', 'Completed', 64798, 0, 64798);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (2, 15, 2, '2026-01-08', 'Completed', 188997, 0, 188997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (3, 22, 3, '2026-01-11', 'Processing', 36997, 1849, 35148);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (4, 29, 4, '2026-01-14', 'Shipped', 219998, 0, 219998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (5, 36, 5, '2026-01-17', 'Cancelled', 129597, 0, 129597);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (6, 43, 6, '2026-01-20', 'Completed', 149997, 7499, 142498);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (7, NULL, 7, '2026-01-23', 'Completed', 289995, 28999, 260996);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (8, 12, 8, '2026-01-26', 'Processing', 209997, 0, 209997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (9, 19, 9, '2026-01-29', 'Shipped', 149037, 7451, 141586);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (10, 26, 10, '2026-02-01', 'Cancelled', 117998, 0, 117998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (11, 33, 11, '2026-02-04', 'Completed', 74997, 0, 74997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (12, 40, 12, '2026-02-07', 'Completed', 75997, 3799, 72198);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (13, 2, 13, '2026-02-10', 'Processing', 172798, 0, 172798);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (14, NULL, 14, '2026-02-13', 'Shipped', 151996, 15199, 136797);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (15, 16, 15, '2026-02-16', 'Cancelled', 62997, 3149, 59848);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (16, 23, 16, '2026-02-19', 'Completed', 2598, 0, 2598);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (17, 30, 17, '2026-02-22', 'Completed', 25917, 0, 25917);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (18, 37, 18, '2026-02-25', 'Processing', 81997, 4099, 77898);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (19, 44, 19, '2026-02-28', 'Shipped', 179998, 0, 179998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (20, 6, 20, '2026-03-03', 'Cancelled', 143997, 0, 143997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (21, NULL, 21, '2026-03-06', 'Completed', 443874, 44387, 399487);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (22, 20, 22, '2026-03-09', 'Completed', 91998, 0, 91998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (23, 27, 23, '2026-03-12', 'Processing', 104997, 0, 104997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (24, 34, 24, '2026-03-15', 'Shipped', 43997, 2199, 41798);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (25, 41, 25, '2026-03-18', 'Cancelled', 280798, 0, 280798);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (26, 3, 26, '2026-03-21', 'Completed', 26997, 0, 26997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (27, 10, 27, '2026-03-24', 'Completed', 154997, 7749, 147248);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (28, NULL, 28, '2026-03-27', 'Processing', 244995, 24499, 220496);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (29, 24, 29, '2026-03-30', 'Shipped', 242997, 0, 242997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (30, 31, 30, '2026-04-02', 'Cancelled', 224997, 11249, 213748);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (31, 38, 31, '2026-04-05', 'Completed', 3998, 0, 3998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (32, 45, 32, '2026-04-08', 'Completed', 149997, 0, 149997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (33, 7, 33, '2026-04-11', 'Processing', 67605, 3380, 64225);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (34, 14, 34, '2026-04-14', 'Shipped', 27998, 0, 27998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (35, NULL, 35, '2026-04-17', 'Cancelled', 156996, 15699, 141297);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (36, 28, 36, '2026-04-20', 'Completed', 184997, 9249, 175748);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (37, 35, 37, '2026-04-23', 'Completed', 64798, 0, 64798);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (38, 42, 38, '2026-04-26', 'Processing', 275997, 0, 275997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (39, 4, 39, '2026-04-29', 'Shipped', 156997, 7849, 149148);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (40, 11, 40, '2026-05-02', 'Cancelled', 57998, 0, 57998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (41, 18, 41, '2026-05-05', 'Completed', 136077, 0, 136077);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (42, NULL, 42, '2026-05-08', 'Completed', 509994, 50999, 458995);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (43, 32, 43, '2026-05-11', 'Processing', 69998, 0, 69998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (44, 39, 44, '2026-05-14', 'Shipped', 269997, 0, 269997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (45, 1, 45, '2026-05-17', 'Cancelled', 195477, 9773, 185704);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (46, 8, 46, '2026-05-20', 'Completed', 49998, 0, 49998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (47, 15, 47, '2026-05-23', 'Completed', 224997, 0, 224997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (48, 22, 48, '2026-05-26', 'Processing', 103997, 5199, 98798);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (49, 29, 49, '2026-05-29', 'Shipped', 226795, 22679, 204116);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (50, 36, 50, '2026-06-01', 'Cancelled', 188997, 0, 188997);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (51, 43, 1, '2026-06-04', 'Completed', 36997, 1849, 35148);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (52, 5, 2, '2026-06-07', 'Completed', 219998, 0, 219998);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (53, 12, 3, '2026-06-10', 'Draft', 0, 0, 0);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (54, 19, 4, '2026-06-13', 'Draft', 0, 0, 0);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (55, 26, 5, '2026-06-16', 'Draft', 0, 0, 0);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (56, 33, 6, '2026-06-19', 'Draft', 0, 0, 0);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (57, 40, 7, '2026-06-22', 'Draft', 0, 0, 0);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (58, 2, 8, '2026-06-25', 'Draft', 0, 0, 0);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (59, 9, 9, '2026-06-28', 'Draft', 0, 0, 0);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (60, 16, 10, '2026-07-01', 'Draft', 0, 0, 0);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (61, 23, 11, '2023-02-14', 'Cancelled', 147198, 0, 147198);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (62, 30, 12, '2023-05-20', 'Cancelled', 129717, 0, 129717);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (63, 37, 13, '2023-08-09', 'Cancelled', 264954, 26495, 238459);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (64, 44, 14, '2023-11-30', 'Cancelled', 2390, 0, 2390);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (65, 6, 15, '2023-06-15', 'Completed', 22077, 0, 22077);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (66, 13, 16, '2023-10-02', 'Completed', 75437, 3771, 71666);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (67, 20, 17, '2024-03-18', 'Cancelled', 165598, 0, 165598);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (68, 27, 18, '2024-09-10', 'Completed', 132477, 0, 132477);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (69, 34, 19, '2024-12-20', 'Completed', 253917, 12695, 241222);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (70, 41, 20, '2025-02-11', 'Completed', 195035, 19503, 175532);
INSERT INTO sales.orders (order_id, cust_id, store_id, order_date, order_status, gross_total, discount_amount, net_total) VALUES (1001, 101, 1, '2026-07-04', 'Completed', 73496, 7349, 66147);

INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (1, 1, 6, 2, 32399);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (2, 2, 11, 3, 62999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (3, 3, 16, 1, 8999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (4, 3, 27, 2, 13999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (5, 4, 21, 2, 109999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (6, 5, 26, 3, 43199);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (7, 6, 31, 1, 89999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (8, 6, 42, 2, 29999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (9, 7, 36, 2, 6999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (10, 7, 47, 3, 91999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (11, 8, 41, 3, 69999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (12, 9, 46, 1, 86399);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (13, 9, 9, 2, 31319);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (14, 10, 3, 2, 58999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (15, 11, 8, 3, 24999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (16, 12, 13, 1, 5999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (17, 12, 24, 2, 34999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (18, 13, 18, 2, 86399);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (19, 14, 23, 3, 46999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (20, 14, 34, 1, 10999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (21, 15, 28, 1, 12999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (22, 15, 39, 2, 24999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (23, 16, 33, 2, 1299);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (24, 17, 38, 3, 8639);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (25, 18, 43, 1, 21999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (26, 18, 6, 2, 29999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (27, 19, 48, 2, 89999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (28, 20, 5, 3, 47999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (29, 21, 10, 1, 60479);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (30, 21, 21, 2, 118799);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (31, 21, 32, 3, 48599);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (32, 22, 15, 2, 45999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (33, 23, 20, 3, 34999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (34, 24, 25, 1, 29999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (35, 24, 36, 2, 6999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (36, 25, 30, 2, 140399);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (37, 26, 35, 3, 8999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (38, 27, 40, 1, 36999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (39, 27, 3, 2, 58999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (40, 28, 45, 2, 84999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (41, 28, 8, 3, 24999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (42, 29, 2, 3, 80999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (43, 30, 7, 1, 64999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (44, 30, 18, 2, 79999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (45, 31, 12, 2, 1999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (46, 32, 17, 3, 49999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (47, 33, 22, 1, 64799);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (48, 33, 33, 2, 1403);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (49, 34, 27, 2, 13999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (50, 35, 32, 3, 44999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (51, 35, 43, 1, 21999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (52, 36, 37, 1, 4999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (53, 36, 48, 2, 89999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (54, 37, 42, 2, 32399);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (55, 38, 47, 3, 91999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (56, 39, 4, 1, 64999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (57, 39, 15, 2, 45999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (58, 40, 9, 2, 28999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (59, 41, 14, 3, 45359);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (60, 42, 19, 1, 39999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (61, 42, 30, 2, 129999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (62, 42, 41, 3, 69999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (63, 43, 24, 2, 34999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (64, 44, 29, 3, 89999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (65, 45, 34, 1, 11879);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (66, 45, 45, 2, 91799);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (67, 46, 39, 2, 24999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (68, 47, 44, 3, 74999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (69, 48, 1, 1, 99999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (70, 48, 12, 2, 1999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (71, 49, 6, 2, 32399);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (72, 49, 17, 3, 53999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (73, 50, 11, 3, 62999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (74, 51, 16, 1, 8999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (75, 51, 27, 2, 13999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (76, 52, 21, 2, 109999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (77, 61, 18, 2, 73599);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (78, 62, 23, 3, 43239);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (79, 63, 28, 1, 11959);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (80, 63, 39, 2, 22999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (81, 63, 2, 3, 68999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (82, 64, 33, 2, 1195);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (83, 65, 38, 3, 7359);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (84, 66, 43, 1, 20239);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (85, 66, 6, 2, 27599);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (86, 67, 48, 2, 82799);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (87, 68, 5, 3, 44159);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (88, 69, 10, 1, 51519);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (89, 69, 21, 2, 101199);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (90, 70, 15, 2, 42319);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (91, 70, 26, 3, 36799);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (92, 1001, 3, 1, 58999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (93, 1001, 36, 2, 6999);
INSERT INTO sales.order_items (order_item_id, order_id, product_id, quantity, unit_price) VALUES (94, 1001, 56, 1, 499);

INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (1, 1, '2026-01-06', 'Credit Card', 'Paid', 64798);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (2, 2, '2026-01-09', 'Debit Card', 'Paid', 188997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (3, 4, '2026-01-15', 'Cash', 'Paid', 219998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (4, 6, '2026-01-21', 'Credit Card', 'Paid', 142498);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (5, 7, '2026-01-24', 'Debit Card', 'Paid', 260996);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (6, 8, '2026-01-27', 'Net Banking', 'Pending', 209997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (7, 9, '2026-01-30', 'Cash', 'Paid', 141586);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (8, 10, '2026-02-02', 'UPI', 'Failed', 117998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (9, 11, '2026-02-05', 'Credit Card', 'Paid', 74997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (10, 12, '2026-02-08', 'UPI', 'Paid', 36099);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (11, 12, '2026-02-08', 'Credit Card', 'Paid', 36099);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (12, 14, '2026-02-14', 'Cash', 'Paid', 136797);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (13, 16, '2026-02-20', 'UPI', 'Paid', 1299);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (14, 16, '2026-02-20', 'Credit Card', 'Paid', 1299);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (15, 17, '2026-02-23', 'Debit Card', 'Paid', 25917);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (16, 18, '2026-02-26', 'Net Banking', 'Pending', 77898);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (17, 19, '2026-03-01', 'Cash', 'Paid', 179998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (18, 20, '2026-03-04', 'UPI', 'Failed', 143997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (19, 21, '2026-03-07', 'Credit Card', 'Paid', 399487);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (20, 22, '2026-03-10', 'Debit Card', 'Paid', 91998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (21, 24, '2026-03-16', 'Cash', 'Paid', 41798);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (22, 26, '2026-03-22', 'Credit Card', 'Paid', 26997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (23, 27, '2026-03-25', 'Debit Card', 'Paid', 147248);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (24, 28, '2026-03-28', 'Net Banking', 'Pending', 220496);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (25, 29, '2026-03-31', 'Cash', 'Paid', 242997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (26, 30, '2026-04-03', 'UPI', 'Failed', 213748);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (27, 31, '2026-04-06', 'Credit Card', 'Paid', 3998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (28, 32, '2026-04-09', 'UPI', 'Paid', 74998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (29, 32, '2026-04-09', 'Credit Card', 'Paid', 74999);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (30, 34, '2026-04-15', 'Cash', 'Paid', 27998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (31, 36, '2026-04-21', 'UPI', 'Paid', 87874);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (32, 36, '2026-04-21', 'Credit Card', 'Paid', 87874);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (33, 37, '2026-04-24', 'Debit Card', 'Paid', 64798);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (34, 38, '2026-04-27', 'Net Banking', 'Pending', 275997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (35, 39, '2026-04-30', 'Cash', 'Paid', 149148);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (36, 40, '2026-05-03', 'UPI', 'Failed', 57998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (37, 41, '2026-05-06', 'Credit Card', 'Paid', 136077);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (38, 42, '2026-05-09', 'Debit Card', 'Paid', 458995);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (39, 44, '2026-05-15', 'Cash', 'Paid', 269997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (40, 46, '2026-05-21', 'Credit Card', 'Paid', 49998);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (41, 47, '2026-05-24', 'Debit Card', 'Paid', 224997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (42, 48, '2026-05-27', 'Net Banking', 'Pending', 98798);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (43, 49, '2026-05-30', 'Cash', 'Paid', 204116);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (44, 50, '2026-06-02', 'UPI', 'Failed', 188997);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (45, 51, '2026-06-05', 'Credit Card', 'Paid', 35148);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (46, 52, '2026-06-08', 'UPI', 'Paid', 109999);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (47, 52, '2026-06-08', 'Credit Card', 'Paid', 109999);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (48, 62, '2023-05-21', 'Debit Card', 'Failed', 129717);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (49, 64, '2023-12-01', 'Cash', 'Failed', 2390);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (50, 65, '2023-06-16', 'UPI', 'Paid', 22077);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (51, 66, '2023-10-03', 'Credit Card', 'Paid', 71666);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (52, 68, '2024-09-11', 'UPI', 'Paid', 66238);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (53, 68, '2024-09-11', 'Credit Card', 'Paid', 66239);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (54, 69, '2024-12-21', 'Cash', 'Paid', 241222);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (55, 70, '2025-02-12', 'UPI', 'Paid', 175532);
INSERT INTO sales.payments (payment_id, order_id, payment_date, payment_method, payment_status, amount) VALUES (56, 1001, '2026-07-05', 'Credit Card', 'Paid', 66147);

INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (1, 1, '2026-01-07', '2026-01-10', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (2, 2, '2026-01-10', '2026-01-13', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (3, 4, '2026-01-16', NULL, 'XpressBees', 'In Transit');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (4, 6, '2026-01-22', '2026-01-25', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (5, 6, '2026-01-23', '2026-01-26', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (6, 7, '2026-01-25', '2026-01-28', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (7, 9, '2026-01-31', NULL, 'XpressBees', 'Shipped');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (8, 11, '2026-02-06', '2026-02-09', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (9, 12, '2026-02-09', '2026-02-12', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (10, 12, '2026-02-10', '2026-02-13', 'Ecom Express', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (11, 14, '2026-02-15', NULL, 'XpressBees', 'In Transit');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (12, 16, '2026-02-21', '2026-02-24', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (13, 17, '2026-02-24', '2026-02-27', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (14, 19, '2026-03-02', NULL, 'XpressBees', 'Shipped');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (15, 21, '2026-03-08', '2026-03-11', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (16, 22, '2026-03-11', '2026-03-14', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (17, 24, '2026-03-17', NULL, 'XpressBees', 'In Transit');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (18, 26, '2026-03-23', '2026-03-26', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (19, 27, '2026-03-26', NULL, 'DTDC', 'Returned');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (20, 29, '2026-04-01', NULL, 'XpressBees', 'Shipped');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (21, 31, '2026-04-07', '2026-04-10', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (22, 32, '2026-04-10', '2026-04-13', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (23, 34, '2026-04-16', NULL, 'XpressBees', 'In Transit');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (24, 36, '2026-04-22', NULL, 'Delhivery', 'Returned');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (25, 37, '2026-04-25', '2026-04-28', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (26, 39, '2026-05-01', NULL, 'XpressBees', 'Shipped');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (27, 41, '2026-05-07', '2026-05-10', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (28, 42, '2026-05-10', '2026-05-13', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (29, 42, '2026-05-11', '2026-05-14', 'Ecom Express', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (30, 44, '2026-05-16', NULL, 'XpressBees', 'In Transit');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (31, 46, '2026-05-22', '2026-05-25', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (32, 47, '2026-05-25', '2026-05-28', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (33, 49, '2026-05-31', NULL, 'XpressBees', 'Shipped');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (34, 51, '2026-06-06', '2026-06-09', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (35, 52, '2026-06-09', '2026-06-12', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (36, 65, '2023-06-17', '2023-06-20', 'BlueDart', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (37, 66, '2023-10-04', '2023-10-07', 'Delhivery', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (38, 66, '2023-10-05', '2023-10-08', 'DTDC', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (39, 68, '2024-09-12', '2024-09-15', 'Ecom Express', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (40, 69, '2024-12-22', '2024-12-25', 'XpressBees', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (41, 70, '2025-02-13', '2025-02-16', 'BlueDart', 'Delivered');
INSERT INTO sales.shipments (shipment_id, order_id, shipment_date, delivery_date, carrier, shipment_status) VALUES (42, 1001, '2026-07-06', '2026-07-09', 'Delhivery', 'Delivered');

INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (1, 4637, '2026-09-01 11:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (2, 7774, '2026-09-01 12:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (3, 10911, '2026-09-01 13:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (4, 14048, '2026-09-01 14:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (5, 17185, '2026-09-01 15:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (6, 20322, '2026-09-01 16:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (7, 3459, '2026-09-01 17:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (8, 6596, '2026-09-01 18:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (9, 9733, '2026-09-01 19:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (10, 12870, '2026-09-01 20:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (11, 16007, '2026-09-01 21:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (12, 19144, '2026-09-01 22:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (13, 2281, '2026-09-01 23:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (14, 5418, '2026-09-02 00:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (15, 8555, '2026-09-02 01:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (16, 11692, '2026-09-02 02:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (17, 14829, '2026-09-02 03:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (18, 17966, '2026-09-02 04:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (19, 21103, '2026-09-02 05:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (20, 4240, '2026-09-02 06:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (21, 7377, '2026-09-02 07:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (22, 10514, '2026-09-02 08:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (23, 13651, '2026-09-02 09:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (24, 16788, '2026-09-02 10:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (25, 19925, '2026-09-02 11:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (26, 3062, '2026-09-02 12:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (27, 6199, '2026-09-02 13:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (28, 9336, '2026-09-02 14:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (29, 12473, '2026-09-02 15:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (30, 15610, '2026-09-02 16:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (31, 18747, '2026-09-02 17:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (32, 1884, '2026-09-02 18:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (33, 5021, '2026-09-02 19:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (34, 8158, '2026-09-02 20:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (35, 11295, '2026-09-02 21:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (36, 14432, '2026-09-02 22:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (37, 17569, '2026-09-02 23:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (38, 20706, '2026-09-03 00:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (39, 3843, '2026-09-03 01:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (40, 6980, '2026-09-03 02:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (101, 25000, '2026-09-01 15:00:00');
INSERT INTO customers.wallets (cust_id, balance, last_updated) VALUES (202, 12000, '2026-09-01 20:00:00');

INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (4, 13, 1000, '2026-08-02 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (7, 20, 1500, '2026-08-03 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (10, 27, 2000, '2026-08-04 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (13, 34, 2500, '2026-08-05 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (16, 1, 3000, '2026-08-06 09:00:00', 'Failed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (19, 8, 3500, '2026-08-07 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (22, 15, 4000, '2026-08-08 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (25, 22, 500, '2026-08-09 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (28, 29, 1000, '2026-08-10 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (31, 36, 1500, '2026-08-11 09:00:00', 'Failed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (34, 3, 2000, '2026-08-12 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (37, 10, 2500, '2026-08-13 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (40, 17, 3000, '2026-08-14 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (3, 24, 3500, '2026-08-15 09:00:00', 'Completed');
INSERT INTO finance.transfer_log (from_account, to_account, amount, transferred_at, status) VALUES (202, 101, 2000, '2026-08-20 11:30:00', 'Completed');

INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (1, 1, '2026-01-06', 'Electricity', 8977);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (2, 2, '2026-01-11', 'Salaries', 9954);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (3, 3, '2026-01-16', 'Maintenance', 10931);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (4, 4, '2026-01-21', 'Marketing', 11908);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (5, 5, '2026-01-26', 'Rent', 12885);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (6, 6, '2026-01-31', 'Electricity', 13862);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (7, 7, '2026-02-05', 'Salaries', 14839);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (8, 8, '2026-02-10', 'Maintenance', 15816);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (9, 9, '2026-02-15', 'Marketing', 16793);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (10, 10, '2026-02-20', 'Rent', 17770);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (11, 11, '2026-02-25', 'Electricity', 18747);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (12, 12, '2026-03-02', 'Salaries', 19724);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (13, 13, '2026-03-07', 'Maintenance', 20701);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (14, 14, '2026-03-12', 'Marketing', 21678);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (15, 15, '2026-03-17', 'Rent', 22655);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (16, 16, '2026-03-22', 'Electricity', 23632);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (17, 17, '2026-03-27', 'Salaries', 24609);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (18, 18, '2026-04-01', 'Maintenance', 25586);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (19, 19, '2026-04-06', 'Marketing', 26563);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (20, 20, '2026-04-11', 'Rent', 27540);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (21, 21, '2026-04-16', 'Electricity', 28517);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (22, 22, '2026-04-21', 'Salaries', 29494);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (23, 23, '2026-04-26', 'Maintenance', 30471);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (24, 24, '2026-05-01', 'Marketing', 31448);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (25, 25, '2026-05-06', 'Rent', 32425);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (26, 26, '2026-05-11', 'Electricity', 33402);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (27, 27, '2026-05-16', 'Salaries', 34379);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (28, 28, '2026-05-21', 'Maintenance', 35356);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (29, 29, '2026-05-26', 'Marketing', 36333);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (30, 30, '2026-05-31', 'Rent', 37310);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (31, 31, '2026-06-05', 'Electricity', 38287);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (32, 32, '2026-06-10', 'Salaries', 39264);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (33, 33, '2026-06-15', 'Maintenance', 40241);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (34, 34, '2026-06-20', 'Marketing', 41218);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (35, 35, '2026-06-25', 'Rent', 42195);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (36, 36, '2026-06-30', 'Electricity', 43172);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (37, 37, '2026-07-05', 'Salaries', 44149);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (38, 38, '2026-07-10', 'Maintenance', 45126);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (39, 39, '2026-07-15', 'Marketing', 46103);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (40, 40, '2026-07-20', 'Rent', 47080);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (41, 41, '2026-07-25', 'Electricity', 48057);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (42, 42, '2026-07-30', 'Salaries', 49034);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (43, 43, '2026-08-04', 'Maintenance', 50011);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (44, 44, '2026-08-09', 'Marketing', 50988);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (45, 45, '2026-08-14', 'Rent', 51965);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (46, 1, '2026-08-19', 'Electricity', 52942);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (47, 2, '2026-08-24', 'Salaries', 53919);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (48, 3, '2026-08-29', 'Maintenance', 54896);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (49, 4, '2026-09-03', 'Marketing', 55873);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (50, 5, '2026-09-08', 'Rent', 56850);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (51, 6, '2026-09-13', 'Electricity', 57827);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (52, 7, '2026-09-18', 'Salaries', 58804);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (53, 8, '2026-09-23', 'Maintenance', 59781);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (54, 9, '2026-09-28', 'Marketing', 60758);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (55, 10, '2026-10-03', 'Rent', 61735);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (56, 11, '2026-10-08', 'Electricity', 62712);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (57, 12, '2026-10-13', 'Salaries', 63689);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (58, 13, '2026-10-18', 'Maintenance', 64666);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (59, 14, '2026-10-23', 'Marketing', 65643);
INSERT INTO finance.expenses (expense_id, store_id, expense_date, expense_type, amount) VALUES (60, 15, '2026-10-28', 'Rent', 66620);

-- finance.revenue_summary is DERIVED from sales.orders (a deliberate denormalization).
-- Only live orders count: Cancelled and Draft orders are excluded.
-- It must be refreshed whenever sales.orders changes.
INSERT INTO finance.revenue_summary (summary_month, order_count, gross_revenue, total_discount, net_revenue)
SELECT date_trunc('month', order_date)::date, COUNT(*), SUM(gross_total), SUM(discount_amount), SUM(net_total)
FROM sales.orders
WHERE order_status NOT IN ('Cancelled', 'Draft')
GROUP BY 1
ORDER BY 1;
