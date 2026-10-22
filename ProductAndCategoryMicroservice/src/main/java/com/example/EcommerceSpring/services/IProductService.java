package com.example.EcommerceSpring.services;

import com.example.EcommerceSpring.dto.ProductDTO;
import com.example.EcommerceSpring.dto.ProductWithCategoryDTO;

public interface IProductService {

    ProductDTO getProductById(Long id) throws Exception;
    ProductDTO createProduct(ProductDTO dto) throws Exception;
    ProductWithCategoryDTO getProductWithCategory(Long id) throws Exception;
}
