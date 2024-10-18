namespace Simple.CartApi.Contracts;
record Book(
    Guid Id,
    string Title,
    string Author,
    int Year
);

record CartItem(Guid Id,
    string Name,
    double Price,
    int Quantity,
    Book Product
);

record DeliveryAddress(string? Address,
    string City,
    string State,
    string PostalCode,
    string Country
);

record DeliveryStatus(Guid Id,
    string Status,
    DeliveryAddress Address,
    string? Summary
);
