package com.example.notificationworker.repository;

import com.example.notificationworker.entity.Notification;
import org.springframework.data.jpa.repository.JpaRepository;

public interface NotificationRepository extends JpaRepository<Notification, Long> {
    boolean existsByOrderId(Long orderId);
}
