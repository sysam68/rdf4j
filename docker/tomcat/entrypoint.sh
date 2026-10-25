#!/bin/sh
#
# Optionally imports additional TLS certificates (e.g. the CA used by an
# intranet reverse proxy that terminates TLS) into a writable copy of the
# JDK truststore, then starts the server as usual.
#
# Certificates are read from CERTS_DIR (typically a read-only mount). PEM
# bundles containing several certificates are split, because keytool only
# reads the first certificate of a file.
#
# The container runs as a non-root user while the JDK truststore
# ($JAVA_HOME/lib/security/cacerts) is owned by root, so the truststore is
# copied to a writable location and the JVM is pointed at it through the
# javax.net.ssl.trustStore system properties (via JAVA_TOOL_OPTIONS).
#
# Environment variables:
#   IMPORT_CERTS_ENABLED - set to "false" to skip the import entirely
#                           (default: enabled)
#   CERTS_DIR            - directory with .pem/.crt/.cer/.der files
#                          (default: /usr/local/tomcat/certs)
#   TRUSTSTORE_SOURCE    - truststore to extend
#                          (default: $JAVA_HOME/lib/security/cacerts)
#   TRUSTSTORE_PASSWORD  - truststore password (default: changeit)
set -e

install_repository_if_missing() {
    repository_id="$1"
    source_config="/opt/rdf4j/bootstrap/$repository_id/config.ttl"
    destination_config="/var/rdf4j/repositories/$repository_id/config.ttl"

    [ -f "$source_config" ] || return
    [ -f "$destination_config" ] && return

    mkdir -p "$(dirname "$destination_config")"
    cp "$source_config" "$destination_config"
    echo "[repository-bootstrap] installed $repository_id"
}

install_repository_if_missing "semantic-registry"

configure_workbench_default_server() {
    server_url="${RDF4J_WORKBENCH_DEFAULT_SERVER:-}"
    [ -n "$server_url" ] || return

    case "$server_url" in
        http://*|https://*) ;;
        *)
            echo "[workbench-config] RDF4J_WORKBENCH_DEFAULT_SERVER must use http or https" >&2
            exit 1
            ;;
    esac
    case "$server_url" in
        *[!A-Za-z0-9.:_/-]*)
            echo "[workbench-config] RDF4J_WORKBENCH_DEFAULT_SERVER contains unsupported characters" >&2
            exit 1
            ;;
    esac

    war_file="/usr/local/tomcat/webapps/rdf4j-workbench.war"
    [ -f "$war_file" ] || {
        echo "[workbench-config] missing Workbench archive: $war_file" >&2
        exit 1
    }

    workbench_dir="$(mktemp -d /tmp/rdf4j-workbench.XXXXXX)"
    trap 'rm -rf "$workbench_dir"' EXIT
    (
        cd "$workbench_dir"
        jar xf "$war_file" WEB-INF/web.xml
        awk -v server_url="$server_url" '
            $0 ~ "<param-name>default-server</param-name>" {
                print
                if (getline <= 0) exit 1
                sub("<param-value>[^<]*</param-value>", "\t\t\t<param-value>" server_url "</param-value>")
                print
                found = 1
                next
            }
            { print }
            END { if (!found) exit 1 }
        ' WEB-INF/web.xml > WEB-INF/web.xml.new
        mv WEB-INF/web.xml.new WEB-INF/web.xml
        jar --update --file "$war_file" -C "$workbench_dir" WEB-INF/web.xml
    )
    trap - EXIT
    rm -rf "$workbench_dir"
    echo "[workbench-config] default server set to $server_url"
}

configure_workbench_default_server

if [ "${IMPORT_CERTS_ENABLED:-true}" = "false" ]; then
    echo "[import-certs] disabled (IMPORT_CERTS_ENABLED=false)"
    exec "$@"
fi

CERTS_DIR="${CERTS_DIR:-/usr/local/tomcat/certs}"
TRUSTSTORE_SOURCE="${TRUSTSTORE_SOURCE:-${JAVA_HOME}/lib/security/cacerts}"
TRUSTSTORE_PASSWORD="${TRUSTSTORE_PASSWORD:-changeit}"

if [ ! -d "$CERTS_DIR" ]; then
    echo "[import-certs] ${CERTS_DIR} not mounted, starting without extra certificates"
    exec "$@"
fi

# Remove leftovers from previous restarts of this container, then create a
# fresh working directory.
rm -rf /tmp/rdf4j-truststore.* 2>/dev/null || true
WORK_DIR="$(mktemp -d /tmp/rdf4j-truststore.XXXXXX)"
PEM_DIR="$WORK_DIR/pem"
mkdir -p "$PEM_DIR"

