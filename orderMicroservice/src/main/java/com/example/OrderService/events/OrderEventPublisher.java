package com.example.OrderService.events;

import com.example.OrderService.enums.OrderStatus;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.context.Context;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import software.amazon.awssdk.services.sqs.SqsAsyncClient;
import software.amazon.awssdk.services.sqs.model.MessageAttributeValue;

import java.util.HashMap;
import java.util.Map;

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventPublisher {

    // Use raw SqsAsyncClient instead of SqsTemplate.
    // SqsTemplate auto-adds a JavaType message attribute pointing to this inner class.
    // notification-worker (different JAR) can't load that class → deserialization fails.
    // Raw sendMessage with explicit messageAttributes lets us carry the W3C traceparent.
    private final SqsAsyncClient sqsAsyncClient;
    private final ObjectMapper objectMapper;

    @Value("${SQS_QUEUE_URL}")
    private String queueUrl;

    public void publishOrderPlaced(Long orderId, OrderStatus status, Long userId) {
        try {
            String payload = objectMapper.writeValueAsString(
                new OrderEventMessage(orderId, status.name(), userId)
            );

            // M16: inject W3C traceparent into SQS message attributes so
            // notification-worker can restore the trace context and link its
            // consumer span to this order-service span. The OTel propagator
            // writes "traceparent" (and optionally "tracestate") as String attributes.
            Map<String, MessageAttributeValue> traceAttrs = new HashMap<>();
            GlobalOpenTelemetry.getPropagators().getTextMapPropagator()
                .inject(Context.current(), traceAttrs, (carrier, key, value) ->
                    carrier.put(key, MessageAttributeValue.builder()
                        .dataType("String")
                        .stringValue(value)
                        .build()));

            sqsAsyncClient.sendMessage(req -> req
                .queueUrl(queueUrl)
                .messageBody(payload)
                .messageAttributes(traceAttrs)
            ).join();
            log.info("Published order event: orderId={} status={}", orderId, status);
        } catch (Exception e) {
            log.error("Failed to publish order event for orderId={}: {}", orderId, e.getMessage(), e);
        }
    }

    public record OrderEventMessage(Long orderId, String status, Long userId) {}
}
