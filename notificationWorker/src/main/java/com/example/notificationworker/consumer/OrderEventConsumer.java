package com.example.notificationworker.consumer;

import com.example.notificationworker.service.NotificationService;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.awspring.cloud.sqs.annotation.SqsListener;
import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.StatusCode;
import io.opentelemetry.context.Context;
import io.opentelemetry.context.Scope;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.messaging.Message;
import org.springframework.stereotype.Component;

@Component
@RequiredArgsConstructor
@Slf4j
public class OrderEventConsumer {

    private final NotificationService notificationService;
    private final ObjectMapper objectMapper;

    // M16: Message<String> gives access to headers (SQS message attributes) alongside
    // the body. Spring Cloud AWS 3.x maps SQS MessageAttributeValue entries to
    // Spring MessageHeaders, so "traceparent" injected by order-service arrives here
    // as a plain String header value.
    //
    // No Acknowledgement param: default ON_SUCCESS mode auto-acks after method returns.
    // Re-throw on failure so the message stays in SQS and retries.
    @SqsListener("${SQS_QUEUE_URL}")
    public void onOrderEvent(Message<String> message) {
        // Restore the order-service trace context from SQS message attributes.
        // Without this, notification-worker creates an orphan root span and the
        // trace is broken at the async boundary — you lose the full call graph.
        Context parentCtx = GlobalOpenTelemetry.getPropagators().getTextMapPropagator()
            .extract(Context.current(), message.getHeaders(), (carrier, key) -> {
                Object v = carrier.get(key);
                return v != null ? v.toString() : null;
            });

        // CONSUMER kind signals "this span was triggered by a message from a queue"
        // — Tempo's Service Graph view uses SpanKind to draw the async edge between
        // order-service and notification-worker.
        Span span = GlobalOpenTelemetry.getTracer("notification-worker")
            .spanBuilder("processOrderEvent")
            .setParent(parentCtx)
            .setSpanKind(SpanKind.CONSUMER)
            .setAttribute("messaging.system", "aws_sqs")
            .startSpan();

        String payload = message.getPayload();
        try (Scope scope = span.makeCurrent()) {
            OrderEventMessage event = objectMapper.readValue(payload, OrderEventMessage.class);
            log.info("Received order event: orderId={} status={} userId={}",
                event.orderId(), event.status(), event.userId());
            notificationService.processOrderEvent(event.orderId());
            log.info("Processed order event for orderId={}", event.orderId());
            span.setStatus(StatusCode.OK);
        } catch (Exception e) {
            span.recordException(e);
            span.setStatus(StatusCode.ERROR, e.getMessage());
            log.error("Failed to process message — will retry: {}", payload, e);
            throw new RuntimeException(e);
        } finally {
            span.end();
        }
    }

    public record OrderEventMessage(Long orderId, String status, Long userId) {}
}
