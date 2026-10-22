package com.example.EcommerceSpring.gateway;

import com.example.EcommerceSpring.dto.LimitProductsDTO;

import java.io.IOException;
import java.util.List;

public interface ILimitProductGateway {
    List<LimitProductsDTO> getLimitedProducts(int limit) throws IOException;
}
