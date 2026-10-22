package com.example.OrderService.configuration;

import org.springframework.cloud.client.loadbalancer.LoadBalanced;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.client.RestTemplate;

@Configuration
public class AppConfig {

    @Bean
    @LoadBalanced       // @LoadBalanced tells Spring: resolve service names via Eureka
    // Without this, "PRODUCT-SERVICE" is just a string — not a real host
    public RestTemplate restTemplate() {return new RestTemplate();}

}

//Adding LoadBalanced on a RestTemplate enables client-side load balancing.
//it intercept the local service names and resolve them into actual instance urls from Eureka.

//Eureka client > PRODUCT_SERVICE

//PRODUCT_SERVICE > [10.0.0.12:8080, 10.0.0.13:8080, 10.0.0.16:8080]

//restTeamplate.goForObject("http://PRODUCT-SERVICE/api/products/1", ProductDTO.class);

//PRODUCT_SERVICE > NOT A DNS name

//@LoadBalanced annotation contacts Eureka > fetch the available instances > picks one

//restTeamplate.getForObject("http://10.0.13:8080/api/products/1", ProductDTO.class);