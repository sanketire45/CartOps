package com.example.notificationworker.service;

import com.example.notificationworker.entity.Notification;
import com.example.notificationworker.repository.NotificationRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@RequiredArgsConstructor
@Slf4j
public class NotificationService {

    private final NotificationRepository notificationRepository;

    @Transactional
    public void processOrderEvent(Long orderId) {
        // IDEMPOTENCY CHECK — SQS Standard queues deliver at-least-once.
        // A message can arrive twice (e.g. worker crashed after processing but before deleting).
        // existsByOrderId() is the fast path. The UNIQUE constraint in the DB is the hard guard.
        if (notificationRepository.existsByOrderId(orderId)) {
            log.warn("Duplicate SQS delivery for orderId={} — skipping", orderId);
            return;
        }

        try {
            Notification notification = Notification.builder()
                    .orderId(orderId)
                    .status("SENT")
                    .build();

            notificationRepository.save(notification);
            log.info("Notification saved for orderId={}", orderId);

            // In production: send email/SMS/push here before saving,
            // or use the outbox table to guarantee delivery.

        } catch (DataIntegrityViolationException e) {
            // Race condition: two pods processed the same message simultaneously.
            // The UNIQUE constraint rejected the second INSERT — safe to ignore.
            log.warn("Concurrent duplicate for orderId={} — already processed", orderId);
        }
    }
}
