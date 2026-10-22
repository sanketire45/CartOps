package com.example.EcommerceSpring.gateway;

import com.example.EcommerceSpring.dto.FakeStoreLimitProductResponseDTO;
import com.example.EcommerceSpring.dto.LimitProductsDTO;
import com.example.EcommerceSpring.gateway.api.FakeStoreLimitProductApi;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.util.List;

@Component
public class FakeStoreLimitProductGateway implements ILimitProductGateway{

    private final FakeStoreLimitProductApi fakeStoreLimitProductApi;
    public FakeStoreLimitProductGateway(FakeStoreLimitProductApi fakeStoreLimitProductApi){
        this.fakeStoreLimitProductApi = fakeStoreLimitProductApi;
    }

    @Override
    public List<LimitProductsDTO> getLimitedProducts(int limit) throws IOException {
        FakeStoreLimitProductResponseDTO response = this.fakeStoreLimitProductApi.getLimitedProducts(limit).execute().body();
        if(response == null){
            throw new IOException("Product not found");
        }

        return response.getProducts();
    }
}
