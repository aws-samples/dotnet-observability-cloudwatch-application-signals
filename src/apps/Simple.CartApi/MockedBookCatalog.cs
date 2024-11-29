
using Simple.CartApi.Contracts;

namespace Simple.CartApi;
internal class MockedBookCatalog
{
    public static IList<Book> MockBooks()
    {
        var books = new List<Book>();
        int max = Random.Shared.Next(2, 10);

        for (int i = 1; i <= max; i++)
        {
            books.Add(new Book
            (
                Guid.NewGuid(),
                "Book " + i,
                "Author " + i,
                2000 + 1
            ));
        }

        return books;
    }
}
