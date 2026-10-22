package com.example.OrderService.services;

import com.example.OrderService.dto.CreateOrderResponseDTO;
import com.example.OrderService.dto.OrderRequestDTO;
import org.springframework.stereotype.Component;

@Component
public interface IOrderService {

    CreateOrderResponseDTO createOrder(OrderRequestDTO requestDTO);

}
