using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json;
using Amazon.DynamoDBv2;
using Amazon.DynamoDBv2.DataModel;
using Microsoft.Net.Http.Headers;
using Simple.CartApi;
using Simple.CartApi.Contracts;

var builder = WebApplication.CreateBuilder(args);

builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
});
// Add services to the container.
builder.Services.AddHealthChecks();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.AddDefaultAWSOptions(builder.Configuration.GetAWSOptions());
builder.Services.AddAWSService<IAmazonDynamoDB>();

builder.Services.AddHttpClient("BackendAPIClient", httpClient =>
{
    var backend_url = Environment.GetEnvironmentVariable("BACKEND_URL") ?? "http://localhost:5120";
    httpClient.BaseAddress = new Uri(backend_url);
    httpClient.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
    httpClient.DefaultRequestHeaders.Add(HeaderNames.UserAgent, "WebPage");
});


var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}


app.MapGet("/cart/{id:guid}", async (Guid id,
    IAmazonDynamoDB dynamoDbClient,
    IHttpClientFactory httpClientFactory) =>
{
    //using id get cart from dynamodb
    var dynamoDBContext = new DynamoDBContext(dynamoDbClient);
    Cart? cart = null;
    try
    {
        cart = await dynamoDBContext.LoadAsync<Cart>(id);
    }
    catch (Exception ex)
    {
        Console.WriteLine(ex.Message);
    }

    if (cart == null)
    {
        var cartItem = MockedBookCatalog.MockBooks()
            .Select(book => new CartItem(Guid.NewGuid(), book.Title, Random.Shared.Next(10, 20), 1, book))
            .ToList();

        cart = new Cart { Id = id, Items = cartItem };

        await dynamoDBContext.SaveAsync(cart);
    }

    //Get delivery details from backend
    var httpClient = httpClientFactory.CreateClient("BackendAPIClient");
    cart.DeliveryStatus = await httpClient.GetFromJsonAsync<DeliveryStatus>($"/deliver/cart/{id}");

    return Results.Ok(cart);
});

app.MapGet("/", () => "Simple API emulating Cart service");
app.MapHealthChecks("/healthz");
app.UsePathBase(new PathString("/apps/cart"));
app.Run();
