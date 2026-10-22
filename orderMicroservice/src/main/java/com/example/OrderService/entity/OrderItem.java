package com.example.OrderService.entity;

import jakarta.persistence.Entity;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import lombok.*;

@Getter
@Setter
@AllArgsConstructor
@NoArgsConstructor
@Builder
@Entity

public class OrderItem extends BaseEntity{
    private Long productId;
    private int quantity;
    private double pricePerUnit;
    private double totalPrice;

    @ManyToOne
    @JoinColumn(name = "order_id")
    private Order order;
}
