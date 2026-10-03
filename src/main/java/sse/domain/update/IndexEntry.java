package sse.domain.update;

import java.io.Serializable;
import java.util.Arrays;
import java.util.Objects;

public final class IndexEntry implements Serializable {

    private static final int MASKED_EPHEMERAL_KEY_LENGTH_BYTES = 16;

    private final EncryptedUpdateTuple encryptedTuple;
    private final byte[] maskedEphemeralKey;

    public IndexEntry(EncryptedUpdateTuple encryptedTuple, byte[] maskedEphemeralKey) {
        if (encryptedTuple == null) {
            throw new IllegalArgumentException("encryptedTuple cannot be null");
        }
        if (maskedEphemeralKey == null
                || maskedEphemeralKey.length != MASKED_EPHEMERAL_KEY_LENGTH_BYTES) {
            throw new IllegalArgumentException(
                    "maskedEphemeralKey must be exactly "
                            + MASKED_EPHEMERAL_KEY_LENGTH_BYTES + " bytes");
        }

        this.encryptedTuple = encryptedTuple;
        this.maskedEphemeralKey = Arrays.copyOf(maskedEphemeralKey, maskedEphemeralKey.length);
    }

    public EncryptedUpdateTuple encryptedTuple() {
        return encryptedTuple;
    }

    public byte[] maskedEphemeralKey() {
        return Arrays.copyOf(maskedEphemeralKey, maskedEphemeralKey.length);
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        IndexEntry that = (IndexEntry) o;
        return Objects.equals(encryptedTuple, that.encryptedTuple)
                && Arrays.equals(maskedEphemeralKey, that.maskedEphemeralKey);
    }

    @Override
    public int hashCode() {
        int result = Objects.hash(encryptedTuple);
        result = 31 * result + Arrays.hashCode(maskedEphemeralKey);
        return result;
    }

    @Override
    public String toString() {
        return "IndexEntry[" +
                "encryptedTuple=" + encryptedTuple +
                ", maskedEphemeralKeyLength=" + maskedEphemeralKey.length +
                ']';
    }
}
