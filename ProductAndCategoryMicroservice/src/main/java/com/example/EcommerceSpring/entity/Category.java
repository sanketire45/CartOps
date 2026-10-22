package com.example.EcommerceSpring.entity;

import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import lombok.*;
import jakarta.persistence.*;

import java.util.List;

@Entity
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder

public class Category extends BaseEntity{

    @Column(nullable = false, unique = true)
    private String name;

    //one category can have  many products
    //one to many means category can have many products
    //This does not mean that your trying to store list of products inside category table
    //Telling jpa , the relationship is already owned by the product entity, so just read from there
    @OneToMany(mappedBy = "category")
    private List<Product> products;
}
