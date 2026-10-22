package com.example.EurekaApplication.EurekaApplication;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.cloud.netflix.eureka.server.EnableEurekaServer;

@SpringBootApplication
@EnableEurekaServer

public class EurekaApplication {

	public static void main(String[] args) {
		SpringApplication.run(EurekaApplication.class, args);
	}

}

/*
PART 2: FULL STORY OF EUREKA, FEIGN, DISCOVERY, CACHE, HEARTBEAT, AND HOW EVERYTHING WORKS TOGETHER

I have three services:
- product-service
- order-service
- eureka-server

Eureka-server is the central registry.
Its job is to keep the list of running services in memory.
It does not store the registry in a database.

Each service that wants to take part in discovery includes the Eureka client starter.
That means the service becomes a Eureka client.

So when order-service starts:
- it registers itself with Eureka
- it sends its service name
- it sends its current address like host and port
- it keeps sending heartbeat signals every 30 seconds by default to say "I am still alive"

The heartbeat is only a life signal.
It does not rename the service.
It does not update the service name.
It does not magically change config.
If I change spring.application.name, I normally need to restart the service so it registers again with the new name.

The service name is the logical name.
Example:
product-service

That name is not the real network address.
It is just the friendly service ID.
Eureka stores the current live address behind that name.

When order-service wants to call product-service:
- it does not hardcode localhost:8081
- it calls a Feign interface
- Feign works with Spring Cloud discovery and load balancing to resolve the service name
- Eureka gives the live instance information from the registry
- then order-service sends the HTTP request directly to that product instance

So Eureka is not the thing that carries the business request.
It is only the registry / lookup system.
The real API call goes directly from order-service to product-service.

Feign is the clean client I use for this.
With Feign, I create an interface and annotate it with @FeignClient.

Example idea:
@FeignClient(name = "product-service")

This means:
- do not treat product-service as a fixed URL
- treat it as a service name
- find its live instance through discovery
- then call it for me

Feign does this by creating a proxy in the background.
When I call a method on the interface, Feign turns that method call into a real HTTP request.
Feign is the caller, and the discovery/load-balancer layer helps resolve the actual live service instance behind the name.

So the flow is:
1) product-service starts
2) product-service registers itself in Eureka
3) order-service starts
4) order-service also registers itself in Eureka
5) order-service keeps a local in-memory copy of the registry
6) that local copy lives inside the JVM memory of the order-service process
7) by default, the registry copy is refreshed every 30 seconds
8) Feign uses the discovery information to find the correct live instance
9) order-service sends the request directly to product-service

This local cache exists so the app does not ask Eureka for every single request.
That makes calls faster and reduces network traffic.

Eureka server also keeps things in memory.
There is no database behind it for the registry.

If a service stops sending heartbeats, Eureka assumes it may be dead.
After the expiration time, the entry can be removed.
But Eureka also has self-preservation mode.
That is a safety mode that tries not to remove too many services too quickly if there is a temporary network problem.

So the main ideas are:

- Eureka server = keeps the registry list in memory
- Eureka client = registers the service and fetches registry data
- local cache = in-memory copy inside each service JVM
- heartbeat = "I am still alive"
- Feign = declarative HTTP client that uses service name + discovery
- service name = logical name, not actual URL
- direct HTTP call = from order-service straight to product-service after discovery

Useful annotations and what they do:

- @EnableEurekaServer
  This turns one Spring Boot app into the Eureka registry server.

- @EnableDiscoveryClient
  This tells a service that it can participate in service discovery.
  In modern Spring Cloud setups, it is often not strictly required if the discovery starter is already present, but it is still easy to understand as "enable discovery support".

- @EnableFeignClients
  This tells Spring to find all @FeignClient interfaces and create runtime client proxies for them.

- @FeignClient(name = "product-service")
  This says: use the service name, find it through discovery, and call that service.

- spring.application.name
  This is the service identity used when registering with Eureka.

Very important memory:
- startup = full registration
- every 30 seconds = heartbeat
- registry refresh = client fetches updated service list
- service restart = needed if I change the service name
- Feign = uses discovery info to make the real HTTP call
- Feign does not directly hardcode or manually manage IPs; it relies on discovery and load balancing to reach the live instance behind the service name

That is the whole story in simple words.
*/