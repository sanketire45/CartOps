package com.example.OrderService.clients;

import com.example.OrderService.dto.ProductDTO;
import org.springframework.boot.web.client.RestTemplateBuilder;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

@Component
public class ProductServiceClient {

    private final RestTemplate restTemplate;

    public ProductServiceClient(RestTemplate restTemplate) {
        this.restTemplate = restTemplate;
    }

    public ProductDTO getProductById(Long productId){
        // "ECOMMERCESPRING" is the spring.application.name in Eureka
        // LoadBalancer resolves it to actual http://192.168.x.x:8081
        String url = "http://ECOMMERCESPRING/api/products/" + productId;

        ResponseEntity<ProductDTO> response = restTemplate.getForEntity(url, ProductDTO.class);
        return response.getBody();
    }
}
