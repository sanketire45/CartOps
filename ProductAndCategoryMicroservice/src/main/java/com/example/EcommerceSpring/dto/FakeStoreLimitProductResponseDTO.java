package com.example.EcommerceSpring.dto;

import java.util.List;
import lombok.Data;

@Data
public class FakeStoreLimitProductResponseDTO{
	private String message;
	private String status;
	private List<LimitProductsDTO> products;
}

