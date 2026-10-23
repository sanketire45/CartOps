package com.example.OrderService.services;

import com.example.OrderService.dto.CreateOrderResponseDTO;
import com.example.OrderService.dto.OrderHistoryDTO;
import com.example.OrderService.dto.OrderRequestDTO;
import org.springframework.stereotype.Component;
import java.util.List;

@Component
public interface IOrderService {

    CreateOrderResponseDTO createOrder(OrderRequestDTO requestDTO);
    List<OrderHistoryDTO> getOrdersByUserId(Long userId);
}
