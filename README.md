# E-Commerce Backend System

A microservices-based e-commerce backend built with **Spring Boot 3.5**, featuring service discovery, inter-service REST communication, schema migration, and global exception handling.

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Java 17 |
| Framework | Spring Boot 3.5, Spring Data JPA, Hibernate |
| Database | MySQL 8 |
| Schema Migration | Flyway |
| Service Discovery | Netflix Eureka |
| HTTP Clients | RestTemplate, Retrofit (FakeStore API) |
| Testing | JUnit 5, Mockito |
| Build | Gradle |

---

## Architecture

```
                        ┌─────────────────────────────┐
                        │     Netflix Eureka Server    │
                        │         (port 8761)          │
                        └────────────┬────────────────-┘
                                     │  Service Registry
                     ┌───────────────┴───────────────┐
                     │                               │
          ┌──────────▼──────────┐         ┌──────────▼──────────┐
          │  Product & Category  │         │   Order Microservice │
          │    Microservice      │◄────────│                     │
          │    (port: $PORT)     │  REST   │    (port: $PORT)    │
          └──────────┬──────────┘         └──────────┬──────────┘
                     │                               │
          ┌──────────▼──────────┐         ┌──────────▼──────────┐
          │  MySQL: ecommerce_db│         │  MySQL: order_db    │
          │  (Flyway migrations) │         │                     │
          └─────────────────────┘         └─────────────────────┘
                     │
          ┌──────────▼──────────┐
          │  FakeStore API       │  ← External product data source
          │  (via Retrofit)      │
          └─────────────────────┘
```

### Request Flow

```
Client
  │
  ├─► GET/POST /api/products     ──► ProductController
  │                                       │
  │                                  IProductService
  │                                       │
  │                              ┌────────┴────────┐
  │                              │                 │
  │                         ProductRepo       FakeStoreGateway
  │                         (MySQL DB)        (Retrofit → FakeStore API)
  │
  ├─► GET/POST /api/categories   ──► CategoryController
  │                                       │
  │                                  ICategoryService
  │                                       │
  │                              CategoryRepo (MySQL DB)
  │
  └─► GET /api/products/limited  ──► LimitProductController
                                          │
                                    FakeStoreLimitProductGateway
```

---

## Services

### 1. Product & Category Microservice
Manages the product catalogue and categories. Integrates with the [FakeStore API](https://fakestoreapi.com/) via Retrofit as an external product data source.

**Endpoints**

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/products/{id}` | Get product by ID |
| `POST` | `/api/products` | Create a new product |
| `GET` | `/api/products/{id}/details` | Get product with its category |
| `GET` | `/api/categories` | List all categories (or search by `?name=`) |
| `POST` | `/api/categories` | Create a new category |
| `GET` | `/api/categories/{id}/products` | Get all products in a category |

**Database Schema (via Flyway)**

```
category
  ├── id (PK)
  ├── name
  └── [base: created_at, updated_at]

product
  ├── id (PK)
  ├── title
  ├── description
  ├── price
  ├── brand
  ├── model
  ├── color
  ├── image
  ├── discount
  ├── popular
  ├── rating          ← added in V3
  ├── category_id (FK → category)
  └── [base: created_at, updated_at]
```

### 2. Order Microservice
Manages customer orders and calls the Product service via REST (RestTemplate / Feign Client) using the Eureka-registered service name.

### 3. Eureka Service Discovery
Acts as the central service registry. All microservices register on startup and resolve each other by name rather than hardcoded host/port.

---

## Project Structure

```
Ecommerce-Spring-main/
├── Service discovery with eureka/     # Eureka Server (port 8761)
├── Product And Category Microservice/ # Product & Category service
│   └── src/main/java/.../
│       ├── controllers/               # REST controllers
│       ├── services/                  # Business logic (interface + impl)
│       ├── gateway/                   # FakeStore API adapters (Retrofit)
│       ├── repository/                # Spring Data JPA repos
│       ├── entity/                    # JPA entities
│       ├── dto/                       # Request/Response DTOs
│       ├── mapper/                    # Entity ↔ DTO mappers
│       ├── exception/                 # GlobalExceptionHandler + custom exceptions
│       └── configuration/             # Retrofit config
└── order microservice/                # Order service
```

---

## Running Locally

### Prerequisites
- Java 17+
- MySQL 8 running on `localhost:3306`
- Gradle

### 1. Create databases

```sql
CREATE DATABASE ecommerce_db;
CREATE DATABASE order_db;
```

### 2. Start Eureka Server

```bash
cd "Service discovery with eureka"
./gradlew bootRun
```
Eureka dashboard: [http://localhost:8761](http://localhost:8761)

### 3. Start Product & Category Microservice

```bash
cd "Product And Category Microservice"
PORT=8080 ./gradlew bootRun
```

### 4. Start Order Microservice

```bash
cd "order microservice"
PORT=8081 ./gradlew bootRun
```

### Configuration

Update `application.properties` in each service with your MySQL credentials:

```properties
spring.datasource.username=root
spring.datasource.password=your_password
```

Flyway migrations run automatically on startup — no manual schema setup needed.

---

## Exception Handling

All services use `@ControllerAdvice` + `@ExceptionHandler` for centralized error handling, returning consistent JSON error payloads:

```json
{
  "status": 404,
  "error": "Product not found",
  "message": "No product found with id: 42"
}
```

---

## Running Tests

```bash
./gradlew test
```

Tests cover service-layer business logic and repository contracts using JUnit 5 and Mockito.

---

## Author

**Sanket Walunj** — [github.com/sanket9787](https://github.com/sanket9787) | [linkedin.com/in/sanket-walunj](https://linkedin.com/in/sanket-walunj)
