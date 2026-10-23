package com.example.OrderService.dto;

import com.example.OrderService.enums.OrderStatus;
import lombok.*;
import java.time.Instant;
import java.util.List;

@Getter
@AllArgsConstructor
@NoArgsConstructor
@Builder
public class OrderHistoryDTO {
    private Long orderId;
    private Long userId;
    private OrderStatus status;
    private Instant createdAt;
    private List<OrderItemResponseDTO> items;
    private double totalAmount;
}
