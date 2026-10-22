package com.example.EcommerceSpring.dto;

import lombok.*;

import java.util.List;

@Getter
@Setter
@Builder
@NoArgsConstructor
@AllArgsConstructor

public class GetAllProductOfACategoryDTO {
    private Long id;
    private String name;

    private List<ProductDTO> products;
}
