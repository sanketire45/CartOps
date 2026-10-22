package com.example.EcommerceSpring.gateway;

import com.example.EcommerceSpring.dto.CategoryDTO;
import com.example.EcommerceSpring.dto.FakeStoreCategoryResponseDTO;
import com.example.EcommerceSpring.mapper.GetAllCategoriesMapper;
import org.springframework.boot.web.client.RestTemplateBuilder;
import org.springframework.http.ResponseEntity;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

import java.io.IOException;
import java.util.List;

@Component("FakeStoreRestTemplateGateway")
//with @ primary we can say to dependancy injection to inject the object of this class when we have two class implementation of the same interface
// @Primary
public class FakeStoreRestTemplateGateway implements ICategoryGateway{

    private final RestTemplateBuilder restTemplateBuilder;

    public FakeStoreRestTemplateGateway(RestTemplateBuilder restTemplateBuilder){
        this.restTemplateBuilder = restTemplateBuilder;
    }

    @Override
    public List<CategoryDTO> getAllCategories() throws IOException {
        RestTemplate restTemplate = restTemplateBuilder.build();
        String url = "https://fakestoreapi.in/api/ products/category";
        ResponseEntity< FakeStoreCategoryResponseDTO> response = restTemplate.getForEntity(url, FakeStoreCategoryResponseDTO.class);

        if(response.getBody() == null){
            throw new IOException("Failed to fetch categories from Fakestore API");
        }

        return GetAllCategoriesMapper.toCategoryDto(response.getBody());
    }

}
