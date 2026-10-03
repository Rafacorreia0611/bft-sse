package sse.domain.search;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.ObjectInput;
import java.io.ObjectInputStream;
import java.io.ObjectOutput;
import java.io.ObjectOutputStream;
import java.io.Serializable;
import java.util.Arrays;
import java.util.Objects;

import sse.domain.id.SearchTokenValue;

public final class SearchToken implements Serializable {

    private static final int KEYWORD_KEY_LENGTH_BYTES = 32;
    private static final int STATE_LENGTH_BYTES = 16;

    private final byte[] keywordKey;
    private final SearchTokenValue currentToken;
    private final int counter;

    public SearchToken(byte[] keywordKey, SearchTokenValue currentToken, int counter) {
        if (keywordKey == null || keywordKey.length != KEYWORD_KEY_LENGTH_BYTES) {
            throw new IllegalArgumentException(
                    "keywordKey must be exactly " + KEYWORD_KEY_LENGTH_BYTES + " bytes");
        }
        if (currentToken == null || currentToken.value().length != STATE_LENGTH_BYTES) {
            throw new IllegalArgumentException(
                    "currentToken must be exactly " + STATE_LENGTH_BYTES + " bytes");
        }
        if (counter <= 0) {
            throw new IllegalArgumentException("counter must be greater than zero");
        }
        this.keywordKey = keywordKey.clone();
        this.currentToken = currentToken;
        this.counter = counter;
    }

    public byte[] keywordKey() {
        return keywordKey.clone();
    }

    public SearchTokenValue currentToken() {
        return currentToken;
    }

    public int counter() {
        return counter;
    }

    public byte[] serialize() {
        try (ByteArrayOutputStream bos = new ByteArrayOutputStream();
             ObjectOutput out = new ObjectOutputStream(bos)) {
            out.writeObject(this);
            out.flush();
            bos.flush();
            return bos.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Error serializing search token", e);
        }
    }

    public static SearchToken deserialize(byte[] serializedToken) {
        if (serializedToken == null) {
            return null;
        }
        try (ByteArrayInputStream bis = new ByteArrayInputStream(serializedToken);
             ObjectInput in = new ObjectInputStream(bis)) {
            return (SearchToken) in.readObject();
        } catch (IOException | ClassNotFoundException e) {
            throw new RuntimeException("Error deserializing search token", e);
        }
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        SearchToken that = (SearchToken) o;
        return counter == that.counter
                && Arrays.equals(keywordKey, that.keywordKey)
                && Objects.equals(currentToken, that.currentToken);
    }

    @Override
    public int hashCode() {
        int result = Objects.hash(currentToken, counter);
        result = 31 * result + Arrays.hashCode(keywordKey);
        return result;
    }

    @Override
    public String toString() {
        return "SearchToken[" +
                "keywordKeyLength=" + keywordKey.length +
                ", currentToken=" + currentToken +
                ", counter=" + counter +
                ']';
    }
}
