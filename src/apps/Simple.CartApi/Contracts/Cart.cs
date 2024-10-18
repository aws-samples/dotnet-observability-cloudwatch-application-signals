using Amazon.DynamoDBv2.DataModel;

namespace Simple.CartApi.Contracts;


[DynamoDBTable("simple-cart-catalog")]
record Cart
{
    [DynamoDBHashKey] // Partition key
    public Guid Id { get; set; }

    [DynamoDBProperty(typeof(CartItemConverter))]
    public List<CartItem> Items { get; set; } = [];

    public double TotalPrice => Items.Sum(item => item.Price * item.Quantity);

    [DynamoDBIgnore]
    public DeliveryStatus? DeliveryStatus { get; set; }
}

