package com.example.OrderService.dto;
import com.example.OrderService.enums.OrderStatus;
import lombok.*;
import org.springframework.stereotype.Service;

@Getter
@AllArgsConstructor
@NoArgsConstructor
@Builder

public class CreateOrderResponseDTO {
    private Long orderId;
    private OrderStatus status;
}
