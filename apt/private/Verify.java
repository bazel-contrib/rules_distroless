import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.Security;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.bouncycastle.bcpg.ArmoredInputStream;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.openpgp.PGPPublicKey;
import org.bouncycastle.openpgp.PGPPublicKeyRingCollection;
import org.bouncycastle.openpgp.PGPSignature;
import org.bouncycastle.openpgp.PGPSignatureList;
import org.bouncycastle.openpgp.PGPUtil;
import org.bouncycastle.openpgp.jcajce.JcaPGPObjectFactory;
import org.bouncycastle.openpgp.operator.jcajce.JcaKeyFingerprintCalculator;
import org.bouncycastle.openpgp.operator.jcajce.JcaPGPContentVerifierBuilderProvider;

/**
 * Hermetic OpenPGP signature verifier used by the apt module extension when neither `sqv` nor
 * `gpgv` is on PATH.
 *
 * Usage:
 *   Verify clearsigned --keyring KEYRING... --output VERIFIED_OUT INRELEASE
 *   Verify detached    --keyring KEYRING... SIGNATURE MESSAGE
 *
 * Keyrings and signatures may be ASCII-armored or binary. Like the gpgv path, verification
 * succeeds when at least one signature is good and none is bad; signatures from keys that are not
 * in the keyrings are ignored. Exit codes: 0 verified, 1 not verified, 2 usage or parse error.
 */
public class Verify {
    public static void main(String[] args) throws Exception {
        Security.addProvider(new BouncyCastleProvider());
        if (args.length == 0) {
            usage();
        }
        String mode = args[0];
        List<PGPPublicKeyRingCollection> keyrings = new ArrayList<>();
        Path output = null;
        List<Path> positional = new ArrayList<>();
        for (int i = 1; i < args.length; i++) {
            switch (args[i]) {
                case "--keyring":
                    keyrings.add(readKeyring(Path.of(args[++i])));
                    break;
                case "--output":
                    output = Path.of(args[++i]);
                    break;
                default:
                    positional.add(Path.of(args[i]));
            }
        }

        switch (mode) {
            case "clearsigned":
                if (positional.size() != 1 || output == null) {
                    usage();
                }
                verifyClearsigned(keyrings, positional.get(0), output);
                break;
            case "detached":
                if (positional.size() != 2) {
                    usage();
                }
                verifyDetached(keyrings, positional.get(0), positional.get(1));
                break;
            default:
                usage();
        }
    }

    private static void usage() {
        System.err.println("usage: Verify clearsigned --keyring K... --output OUT INRELEASE");
        System.err.println("       Verify detached --keyring K... SIGNATURE MESSAGE");
        System.exit(2);
    }

    private static PGPPublicKeyRingCollection readKeyring(Path path) throws Exception {
        try (InputStream in = PGPUtil.getDecoderStream(new BufferedInputStream(Files.newInputStream(path)))) {
            return new PGPPublicKeyRingCollection(in, new JcaKeyFingerprintCalculator());
        }
    }

    private static void verifyClearsigned(List<PGPPublicKeyRingCollection> keyrings, Path inRelease, Path output) throws Exception {
        try (ArmoredInputStream armored = new ArmoredInputStream(new BufferedInputStream(Files.newInputStream(inRelease)))) {
            if (!armored.isClearText()) {
                System.err.println("not a cleartext-signed message: " + inRelease);
                System.exit(2);
            }

            // ArmoredInputStream undoes dash-escaping. Split into lines and drop the trailing line
            // ending, which is not part of the signed text (RFC 4880 section 7.1).
            List<byte[]> lines = new ArrayList<>();
            ByteArrayOutputStream line = new ByteArrayOutputStream();
            int ch;
            while ((ch = armored.read()) >= 0 && armored.isClearText()) {
                if (ch == '\n') {
                    byte[] b = line.toByteArray();
                    int n = b.length;
                    if (n > 0 && b[n - 1] == '\r') {
                        n--;
                    }
                    lines.add(Arrays.copyOf(b, n));
                    line.reset();
                } else {
                    line.write(ch);
                }
            }
            if (line.size() > 0) {
                lines.add(line.toByteArray());
            }
            ByteArrayOutputStream text = new ByteArrayOutputStream();
            for (int i = 0; i < lines.size(); i++) {
                text.write(lines.get(i));
                if (i < lines.size() - 1) {
                    text.write('\n');
                }
            }

            PGPSignatureList sigs = readSignatures(armored);
            // Signatures are computed over the text with CRLF line endings.
            if (check(keyrings, sigs, crlf(text.toByteArray()))) {
                Files.write(output, text.toByteArray());
                System.exit(0);
            }
            System.exit(1);
        }
    }

    private static void verifyDetached(List<PGPPublicKeyRingCollection> keyrings, Path signature, Path message) throws Exception {
        PGPSignatureList sigs;
        try (InputStream in = PGPUtil.getDecoderStream(new BufferedInputStream(Files.newInputStream(signature)))) {
            sigs = readSignatures(in);
        }
        System.exit(check(keyrings, sigs, Files.readAllBytes(message)) ? 0 : 1);
    }

    private static PGPSignatureList readSignatures(InputStream in) throws Exception {
        Object o = new JcaPGPObjectFactory(in).nextObject();
        if (!(o instanceof PGPSignatureList)) {
            System.err.println("no OpenPGP signature found");
            System.exit(2);
        }
        return (PGPSignatureList) o;
    }

    private static boolean check(List<PGPPublicKeyRingCollection> keyrings, PGPSignatureList sigs, byte[] data) throws Exception {
        int good = 0;
        int bad = 0;
        for (PGPSignature sig : sigs) {
            PGPPublicKey key = null;
            for (PGPPublicKeyRingCollection ring : keyrings) {
                key = ring.getPublicKey(sig.getKeyID());
                if (key != null) {
                    break;
                }
            }
            if (key == null) {
                System.out.printf("NO_PUBKEY %016X%n", sig.getKeyID());
                continue;
            }
            sig.init(new JcaPGPContentVerifierBuilderProvider().setProvider("BC"), key);
            sig.update(data);
            if (sig.verify()) {
                good++;
                System.out.printf("GOODSIG %016X%n", sig.getKeyID());
            } else {
                bad++;
                System.out.printf("BADSIG %016X%n", sig.getKeyID());
            }
        }
        if (good == 0 || bad > 0) {
            System.err.printf("verification failed: %d good, %d bad signature(s)%n", good, bad);
        }
        return good > 0 && bad == 0;
    }

    private static byte[] crlf(byte[] in) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        for (byte b : in) {
            if (b == '\n') {
                out.write('\r');
            }
            out.write(b);
        }
        return out.toByteArray();
    }
}
