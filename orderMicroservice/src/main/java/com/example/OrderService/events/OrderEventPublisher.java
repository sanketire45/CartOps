package com.example.OrderService.events;

import com.example.OrderService.enums.OrderStatus;
import io.awspring.cloud.sqs.operations.SqsTemplate;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventPublisher {

    private final SqsTemplate sqsTemplate;

    @Value("${SQS_QUEUE_URL}")
    private String queueUrl;

    // Called after order is saved to DB. Fire-and-forget — if SQS is temporarily
    // unavailable the order is still created; notification-worker will retry via DLQ.
    public void publishOrderPlaced(Long orderId, OrderStatus status, Long userId) {
        OrderEventMessage message = new OrderEventMessage(orderId, status.name(), userId);
        sqsTemplate.send(queueUrl, message);
        log.info("Published order event: orderId={} status={}", orderId, status);
    }

    public record OrderEventMessage(Long orderId, String status, Long userId) {}
}
