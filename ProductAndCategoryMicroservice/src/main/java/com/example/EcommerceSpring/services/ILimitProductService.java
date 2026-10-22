package com.example.EcommerceSpring.services;

import com.example.EcommerceSpring.dto.LimitProductsDTO;

import java.io.IOException;
import java.util.List;

public interface ILimitProductService {
    List<LimitProductsDTO> getLimitedProducts(int limit) throws IOException;
}
