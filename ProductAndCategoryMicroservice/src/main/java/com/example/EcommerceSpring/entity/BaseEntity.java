package com.example.EcommerceSpring.entity;

//Importing JPA annotations like @id, @column used for mapping class to a db structure
import jakarta.persistence.*;
import lombok.Getter;
import lombok.Setter;
import org.springframework.data.annotation.CreatedDate;
import org.springframework.data.annotation.LastModifiedDate;
import org.springframework.data.jpa.domain.support.AuditingEntityListener;

 //Instant class from java time api > represents the timestamp in utc
import java.time.Instant;

//This is a jpa annotation used to define the base class that contains the common fields
//which will be inherited and mapped into child entity tables
//Unlike @entity > it does not get its own table
@MappedSuperclass
// This is for so that spring will automatically populate the columns
@EntityListeners(AuditingEntityListener.class)
@Getter
@Setter

public class BaseEntity {
    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private long id;

    @CreatedDate
    @Column(nullable = false, updatable = false)
    private Instant createdAt;

    @LastModifiedDate
    @Column(nullable = false)
    private Instant updatedAt;

    // this method is automatically called before the entity is saved for the first time.
    // this means you are adding a row to this table for the first time so this function should be called
    @PrePersist
    public void onCreated(){
        Instant now = Instant.now();
        this.createdAt = now;
        this.updatedAt = now;
    }
    //this function is called when the row already existed and i would like to updated and then change the updatedAt
    // column to updated or current timestamp
    @PreUpdate
    public void onUpdate(){
        this.updatedAt = Instant.now();
    }

}
