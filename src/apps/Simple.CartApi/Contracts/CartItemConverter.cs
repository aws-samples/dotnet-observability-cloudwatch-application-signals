using System.Text.Json;
using Amazon.DynamoDBv2.DataModel;
using Amazon.DynamoDBv2.DocumentModel;

namespace Simple.CartApi.Contracts;

class CartItemConverter : IPropertyConverter
{
    public DynamoDBEntry ToEntry(object value)
    {
        if (value is not IEnumerable<CartItem> cartItem)
            throw new ArgumentOutOfRangeException();

        var entry = new Primitive(JsonSerializer.Serialize(cartItem));

        return entry;
    }

    public object FromEntry(DynamoDBEntry entry)
    {
        var primitive = entry as Primitive;
        if (primitive == null || primitive.Value is not String || string.IsNullOrEmpty((string)primitive.Value))
            throw new ArgumentOutOfRangeException();

        return JsonSerializer.Deserialize<IEnumerable<CartItem>>((string)primitive.Value) ?? [];

    }
}