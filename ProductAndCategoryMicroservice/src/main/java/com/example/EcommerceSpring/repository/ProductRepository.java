package com.example.EcommerceSpring.repository;
import org.springframework.data.repository.query.Param;
import com.example.EcommerceSpring.entity.Product;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.stereotype.Repository;

import java.util.List;

@Repository
public interface ProductRepository extends JpaRepository<Product, Long> {
    //find all the expensive products > find all products which have a price > minPrice
    //http://localhost:3000/api/categories?minPrice=2500
    @Query("SELECT p from Product p WHERE p.price > :minPrice")  //This is a custom query method using hybernate hql. Explicitly define the query logic instead of using auto generated
    List<Product> findExpensiveProducts(@Param("minPrice") double minPrice);

    //LIMIT
    //REGEX
    //ILIKE
    //writing raw sql query
    //This is native sql query
    @Query(value = "Select * FROM product WHERE MATCH(name, description) AGAINST(:keyword)", nativeQuery = true)
    List<Product> searchFullText(@Param("keyword") String keyword);

    //:minPrce <"minPrice" in @Param("minPrice")
    //:brand < "brand" in @Param("brand")
    @Query("Select p from Product p where p.price > :minPrice AND p.brand = :brand")
    List<Product> findByBrandAndPrice(
            @Param("minPrice") int price,
            @Param("brand") String brandName
    );

}
