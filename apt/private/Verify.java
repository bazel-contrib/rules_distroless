import java.io.BufferedInputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.Security;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import org.bouncycastle.bcpg.ArmoredInputStream;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.openpgp.PGPSignature;
import org.bouncycastle.openpgp.PGPSignatureException;
import org.bouncycastle.openpgp.PGPSignatureList;
import org.bouncycastle.openpgp.api.OpenPGPApi;
import org.bouncycastle.openpgp.api.OpenPGPCertificate;
import org.bouncycastle.openpgp.api.OpenPGPDefaultPolicy;
import org.bouncycastle.openpgp.api.OpenPGPDetachedSignatureProcessor;
import org.bouncycastle.openpgp.api.OpenPGPSignature.OpenPGPDocumentSignature;
import org.bouncycastle.openpgp.api.jcajce.JcaOpenPGPApi;
import org.bouncycastle.openpgp.jcajce.JcaPGPObjectFactory;

/**
 * Hermetic OpenPGP verifier used by the apt module extension when neither `sqv` nor `gpgv` is on
 * PATH.
 *
 * All OpenPGP semantics (certificate validity, revocation, expiry, key capabilities, hash and key
 * strength policy, text-mode canonicalisation of detached signatures) come from BouncyCastle's
 * high-level `org.bouncycastle.openpgp.api` verifier with its default policy. This file only adds:
 *   - an allowlist of document signature types (the library accepts any signature class, which would
 *     let a key certification pass as a document signature),
 *   - verification against the current time, so expired signatures and keys are rejected,
 *   - the RFC 4880 section 7.1 reduction of a cleartext-signed message to the text that was signed,
 *     because the library cannot parse cleartext-signed messages.
 *
 * Usage:
 *   Verify clearsigned --keyring KEYRING... --output VERIFIED_TEXT INRELEASE
 *   Verify detached    --keyring KEYRING... SIGNATURE MESSAGE
 *
 * `--at EPOCH_SECONDS` verifies as of a fixed time instead of now. It exists for the fixture tests
 * (apt/tests/pgp) so that they do not depend on the clock; the module extension never passes it.
 *
 * Keyrings and signatures may be ASCII-armored or binary. Verification succeeds when at least one
 * signature from a key in the keyrings is valid (the sqv rule).
 *
 * Exit codes: 0 verified, 1 not verified, 2 usage, parse or I/O error.
 */
public class Verify {
    private static final int VERIFIED = 0;
    private static final int NOT_VERIFIED = 1;
    private static final int ERROR = 2;

    private static final int BINARY_DOCUMENT = PGPSignature.BINARY_DOCUMENT;
    private static final int CANONICAL_TEXT_DOCUMENT = PGPSignature.CANONICAL_TEXT_DOCUMENT;

    public static void main(String[] args) {
        int code;
        try {
            code = run(args);
        } catch (Throwable t) {
            System.err.println("error: " + t);
            code = ERROR;
        }
        System.exit(code);
    }

    private static int run(String[] args) throws Exception {
        if (args.length == 0) {
            return usage();
        }
        List<Path> keyrings = new ArrayList<>();
        List<Path> positional = new ArrayList<>();
        Path output = null;
        Date now = new Date();
        for (int i = 1; i < args.length; i++) {
            switch (args[i]) {
                case "--at":
                    if (++i == args.length) return usage();
                    now = new Date(Long.parseLong(args[i]) * 1000L);
                    break;
                case "--keyring":
                    if (++i == args.length) return usage();
                    keyrings.add(Path.of(args[i]));
                    break;
                case "--output":
                    if (++i == args.length) return usage();
                    output = Path.of(args[i]);
                    break;
                default:
                    positional.add(Path.of(args[i]));
            }
        }

        Security.addProvider(new BouncyCastleProvider());
        OpenPGPApi api = new JcaOpenPGPApi(new BouncyCastleProvider(), new OpenPGPDefaultPolicy());
        List<OpenPGPCertificate> certs = readCertificates(api, keyrings);

        switch (args[0]) {
            case "clearsigned":
                if (positional.size() != 1 || output == null) return usage();
                return verifyClearsigned(api, certs, positional.get(0), output, now);
            case "detached":
                if (positional.size() != 2) return usage();
                return verifyDetached(api, certs, positional.get(0), positional.get(1), now);
            default:
                return usage();
        }
    }

    private static int usage() {
        System.err.println("usage: Verify clearsigned --keyring K... --output OUT INRELEASE");
        System.err.println("       Verify detached --keyring K... SIGNATURE MESSAGE");
        return ERROR;
    }

    private static List<OpenPGPCertificate> readCertificates(OpenPGPApi api, List<Path> keyrings) throws Exception {
        List<OpenPGPCertificate> certs = new ArrayList<>();
        for (Path keyring : keyrings) {
            int before = certs.size();
            try (InputStream in = new BufferedInputStream(Files.newInputStream(keyring))) {
                certs.addAll(api.readKeyOrCertificate().parseCertificates(in));
            }
            if (certs.size() == before) {
                throw new IllegalArgumentException("no OpenPGP certificates found in keyring " + keyring);
            }
        }
        if (certs.isEmpty()) {
            throw new IllegalArgumentException("no keyring given");
        }
        return certs;
    }

