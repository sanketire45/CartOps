package com.example.EcommerceSpring.controllers;
import com.example.EcommerceSpring.dto.CategoryDTO;
import com.example.EcommerceSpring.dto.GetAllProductOfACategoryDTO;
import com.example.EcommerceSpring.exception.CategoryNotFoundException;
import com.example.EcommerceSpring.services.ICategoryService;
import okhttp3.Response;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.io.IOException;
import java.util.List;

@RestController
@RequestMapping("/api/categories")
public class CategoryController {

    private final ICategoryService categoryService;

    public CategoryController(ICategoryService categoryService){
        this.categoryService = categoryService;
    }

    @GetMapping
    public ResponseEntity<?> getAllCategories(@RequestParam(required = false) String name) throws Exception {
        if(name!= null && !name.isBlank()){
            CategoryDTO categoryDTO = categoryService.getByName(name);
            return ResponseEntity.ok(categoryDTO);
        }else{
            List<CategoryDTO> result = this.categoryService.getAllCategories();
            return ResponseEntity.ok(result);
        }

    }

    @GetMapping("/{id}/products")
    public ResponseEntity<GetAllProductOfACategoryDTO> getAllProductOfACategory(@PathVariable long id) throws Exception{

        GetAllProductOfACategoryDTO dto = categoryService.getAllProductOfACategory(id);
        return ResponseEntity.ok(dto);
    }

    @PostMapping
    public ResponseEntity<CategoryDTO> createCategory(@RequestBody CategoryDTO categoryDTO) throws Exception {
        CategoryDTO created = categoryService.createCategory(categoryDTO);
        return ResponseEntity.ok(created);
    }

   // @ExceptionHandler(CategoryNotFoundException.class)

}
