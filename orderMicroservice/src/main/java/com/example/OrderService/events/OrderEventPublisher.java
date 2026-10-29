package com.example.OrderService.events;

import com.example.OrderService.enums.OrderStatus;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventPublisher {

    // Use raw SqsAsyncClient instead of SqsTemplate.
    // SqsTemplate auto-adds a JavaType message attribute pointing to this inner class.
    // notification-worker (different JAR) can't load that class → deserialization fails.
    // Raw sendMessage sends only the JSON body with zero message attributes.
    private final SqsAsyncClient sqsAsyncClient;
    private final ObjectMapper objectMapper;

    @Value("${SQS_QUEUE_URL}")
    private String queueUrl;

    public void publishOrderPlaced(Long orderId, OrderStatus status, Long userId) {
        try {
            String payload = objectMapper.writeValueAsString(
                new OrderEventMessage(orderId, status.name(), userId)
            );
            sqsAsyncClient.sendMessage(req -> req
                .queueUrl(queueUrl)
                .messageBody(payload)
            ).join();
            log.info("Published order event: orderId={} status={}", orderId, status);
        } catch (Exception e) {
            log.error("Failed to publish order event for orderId={}: {}", orderId, e.getMessage(), e);
        }
    }

    public record OrderEventMessage(Long orderId, String status, Long userId) {}
}