    private static int verifyDetached(OpenPGPApi api, List<OpenPGPCertificate> certs, Path signature, Path message, Date now) throws Exception {
        PGPSignatureList sigs;
        try (InputStream in = org.bouncycastle.openpgp.PGPUtil.getDecoderStream(new BufferedInputStream(Files.newInputStream(signature)))) {
            sigs = readSignatures(in);
        }
        boolean ok = check(api, certs, sigs, Files.readAllBytes(message), now, BINARY_DOCUMENT, CANONICAL_TEXT_DOCUMENT);
        return ok ? VERIFIED : NOT_VERIFIED;
    }

    private static int verifyClearsigned(OpenPGPApi api, List<OpenPGPCertificate> certs, Path inRelease, Path output, Date now) throws Exception {
        byte[] cleartext;
        PGPSignatureList sigs;
        try (ArmoredInputStream armored = new ArmoredInputStream(new BufferedInputStream(Files.newInputStream(inRelease)))) {
            if (!armored.isClearText()) {
                throw new IllegalArgumentException("not a cleartext-signed message: " + inRelease);
            }
            ByteArrayOutputStream raw = new ByteArrayOutputStream();
            int ch;
            while ((ch = armored.read()) >= 0 && armored.isClearText()) {
                raw.write(ch);
            }
            cleartext = raw.toByteArray();
            sigs = readSignatures(armored);
        }

        List<byte[]> lines = signedLines(cleartext);
        if (lines == null) {
            System.err.println("cleartext contains a carriage return that is not part of a CRLF line ending");
            return NOT_VERIFIED;
        }
        // The signature covers the lines joined with CRLF and without a final line ending. Verify those
        // exact bytes, and return the same lines joined with LF, so the caller parses what was verified.
        if (!check(api, certs, sigs, join(lines, new byte[] {'\r', '\n'}), now, CANONICAL_TEXT_DOCUMENT)) {
            return NOT_VERIFIED;
        }
        Files.write(output, join(lines, new byte[] {'\n'}));
        return VERIFIED;
    }

    /**
     * Reduces a cleartext-signed body to the lines that were signed (RFC 4880 section 7.1): the line
     * ending is removed, trailing spaces and tabs are stripped, and the line ending before the
     * signature header is not part of the text. Returns null when the text contains a CR that is not the
     * first half of a CRLF, because such text has no unambiguous canonical form.
     */
    static List<byte[]> signedLines(byte[] cleartext) {
        List<byte[]> lines = new ArrayList<>();
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        boolean pendingCr = false;
        for (byte b : cleartext) {
            if (pendingCr) {
                if (b != '\n') {
                    return null;
                }
                pendingCr = false;
            }
            if (b == '\r') {
                pendingCr = true;
            } else if (b == '\n') {
                lines.add(stripTrailingBlanks(line.toByteArray()));
                line.reset();
            } else {
                line.write(b);
            }
        }
        if (pendingCr) {
            return null;
        }
        if (line.size() > 0) {
            lines.add(stripTrailingBlanks(line.toByteArray()));
        }
        return lines;
    }

    private static byte[] stripTrailingBlanks(byte[] line) {
        int n = line.length;
        while (n > 0 && (line[n - 1] == ' ' || line[n - 1] == '\t')) {
            n--;
        }
        return java.util.Arrays.copyOf(line, n);
    }

    private static byte[] join(List<byte[]> lines, byte[] separator) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (int i = 0; i < lines.size(); i++) {
            if (i > 0) {
                out.writeBytes(separator);
            }
            out.writeBytes(lines.get(i));
        }
        return out.toByteArray();
    }

    private static PGPSignatureList readSignatures(InputStream in) throws Exception {
        Object o = new JcaPGPObjectFactory(in).nextObject();
        if (!(o instanceof PGPSignatureList)) {
            throw new IllegalArgumentException("no OpenPGP signature found");
        }
        return (PGPSignatureList) o;
    }

    /** True when at least one signature, of an allowed type, is valid at `now` for a key in the certificates. */
    private static boolean check(OpenPGPApi api, List<OpenPGPCertificate> certs, PGPSignatureList sigs, byte[] document, Date now, int... allowedTypes) throws Exception {
        OpenPGPDetachedSignatureProcessor processor = api.verifyDetachedSignature();
        for (OpenPGPCertificate cert : certs) {
            processor.addVerificationCertificate(cert);
        }
        processor.addSignatures(sigs);

        int valid = 0;
        int considered = 0;
        for (OpenPGPDocumentSignature sig : processor.process(new ByteArrayInputStream(document))) {
            considered++;
            String keyId = Long.toHexString(sig.getSignature().getKeyID());
            if (!isAllowedType(sig.getSignature().getSignatureType(), allowedTypes)) {
                System.out.println("REJECTED " + keyId + " (signature type " + sig.getSignature().getSignatureType() + ")");
            } else if (isValidAt(sig, now)) {
                System.out.println("VALID " + keyId);
                valid++;
            } else {
                System.out.println("INVALID " + keyId);
            }
        }
        if (valid == 0) {
            System.err.println("verification failed: " + considered + " signature(s) from known keys, none valid");
        }
        return valid > 0;
    }

    private static boolean isValidAt(OpenPGPDocumentSignature sig, Date when) {
        try {
            return sig.isValidAt(when);
        } catch (PGPSignatureException e) {
            System.out.println("  " + e.getMessage());
            return false;
        }
    }

    private static boolean isAllowedType(int type, int[] allowed) {
        for (int a : allowed) {
            if (a == type) {
                return true;
            }
        }
        return false;
    }
}
