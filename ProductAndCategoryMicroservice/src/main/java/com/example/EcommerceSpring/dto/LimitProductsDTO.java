package com.example.EcommerceSpring.dto;

import lombok.Data;
import lombok.*;

@Getter
@Setter
@Builder
@NoArgsConstructor
@AllArgsConstructor
@Data

public class LimitProductsDTO {
	private String image;
	private String color;
	private int price;
	private String description;
	private int discount;
	private String model;
	private int id;
	private String title;
	private String category;
	private String brand;
	private boolean popular;
}