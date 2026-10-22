package com.example.OrderService.dto;
import lombok.*;
import java.util.List;

@Getter
@Setter
@AllArgsConstructor
@NoArgsConstructor
@Builder

public class OrderRequestDTO {
    private Long userId;
    private List<OrderItemDTO> items;

}
