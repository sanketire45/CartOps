package com.example.OrderService.services;

import com.example.OrderService.clients.ProductServiceClient;
import com.example.OrderService.clients.feignProductServiceClient;
import com.example.OrderService.dto.CreateOrderResponseDTO;
import com.example.OrderService.dto.OrderItemDTO;
import com.example.OrderService.dto.OrderRequestDTO;
import com.example.OrderService.dto.ProductDTO;
import com.example.OrderService.entity.Order;
import com.example.OrderService.entity.OrderItem;
import com.example.OrderService.mapper.OrderItemMapper;
import com.example.OrderService.mapper.OrderMapper;
import com.example.OrderService.repository.OrderRepository;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
@Component
 
public class OrderService implements IOrderService{

    private final OrderRepository orderRepository;
    //private final ProductServiceClient productServiceClient;
    private final feignProductServiceClient feignProductServiceClient;

    public OrderService(OrderRepository orderRepository, feignProductServiceClient feignProductServiceClient){
        this.orderRepository = orderRepository;
        this.feignProductServiceClient = feignProductServiceClient;
    }

    @Override
    public CreateOrderResponseDTO createOrder(OrderRequestDTO request) {
        //Persist the order in order table > OrderRequestDTo > OrderEntity
       Order order = OrderMapper.toEntity(request);

       List<OrderItem> items = new ArrayList<>();

       for(OrderItemDTO itemDTO : request.getItems()){
           //fetch the product details for every item
           ProductDTO product = feignProductServiceClient.getProductById(itemDTO.getProductId());
           double pricePerUnit = product.getPrice();
           double totalPrice = pricePerUnit * itemDTO.getQuantity();

           OrderItem item = OrderItemMapper.OrderItemRequestDTOtoOrderItemEntity(
                   itemDTO,
                   order,
                   pricePerUnit,
                   totalPrice
           );

           items.add(item);
       }

       order.setItems(items);
       Order CreatedOrder = orderRepository.save(order);

       return OrderMapper.toCreateOrderResponseDTO(CreatedOrder);

    }
}
