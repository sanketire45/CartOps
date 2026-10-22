package com.example.EcommerceSpring.gateway.api;

import com.example.EcommerceSpring.dto.FakeStoreLimitProductResponseDTO;
import retrofit2.Call;
import retrofit2.http.GET;
import retrofit2.http.Query;

import java.io.IOException;

public interface FakeStoreLimitProductApi {
    @GET("products")
    Call<FakeStoreLimitProductResponseDTO> getLimitedProducts(@Query("limit") int limit) throws IOException;
}