package com.example.EcommerceSpring.services;

import com.example.EcommerceSpring.dto.LimitProductsDTO;
import com.example.EcommerceSpring.gateway.ILimitProductGateway;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.util.List;

@Service
public class  FakeStoreLimitProductService implements ILimitProductService{

    private final ILimitProductGateway limitProductGateway;

    public FakeStoreLimitProductService(ILimitProductGateway limitProductGateway) {
        this.limitProductGateway = limitProductGateway;
    }

    @Override
    public List<LimitProductsDTO> getLimitedProducts(int limit) throws IOException {
        return this.limitProductGateway.getLimitedProducts(limit);
    }

}
