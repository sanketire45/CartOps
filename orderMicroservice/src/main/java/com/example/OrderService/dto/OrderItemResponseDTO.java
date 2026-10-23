package com.example.OrderService.dto;

import lombok.*;

@Getter
@AllArgsConstructor
@NoArgsConstructor
@Builder
public class OrderItemResponseDTO {
    private Long productId;
    private int quantity;
    private double pricePerUnit;
    private double totalPrice;
}
