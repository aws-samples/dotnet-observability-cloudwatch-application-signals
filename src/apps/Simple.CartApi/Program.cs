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
    IHttpClientFactory httpClientFactory,
    ILogger<Program> logger) =>
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
        var msg = "Fail to persist in DynamoDB Table";
        logger.LogError(ex, msg);
        return Results.Problem(msg);
    }

    //Get delivery details from backend
    var httpClient = httpClientFactory.CreateClient("BackendAPIClient");
    cart.DeliveryStatus = await httpClient.GetFromJsonAsync<DeliveryStatus>($"/deliver/cart/{id}");

    return Results.Ok(cart);
});

/// <summary>
/// List cart items
/// </summary>
/// <returns></returns>
app.MapGet("/cart/{id:guid}/items", async (Guid id, IAmazonDynamoDB dynamoDbClient) =>
{
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
        return Results.Ok(MockedBookCatalog.MockBooks()
            .Select(book => new CartItem(Guid.NewGuid(), book.Title, Random.Shared.Next(10, 20), 1, book))
            .ToList());
    }

    return Results.Ok(cart.Items);
});

/// <summary>
/// Add Cart
/// </summary>
/// <param name="cart"></param>
/// <param name="dynamoDbClient"></param>
/// <returns></returns>
app.MapPost("/cart", async (Cart cart, IAmazonDynamoDB dynamoDbClient) =>
{
    var dynamoDBContext = new DynamoDBContext(dynamoDbClient);
    await dynamoDBContext.SaveAsync(cart);
    return Results.Ok(cart);
});

app.MapGet("/", () => "Simple API emulating Cart service");
app.MapHealthChecks("/healthz");
app.UsePathBase(new PathString("/apps/cart"));
app.Run();
