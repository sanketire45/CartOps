package com.example.EcommerceSpring.gateway;
import com.example.EcommerceSpring.dto.CategoryDTO;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.util.List;

@Component
public interface ICategoryGateway {
    List<CategoryDTO> getAllCategories() throws IOException;
}

