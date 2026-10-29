-- Flyway migration V1 — notifications table
--
-- One row per processed order event.
-- order_id is UNIQUE — idempotency guard.
-- If the same orderId arrives twice (SQS at-least-once delivery),
-- the INSERT fails on the unique constraint → worker skips it → deletes the duplicate message.

CREATE TABLE IF NOT EXISTS notifications (
    id         BIGINT       NOT NULL AUTO_INCREMENT,
    order_id   BIGINT       NOT NULL,
    status     VARCHAR(50)  NOT NULL DEFAULT 'SENT',
    created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_order_id (order_id)   -- idempotency: one notification per order
);
