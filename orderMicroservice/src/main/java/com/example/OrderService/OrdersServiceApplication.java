package com.example.OrderService;

import io.github.cdimascio.dotenv.Dotenv;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.client.discovery.EnableDiscoveryClient;
import org.springframework.cloud.openfeign.EnableFeignClients;
import org.springframework.data.jpa.repository.config.EnableJpaAuditing;

@SpringBootApplication
@EnableJpaAuditing
@EnableDiscoveryClient
//With this annotation, we enable component scanning for interfaces that declare they are Feign clients.
//Feign is the caller, Eureka is the phone book, and Spring Cloud LoadBalancer is the thing that picks the actual number from the phone book.
@EnableFeignClients
public class OrdersServiceApplication {

	public static void main(String[] args) {

		//Dotenv dotenv = Dotenv.configure().ignoreIfMissing().load();

		//dotenv.entries().forEach(dotenvEntry -> System.setProperty(dotenvEntry.getKey(), dotenvEntry.getValue()) );
		SpringApplication.run(OrdersServiceApplication.class, args);
	}

}

//Postman → order-service (7878)
//             │  Feign client asks Eureka: "where is ECOMMERCESPRING?"
//		▼
//Eureka (8761) answers with product container's address
//		│  LoadBalancer picks the instance
//             ▼
//product-service (8080)  → returns ProductDTO{price:7999}
//		│
//		▼
//order-service computes totals → INSERT orders + order_item → order_db (MySQL)