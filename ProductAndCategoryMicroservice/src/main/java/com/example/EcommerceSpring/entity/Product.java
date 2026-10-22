package com.example.EcommerceSpring.entity;

import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import lombok.*;
import org.springframework.data.repository.cdi.Eager;

@Entity
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
@Builder

public class Product extends BaseEntity{
    private String image;
    private String color;
    private int price;
    private String description;
    private int discount;
    private String model;
    //private long id;
    private String title;
    private String brand;
    private boolean popular;

    //Each product belongs to one category
    //And one category can have many products
    //ManytoOne > Eager by default
    //OneToOne > Eager
    //OneToMany > Lazy
    @ManyToOne(fetch = FetchType.LAZY)
    @JoinColumn(name = "category_id", nullable = false)
    private Category category;
}
