// Probe for the .NET images. Built and run by images/dotnet-10-toolset/test.
//
//   probe          one line per check: "PASS <check>: <what it saw>" or
//                  "FAIL <check>: <error>", then "ALL PASS" or "<n> FAILED";
//                  exits with the number of failed checks
//   probe fips     what the FIPS OpenSSL configuration allows: one
//                  "ALLOWED <operation>: <result>" or
//                  "REFUSED <operation>: <error>" line each
//   probe serve    a web server answering "hello from .NET <version> ..."

using System.Globalization;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

string mode = args.Length > 0 ? args[0] : "checks";

if (mode == "serve")
{
  var app = WebApplication.Create(args.Skip(1).ToArray());
  string os = RuntimeInformation.OSDescription;
  app.MapGet("/", () => $"hello from .NET {Environment.Version} on {os}");
  app.Run();
  return 0;
}

if (mode == "fips")
{
  Report("MD5", () =>
    Convert.ToHexString(MD5.HashData(new byte[] { 1 })));

  // RSA keys are made on first use, so export the key to force it.
  Report("RSA-1024 key generation", () =>
    Bits(RSA.Create(1024).ExportParameters(false).Modulus!));
  Report("RSA-2048 key generation", () =>
    Bits(RSA.Create(2048).ExportParameters(false).Modulus!));

  Report("3DES encryption", () =>
    TripleDES.Create().EncryptEcb(new byte[8], PaddingMode.None).Length
    + " bytes");

  // IsSupported says true even when the configuration refuses the cipher,
  // so actually encrypt.
  Report("ChaCha20-Poly1305 encryption", () =>
  {
    using var chacha = new ChaCha20Poly1305(new byte[32]);
    chacha.Encrypt(new byte[12], new byte[] { 1, 2, 3 },
      new byte[3], new byte[16]);
    return "3 bytes";
  });
  return 0;
}

int failures = 0;

Check("runtime", () =>
  $"{RuntimeInformation.FrameworkDescription} " +
  $"{RuntimeInformation.RuntimeIdentifier}, core library in " +
  Path.GetDirectoryName(typeof(object).Assembly.Location));

Check("ICU cultures", () =>
  new DateTime(2026, 10, 6).ToString("D", new CultureInfo("de-DE")));

Check("time zones", () =>
{
  var noon = new DateTime(2026, 7, 1, 12, 0, 0, DateTimeKind.Utc);
  return TimeZoneInfo
    .ConvertTimeBySystemTimeZoneId(noon, "America/Chicago")
    .ToString("HH:mm", CultureInfo.InvariantCulture);
});

Check("Brotli compression", () =>
{
  byte[] data = Encoding.UTF8.GetBytes(new string('x', 4096));
  using var compressed = new MemoryStream();
  // leaveOpen: the compressed stream is read back after Brotli finishes.
  using (var brotli = new BrotliStream(
    compressed, CompressionLevel.Optimal, leaveOpen: true))
  {
    brotli.Write(data);
  }
  compressed.Position = 0;
  using var unpacked = new MemoryStream();
  using (var brotli = new BrotliStream(
    compressed, CompressionMode.Decompress))
  {
    brotli.CopyTo(unpacked);
  }
  if (!unpacked.ToArray().SequenceEqual(data))
  {
    throw new InvalidDataException("round trip differs");
  }
  return "round trip ok";
});

Check("SHA-256", () =>
  Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("abc"))));

Check("AES-GCM", () =>
{
  using var aes = new AesGcm(RandomNumberGenerator.GetBytes(32), 16);
  byte[] nonce = RandomNumberGenerator.GetBytes(12);
  byte[] plain = { 1, 2, 3 };
  byte[] encrypted = new byte[3];
  byte[] tag = new byte[16];
  byte[] opened = new byte[3];
  aes.Encrypt(nonce, plain, encrypted, tag);
  aes.Decrypt(nonce, encrypted, tag, opened);
  if (!opened.SequenceEqual(plain))
  {
    throw new CryptographicException("round trip differs");
  }
  return "round trip ok";
});

Check("HTTPS to github.com", () =>
{
  using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(20) };
  var response = client.GetAsync("https://github.com/").Result;
  return $"HTTP {(int)response.StatusCode}";
});

Console.WriteLine(failures == 0 ? "ALL PASS" : $"{failures} FAILED");
return failures;

void Check(string name, Func<string> body)
{
  try
  {
    Console.WriteLine($"PASS {name}: {body()}");
  }
  catch (Exception e)
  {
    failures++;
    string why = $"{e.GetType().Name}: {FirstLine(e)}";
    Console.WriteLine($"FAIL {name}: {why}");
  }
}

static void Report(string name, Func<string> body)
{
  try
  {
    Console.WriteLine($"ALLOWED {name}: {body()}");
  }
  catch (Exception e)
  {
    string why = $"{e.GetType().Name}: {FirstLine(e)}";
    Console.WriteLine($"REFUSED {name}: {why}");
  }
}

static string FirstLine(Exception e) => e.Message.Split('\n')[0];

static string Bits(byte[] modulus) => $"{modulus.Length * 8}-bit key";
