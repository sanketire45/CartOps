package com.example.EcommerceSpring.configuration;

import com.example.EcommerceSpring.gateway.api.FakeStoreCategoryApi;
import com.example.EcommerceSpring.gateway.api.FakeStoreLimitProductApi;
import com.example.EcommerceSpring.gateway.api.FakeStoreProductApi;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.beans.factory.annotation.Value;
import retrofit2.Retrofit;
import retrofit2.converter.gson.GsonConverterFactory;

@Configuration
public class RetrofitConfig {
    @Value("${FAKESTORE_BASE_URL}")
    private String baseUrl;

    @Bean
    public Retrofit retrofit(){
        return new Retrofit.Builder()
                .baseUrl(baseUrl)
                .addConverterFactory(GsonConverterFactory.create())
                .build();
    }
    @Bean
    public FakeStoreCategoryApi fakeStoreCategoryApi(Retrofit retrofit){
        return retrofit.create(FakeStoreCategoryApi.class);
    }

    @Bean
    public FakeStoreProductApi fakeStoreProductApi(Retrofit retrofit){
        return retrofit.create(FakeStoreProductApi.class);
    }

    @Bean
    public FakeStoreLimitProductApi fakeStoreLimitProductApi(Retrofit retrofit){
        return retrofit.create(FakeStoreLimitProductApi.class);
    }
}
