package com.example.EcommerceSpring.exception;

import org.springframework.cglib.core.Local;

import java.time.LocalDateTime;
import lombok.*;
@Getter
@Setter
@NoArgsConstructor
@AllArgsConstructor
public class ErrorResponse {

    private int status;
    private String message;
    private LocalDateTime timestamp;

}
