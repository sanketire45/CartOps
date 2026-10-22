-- Runs automatically on FIRST MySQL startup (empty data dir), via
-- the image's /docker-entrypoint-initdb.d hook. Creates both schemas
-- the microservices need: product/category -> ecommerce_db, order -> order_db.
CREATE DATABASE IF NOT EXISTS ecommerce_db;
CREATE DATABASE IF NOT EXISTS order_db;
