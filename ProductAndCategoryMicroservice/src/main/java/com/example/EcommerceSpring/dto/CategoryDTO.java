package com.example.EcommerceSpring.dto;
import lombok.*;

@Getter
@Setter
@Builder
@NoArgsConstructor
@AllArgsConstructor

public class CategoryDTO {
    private Long id;
    private String name;
}
