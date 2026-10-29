package com.example.notificationworker.consumer;

import com.example.notificationworker.service.NotificationService;
import com.fasterxml.jackson.databind.ObjectMapper;
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
    private final ObjectMapper objectMapper;

    // Receives the raw JSON string to avoid Spring Cloud AWS trying to resolve
    // the publisher's JavaType attribute (com.example.OrderService.events.OrderEventPublisher$OrderEventMessage)
    // which doesn't exist on this classpath. We own our own deserialization here.
    @SqsListener("${SQS_QUEUE_URL}")
    public void onOrderEvent(String payload, Acknowledgement acknowledgement) {
        try {
            OrderEventMessage message = objectMapper.readValue(payload, OrderEventMessage.class);
            log.info("Received order event: orderId={} status={} userId={}", message.orderId(), message.status(), message.userId());
            notificationService.processOrderEvent(message.orderId());
            acknowledgement.acknowledge();
            log.info("Acknowledged message for orderId={}", message.orderId());
        } catch (Exception e) {
            log.error("Failed to process message — not acknowledging, will retry: {}", payload, e);
        }
    }

    public record OrderEventMessage(Long orderId, String status, Long userId) {}
}
