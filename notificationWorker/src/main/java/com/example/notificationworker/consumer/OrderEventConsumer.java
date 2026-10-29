package com.example.notificationworker.consumer;

import com.example.notificationworker.service.NotificationService;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.awspring.cloud.sqs.annotation.SqsListener;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventConsumer {

    private final NotificationService notificationService;
    private final ObjectMapper objectMapper;

    // String payload bypasses Spring Cloud AWS JavaType resolution — we deserialize manually.
    // No Acknowledgement param: default ON_SUCCESS mode auto-acks after method returns.
    // Re-throw on failure so the message stays in SQS and retries.
    @SqsListener("${SQS_QUEUE_URL}")
    public void onOrderEvent(String payload) {
        try {
            OrderEventMessage message = objectMapper.readValue(payload, OrderEventMessage.class);
            log.info("Received order event: orderId={} status={} userId={}", message.orderId(), message.status(), message.userId());
            notificationService.processOrderEvent(message.orderId());
            log.info("Processed order event for orderId={}", message.orderId());
        } catch (Exception e) {
            log.error("Failed to process message — will retry: {}", payload, e);
            throw new RuntimeException(e);
        }
    }

    public record OrderEventMessage(Long orderId, String status, Long userId) {}
}
