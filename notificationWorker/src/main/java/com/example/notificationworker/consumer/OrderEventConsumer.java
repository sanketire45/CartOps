package com.example.notificationworker.consumer;

import com.example.notificationworker.service.NotificationService;
import io.awspring.cloud.sqs.annotation.SqsListener;
import io.awspring.cloud.sqs.listener.acknowledgement.Acknowledgement;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventConsumer {

    private final NotificationService notificationService;

    // @SqsListener polls the queue continuously (long-polling, 20s wait).
    // acknowledgement-mode=MANUAL means we control when the message is deleted.
    // The message is NOT deleted from SQS until acknowledgement.acknowledge() is called.
    //
    // FLOW:
    //   1. SQS delivers message → visibility timeout starts (60s from sqs.tf)
    //   2. notificationService.processOrderEvent() runs (idempotent)
    //   3. acknowledge() → SQS deletes the message permanently
    //
    // If step 2 throws and we never acknowledge:
    //   → visibility timeout expires → SQS re-delivers to another pod
    //   → after 3 attempts → moves to DLQ

    @SqsListener("${SQS_QUEUE_URL}")
    public void onOrderEvent(OrderEventMessage message, Acknowledgement acknowledgement) {
        log.info("Received order event: orderId={}", message.orderId());
        try {
            notificationService.processOrderEvent(message.orderId());
            acknowledgement.acknowledge();  // delete from SQS only on success
            log.info("Acknowledged message for orderId={}", message.orderId());
        } catch (Exception e) {
            // Do NOT acknowledge — SQS will re-deliver up to maxReceiveCount times,
            // then move to DLQ. The CloudWatch alarm fires when DLQ depth > 0.
            log.error("Failed to process orderId={} — not acknowledging, will retry", message.orderId(), e);
        }
    }

    // SQS message payload — order-service publishes this as JSON
    public record OrderEventMessage(Long orderId, String status, Long userId) {}
}
