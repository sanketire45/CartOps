package com.example.EcommerceSpring.services;

import com.example.EcommerceSpring.dto.CategoryDTO;
import com.example.EcommerceSpring.dto.GetAllProductOfACategoryDTO;

import java.util.List;

public interface ICategoryService {
    List<CategoryDTO> getAllCategories() throws Exception;

    CategoryDTO createCategory(CategoryDTO categoryDTO) throws Exception;
    CategoryDTO getByName(String name) throws Exception;
    GetAllProductOfACategoryDTO getAllProductOfACategory(Long id) throws Exception;

}
