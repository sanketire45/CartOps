package com.example.EcommerceSpring.mapper;

import com.example.EcommerceSpring.dto.CategoryDTO;
import com.example.EcommerceSpring.dto.GetAllProductOfACategoryDTO;
import com.example.EcommerceSpring.entity.Category;

import java.util.stream.Collectors;

public class CategoryMapper {
    public static CategoryDTO toDto(Category entity){
        return CategoryDTO.builder()
                .id(entity.getId())
                .name(entity.getName())
                .build();
    }

    public static Category toEntity(CategoryDTO dto){
        return Category.builder()
                .name(dto.getName())
                .build();
    }

    public static GetAllProductOfACategoryDTO toGetAllProductOfACategoryDTO(Category entity){
        return GetAllProductOfACategoryDTO.builder()
                .id(entity.getId())
                .name(entity.getName())
                .products(entity.getProducts().stream()
                        .map(ProductMapper::toDto)
                        .collect(Collectors.toList()))
                .build();
    }
}
