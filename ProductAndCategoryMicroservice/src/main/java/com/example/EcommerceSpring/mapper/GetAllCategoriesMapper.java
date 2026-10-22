package com.example.EcommerceSpring.mapper;

import com.example.EcommerceSpring.dto.CategoryDTO;
import com.example.EcommerceSpring.dto.FakeStoreCategoryResponseDTO;

import java.util.List;

public class GetAllCategoriesMapper {

    public static FakeStoreCategoryResponseDTO toFakeStoreCategoryDTO(){
        return null;
    }

    public static List<CategoryDTO> toCategoryDto(FakeStoreCategoryResponseDTO dto){
        return dto.getCategories()
                .stream()
                .map(category -> CategoryDTO.builder()
                        .name(category)
                        .build())
                .toList();
    }
}
