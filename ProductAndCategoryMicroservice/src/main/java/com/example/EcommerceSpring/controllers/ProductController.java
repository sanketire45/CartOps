package com.example.EcommerceSpring.controllers;
import com.example.EcommerceSpring.dto.ProductDTO;
import com.example.EcommerceSpring.dto.ProductWithCategoryDTO;
import com.example.EcommerceSpring.exception.CategoryNotFoundException;
import com.example.EcommerceSpring.exception.ProductNotFoundException;
import com.example.EcommerceSpring.services.IProductService;
import okhttp3.Response;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController //tells spring this class handles web requests
@RequestMapping("/api/products")
public class ProductController {

    private final IProductService productService;

    public ProductController(IProductService productService){
        this.productService = productService;
    }

    @GetMapping("/{id}")
    public ResponseEntity<ProductDTO> getProductById(@PathVariable Long id) throws Exception{
        ProductDTO result = this.productService.getProductById(id);

        return ResponseEntity.ok(result);
    }

    @PostMapping
    public ResponseEntity<ProductDTO> createProduct(@RequestBody ProductDTO dto) throws Exception{
        return ResponseEntity.ok(productService.createProduct(dto));
    }

    @GetMapping("/{id}/details")
    public ResponseEntity<ProductWithCategoryDTO> getProductWithCategory(@PathVariable long id) throws Exception{

        ProductWithCategoryDTO dto = productService.getProductWithCategory(id);
        return ResponseEntity.ok(dto);
    }


    //@ExceptionHandler(ProductDeletionException.class)

}
