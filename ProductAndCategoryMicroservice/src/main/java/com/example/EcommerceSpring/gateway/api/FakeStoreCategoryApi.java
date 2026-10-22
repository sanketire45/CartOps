package com.example.EcommerceSpring.gateway.api;

import com.example.EcommerceSpring.dto.FakeStoreCategoryResponseDTO;
import retrofit2.Call;
import retrofit2.http.GET;

import java.io.IOException;


public interface FakeStoreCategoryApi {

   @GET("products/category")
   Call<FakeStoreCategoryResponseDTO> getAllFakeCategories() throws IOException;
}
