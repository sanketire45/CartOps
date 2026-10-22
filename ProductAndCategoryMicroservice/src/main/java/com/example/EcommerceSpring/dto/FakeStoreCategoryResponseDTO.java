package com.example.EcommerceSpring.dto;
import lombok.*;

import java.util.List;

@Getter
@Setter
@Builder
@NoArgsConstructor
@AllArgsConstructor

public class FakeStoreCategoryResponseDTO {

    private String status;
    private String message;
    private List<String> categories;

}
