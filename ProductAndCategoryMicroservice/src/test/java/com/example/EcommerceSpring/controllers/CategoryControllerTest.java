package com.example.EcommerceSpring.controllers;

import com.example.EcommerceSpring.controllers.CategoryController;
import com.example.EcommerceSpring.dto.CategoryDTO;
import com.example.EcommerceSpring.exception.GlobalExceptionHandler;
import com.example.EcommerceSpring.services.ICategoryService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.ArrayList;
import java.util.List;

import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get; // ✅ Import this
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath; // ✅ Import this
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@ExtendWith(MockitoExtension.class)
public class CategoryControllerTest {

    @Mock
    private ICategoryService categoryService;

    @InjectMocks
    private CategoryController categoryController;

    private MockMvc mockMvc;

    @BeforeEach
    void setUp(){
        mockMvc = MockMvcBuilders.standaloneSetup(categoryController)
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();
    }

    @Test
    @DisplayName("Get /api/categories should return all categories")
    void getAllCategories_shouldReturnAllCategories() throws  Exception{
        // Arrange
        List<CategoryDTO> categories = new ArrayList<>();
        categories.add(CategoryDTO.builder().id(1L).name("Electronics").build());
        categories.add(CategoryDTO.builder().id(2L).name("Books").build());
        categories.add(CategoryDTO.builder().id(3L).name("Clothing").build());

        when(categoryService.getAllCategories()).thenReturn(categories);

        // Act + Assert
        mockMvc.perform(get("/api/categories")
                        .contentType(org.springframework.http.MediaType.APPLICATION_JSON))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$").isArray())
                .andExpect(jsonPath("$[0].id").value(1))
                .andExpect(jsonPath("$[0].name").value("Electronics"))
                .andExpect(jsonPath("$[1].id").value(2))
                .andExpect(jsonPath("$[1].name").value("Books"))
                .andExpect(jsonPath("$[2].id").value(3))
                .andExpect(jsonPath("$[2].name").value("Clothing"));

        verify(categoryService, times(1)).getAllCategories();
    }
}
