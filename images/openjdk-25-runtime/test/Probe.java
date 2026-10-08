// Probe for the OpenJDK runtime images, run with the single-file source
// launcher (java Probe.java) by images/openjdk-<version>-runtime/test.
//
// Prints one line per check: "PASS <check>: <what it saw>" or
// "FAIL <check>: <error>", and for the cryptography one "ALLOWED
// <operation>: <result>" or "REFUSED <operation>: <error>" line each.
// Exits 1 when any check failed.

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPairGenerator;
import java.security.MessageDigest;
import java.security.interfaces.RSAPublicKey;
import java.time.Duration;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.time.format.FormatStyle;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Locale;
import java.util.concurrent.Callable;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;
import javax.crypto.Cipher;
import javax.crypto.spec.SecretKeySpec;

public class Probe {
  static int failures = 0;

  public static void main(String[] args) {
    check("runs as", () -> "uid " + Files.readAllLines(
        Path.of("/proc/self/status")).stream()
        .filter(line -> line.startsWith("Uid:"))
        .map(line -> line.split("\\s+")[1])
        .findFirst().orElse("unknown"));
    check("Java", () -> System.getProperty("java.runtime.version"));
    check("cultures", () -> LocalDate.of(2026, 10, 6).format(
        DateTimeFormatter.ofLocalizedDate(FormatStyle.FULL)
            .withLocale(Locale.GERMANY)));
    check("time zones", () -> ZonedDateTime
        .of(2026, 7, 1, 12, 0, 0, 0, ZoneId.of("UTC"))
        .withZoneSameInstant(ZoneId.of("America/Chicago"))
        .toLocalTime().toString());
    check("gzip compression", Probe::gzipRoundTrip);
    check("HTTPS to github.com", Probe::github);

    report("MD5", () -> hex(MessageDigest.getInstance("MD5")
        .digest(new byte[] {1})));
    report("SHA-256", () -> hex(MessageDigest.getInstance("SHA-256")
        .digest(new byte[] {1})));
    report("3DES encryption", () -> {
      Cipher des = Cipher.getInstance("DESede/ECB/NoPadding");
      des.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(new byte[24], "DESede"));
      return des.doFinal(new byte[8]).length + " bytes";
    });
    report("RSA-1024 key generation", () -> rsaKeyBits(1024));
    report("RSA-2048 key generation", () -> rsaKeyBits(2048));
    System.exit(failures == 0 ? 0 : 1);
  }

  static String gzipRoundTrip() throws Exception {
    byte[] data = "x".repeat(4096).getBytes();
    ByteArrayOutputStream packed = new ByteArrayOutputStream();
    try (GZIPOutputStream gzip = new GZIPOutputStream(packed)) {
      gzip.write(data);
    }
    byte[] back = new GZIPInputStream(
        new ByteArrayInputStream(packed.toByteArray())).readAllBytes();
    if (!Arrays.equals(back, data)) {
      throw new IllegalStateException("round trip differs");
    }
    return data.length + " -> " + packed.size() + " bytes and back";
  }

  static String github() throws Exception {
    HttpClient client = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(20)).build();
    HttpRequest request = HttpRequest.newBuilder(
        URI.create("https://github.com/"))
        .timeout(Duration.ofSeconds(20)).build();
    return "HTTP " + client.send(request,
        HttpResponse.BodyHandlers.discarding()).statusCode();
  }

  static String rsaKeyBits(int bits) throws Exception {
    KeyPairGenerator generator = KeyPairGenerator.getInstance("RSA");
    generator.initialize(bits);
    RSAPublicKey key = (RSAPublicKey) generator.generateKeyPair().getPublic();
    return key.getModulus().bitLength() + "-bit key";
  }

  static String hex(byte[] bytes) {
    return HexFormat.of().formatHex(bytes);
  }

  static void check(String name, Callable<String> body) {
    try {
      System.out.println("PASS " + name + ": " + body.call());
    } catch (Exception e) {
      failures++;
      System.out.println("FAIL " + name + ": " + e);
    }
  }

  static void report(String name, Callable<String> body) {
    try {
      System.out.println("ALLOWED " + name + ": " + body.call());
    } catch (Exception e) {
      System.out.println("REFUSED " + name + ": " + e);
    }
  }
}
