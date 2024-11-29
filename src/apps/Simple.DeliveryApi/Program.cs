using System.Text.Json;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container.
// Learn more about configuring Swagger/OpenAPI at https://aka.ms/aspnetcore/swashbuckle
builder.Services.AddHealthChecks();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase;
});

var app = builder.Build();

// Configure the HTTP request pipeline.
if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

/// <summary>
/// Mock delivery data
/// </summary>
/// <value></value>
app.MapGet("/deliver/cart/{id:Guid}", (Guid id, ILogger<Program> logger) =>
{
    var result = new DeliveryStatus(
        Guid.NewGuid(),
        "Delivered",
        new DeliveryAddress(
            "440 Terry Ave N",
            "Seattle",
            "WA",
            "98109",
            "USA"),
        "Delivered successfully",
        id);

    logger.LogInformation("Delivery status for cart {CartId} is {Status}", id, result.Status);
    return result;
});

app.MapGet("/", () => "Simple API emulating Delivery service");

app.MapHealthChecks("/healthz");
app.UsePathBase(new PathString("/apps/delivery"));
await app.RunAsync();

record WeatherForecast(DateOnly Date, int TemperatureC, string? Summary)
{
    public int TemperatureF => 32 + (int)(TemperatureC / 0.5556);
}

record DeliveryAddress(
    string? Address,
    string City,
    string State,
    string PostalCode,
    string Country
);

record DeliveryStatus(
    Guid Id,
    string Status,
    DeliveryAddress Address,
    string? Summary,
    Guid CartId
);