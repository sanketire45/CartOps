package com.example.EcommerceSpring.services;

import com.example.EcommerceSpring.dto.CategoryDTO;
import com.example.EcommerceSpring.dto.GetAllProductOfACategoryDTO;
import com.example.EcommerceSpring.entity.Category;
import com.example.EcommerceSpring.mapper.CategoryMapper;
import com.example.EcommerceSpring.repository.CategoryRepository;
import lombok.Builder;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

@Service

public class CategoryService implements ICategoryService{

    private final CategoryRepository repo;

    public CategoryService(CategoryRepository repo){
        this.repo = repo;
    }

    @Override
    public List<CategoryDTO> getAllCategories() throws Exception {
        List<CategoryDTO> dtos = new ArrayList<>();
        for(Category category : repo.findAll()){
            dtos.add(CategoryMapper.toDto(category));
        }
        return dtos;
    }

    @Override
    public CategoryDTO createCategory(CategoryDTO categoryDTO) throws Exception{
        Category category = CategoryMapper.toEntity(categoryDTO);
        Category saved = repo.save(category);
        return CategoryMapper.toDto(saved);
    }

    @Override
    public CategoryDTO getByName(String name) throws Exception {
        Category category = repo.findByName(name)
                .orElseThrow(() -> new Exception("Category not found with name :" + name));

        return CategoryMapper.toDto(category);
    }

    @Override
    public GetAllProductOfACategoryDTO getAllProductOfACategory(Long id) throws Exception{
        //this category is the entity
        Category category = repo.findById(id)
                .orElseThrow(() -> new Exception("Category not found with id :" + id));

        return CategoryMapper.toGetAllProductOfACategoryDTO(category);
    }

}