# Split PEM bundles into individual certificate files.
for file in "$CERTS_DIR"/*; do
    [ -e "$file" ] || continue
    name="$(basename "$file" | tr -c 'A-Za-z0-9._-' '_')"
    case "$file" in
        *.pem | *.crt | *.cer)
            awk -v prefix="$PEM_DIR/$name" '
                /BEGIN CERTIFICATE/ { n++; out = sprintf("%s-%03d.pem", prefix, n); in_cert = 1 }
                in_cert { print > out }
                /END CERTIFICATE/ { close(out); in_cert = 0 }
            ' "$file"
            ;;
        *.der)
            cp "$file" "$PEM_DIR/$name.der"
            ;;
        *)
            echo "[import-certs] ignoring $file (unsupported extension)"
            ;;
    esac
done

count="$(ls -A "$PEM_DIR" 2>/dev/null | wc -l)"
if [ "$count" -eq 0 ]; then
    echo "[import-certs] no certificates found in $CERTS_DIR, starting without extra certificates"
    exec "$@"
fi

# Work on a writable copy of the JDK truststore so that the public CAs
# remain trusted as well.
TARGET_TRUSTSTORE="$WORK_DIR/cacerts"
cp "$TRUSTSTORE_SOURCE" "$TARGET_TRUSTSTORE"

# Import all certificates in a single JVM (java.util.KeyStore) rather than
# one keytool call per certificate: one keytool call spawns a full JVM,
# which would make startup unnecessarily slow.
IMPORTER="$WORK_DIR/ImportCerts.java"
cat > "$IMPORTER" <<'JAVA'
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.List;

public class ImportCerts {

    public static void main(String[] args) throws Exception {
        Path pemDir = Path.of(args[0]);
        Path targetTruststore = Path.of(args[1]);
        char[] password = args[2].toCharArray();

        KeyStore trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
        try (var in = Files.newInputStream(targetTruststore)) {
            try {
                trustStore.load(in, password);
            } catch (Exception wrongPassword) {
                // Modern JDK cacerts are passwordless: retry without password.
                trustStore = KeyStore.getInstance(KeyStore.getDefaultType());
                try (var retry = Files.newInputStream(targetTruststore)) {
                    trustStore.load(retry, null);
                }
            }
        }

        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        int imported = 0;
        int failed = 0;
        for (Path cert : sortedPemFiles(pemDir)) {
            try {
                for (X509Certificate x509 : readCertificates(cf, cert)) {
                    String alias = "ext-" + cert.getFileName() + "-" + imported;
                    trustStore.setCertificateEntry(alias, x509);
                    imported++;
                }
            } catch (Exception e) {
                failed++;
                System.out.println("[import-certs] WARNING: could not import " + cert + ": " + e);
            }
        }

        try (var out = Files.newOutputStream(targetTruststore)) {
            trustStore.store(out, password);
        }
        System.out.println("[import-certs] imported " + imported + " certificate(s), " + failed + " failure(s)");
        if (imported == 0) {
            System.exit(2);
        }
    }

    private static List<Path> sortedPemFiles(Path dir) throws Exception {
        List<Path> result = new ArrayList<>();
        try (var stream = Files.list(dir)) {
            stream.sorted().forEach(result::add);
        }
        return result;
    }

    private static List<X509Certificate> readCertificates(CertificateFactory cf, Path cert) throws Exception {
        // CertificateFactory.generateCertificates natively handles both DER
        // and PEM (including bundles with several certificates).
        try (var in = Files.newInputStream(cert)) {
            List<X509Certificate> certificates = new ArrayList<>();
            for (var c : cf.generateCertificates(in)) {
                certificates.add((X509Certificate) c);
            }
            return certificates;
        }
    }
}
JAVA

if java "$IMPORTER" "$PEM_DIR" "$TARGET_TRUSTSTORE" "$TRUSTSTORE_PASSWORD"; then
    echo "[import-certs] truststore extended successfully"
else
    echo "[import-certs] WARNING: certificate import reported failures, starting with the partial truststore"
fi

echo "[import-certs] truststore written to ${TARGET_TRUSTSTORE}"

# Point the JVM (Tomcat or Jetty) at the extended truststore. Replacing the
# default cacerts is safe because the copy above retains all public CAs.
export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Djavax.net.ssl.trustStore=$TARGET_TRUSTSTORE -Djavax.net.ssl.trustStorePassword=$TRUSTSTORE_PASSWORD"
echo "[import-certs] starting server with extended truststore"

exec "$@"
