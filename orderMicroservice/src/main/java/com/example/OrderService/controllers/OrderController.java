  package com.example.OrderService.controllers;

import com.example.OrderService.dto.CreateOrderResponseDTO;
import com.example.OrderService.dto.OrderHistoryDTO;
import com.example.OrderService.dto.OrderRequestDTO;
import com.example.OrderService.services.IOrderService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import java.util.List;

@RestController
@RequestMapping("/api/orders")
public class OrderController {
    private final IOrderService orderService;

    public OrderController(IOrderService orderService){
        this.orderService = orderService;
    }

    @PostMapping
    public ResponseEntity<CreateOrderResponseDTO> createOrder(@RequestBody OrderRequestDTO request){
        CreateOrderResponseDTO order = orderService.createOrder(request);
        return ResponseEntity.ok(order);
    }

    @GetMapping("/{userId}")
    public ResponseEntity<List<OrderHistoryDTO>> getOrdersByUserId(@PathVariable Long userId) {
        return ResponseEntity.ok(orderService.getOrdersByUserId(userId));
    }
}

