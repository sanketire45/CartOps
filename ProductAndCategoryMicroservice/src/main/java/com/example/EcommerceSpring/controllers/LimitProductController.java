package com.example.EcommerceSpring.controllers;

import com.example.EcommerceSpring.dto.LimitProductsDTO;
import com.example.EcommerceSpring.services.ILimitProductService;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.util.List;

@RestController
@RequestMapping("/api/products")
public class LimitProductController {

    private final ILimitProductService limitProductService;
    public LimitProductController(ILimitProductService limitProductService){
        this.limitProductService = limitProductService;

    }

    @GetMapping
    public ResponseEntity<List<LimitProductsDTO>> getLimitedProducts(@RequestParam(defaultValue = "3") int limit) throws IOException {
        List<LimitProductsDTO> result = limitProductService.getLimitedProducts(limit);
        return ResponseEntity.ok(result);
    }
}
