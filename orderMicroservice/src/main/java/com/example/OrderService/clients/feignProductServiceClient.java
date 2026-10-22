package com.example.OrderService.clients;

import com.example.OrderService.dto.ProductDTO;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.data.repository.query.Param;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestMethod;

//to work feign we have to delcare the interface only
////Feign is the caller, Eureka is the phone book, and Spring Cloud LoadBalancer is the thing that picks the actual number from the phone book.
@FeignClient(value = "ECOMMERCESPRING")
public interface feignProductServiceClient {

    @GetMapping("/api/products/{id}")
    ProductDTO getProductById(@PathVariable("id") Long productId);

}
