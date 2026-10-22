package com.example.EcommerceSpring.Services;

import com.example.EcommerceSpring.dto.CategoryDTO;
import com.example.EcommerceSpring.entity.Category;
import com.example.EcommerceSpring.repository.CategoryRepository;
import com.example.EcommerceSpring.services.CategoryService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.*;
import static org.mockito.Mockito.times;

@ExtendWith(MockitoExtension.class) //This annotation is used to enable mockito for the test class with JUnit
public class CategoryServiceTest {

    @Mock
    private CategoryRepository categoryRepository;

    @InjectMocks
    private CategoryService categoryService;

    private CategoryDTO categoryDTO;
    private Category category1;
    private Category category2;
    private Category category3;

    @BeforeEach
    void setUp(){
        categoryDTO = CategoryDTO.builder().name("Electronics").build();
        category1 = Category.builder().name("Electronics").build();
        category1.setId(1L);
        category2 = Category.builder().name("Books").build();
        category2.setId(2L);
        category3 = Category.builder().name("Clothing").build();
        category3.setId(3L);
    }

    @Test
    @DisplayName("should return all categories successfully")
    void getAllCategories_shouldReturnAllCategories() throws Exception{

        //Arrange
        List<Category> categories = new ArrayList<>();

        categories.add(category1);
        categories.add(category2);

        when(categoryRepository.findAll()).thenReturn(categories);

        //Act
        List<CategoryDTO> result = categoryService.getAllCategories();

        //Assert
        assertEquals(2, result.size());
        verify(categoryRepository, times(1)).findAll();

    }

    @Test
    @DisplayName("Should create a new category successfully")
    void createCategory_shouldCreateNewCategory() throws Exception{
        //Arrange

        when(categoryRepository.save(any(Category.class))).thenReturn(category1);
        //Act
        CategoryDTO result = categoryService.createCategory(categoryDTO);

        //Assert
        assertEquals("Electronics", result.getName());
    }

    @Test
    @DisplayName("Should return empty list when no categories exist")
    void getAllCategories_shouldReturnEmptyListWhenNoCategoriesExist() throws Exception{

        when(categoryRepository.findAll()).thenReturn(new ArrayList<>());
        //Act
        List<CategoryDTO> result = categoryService.getAllCategories();

        //Assert
        assertEquals(0, result.size());
        verify(categoryRepository, times(1)).findAll();
    }

    @Test
    @DisplayName("Should return category by Name")
    void getByName_shouldReturnCategoryByName() throws Exception{
        when(categoryRepository.findByName("Clothing")).thenReturn(Optional.of(category3));

        CategoryDTO result = categoryService.getByName("Clothing");
        assertEquals("Clothing", result.getName());
        verify(categoryRepository, times(1)).findByName("Clothing");
    }
}
