package sse.domain.setup;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.ObjectInput;
import java.io.ObjectInputStream;
import java.io.ObjectOutput;
import java.io.ObjectOutputStream;
import java.io.Serializable;
import java.util.Objects;

import sse.domain.state.EncryptedKeywordLocationMap;

public final class InitialStatePayload implements Serializable {

    private final EncryptedKeywordLocationMap encryptedKeywordLocationMap;

    public InitialStatePayload(EncryptedKeywordLocationMap encryptedKeywordLocationMap) {
        if (encryptedKeywordLocationMap == null) {
            throw new IllegalArgumentException("encryptedKeywordLocationMap cannot be null");
        }
        this.encryptedKeywordLocationMap = encryptedKeywordLocationMap;
    }

    public EncryptedKeywordLocationMap encryptedKeywordLocationMap() {
        return encryptedKeywordLocationMap;
    }

    public byte[] serialize() {
        try (ByteArrayOutputStream bos = new ByteArrayOutputStream();
             ObjectOutput out = new ObjectOutputStream(bos)) {
            out.writeObject(this);
            out.flush();
            bos.flush();
            return bos.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Error serializing initial state payload", e);
        }
    }

    public static InitialStatePayload deserialize(byte[] serializedPayload) {
        if (serializedPayload == null) {
            return null;
        }
        try (ByteArrayInputStream bis = new ByteArrayInputStream(serializedPayload);
             ObjectInput in = new ObjectInputStream(bis)) {
            Object obj = in.readObject();
            if (!(obj instanceof InitialStatePayload)) {
                throw new RuntimeException("Initial state payload has invalid type");
            }
            return (InitialStatePayload) obj;
        } catch (IOException | ClassNotFoundException e) {
            throw new RuntimeException("Error deserializing initial state payload", e);
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
        InitialStatePayload that = (InitialStatePayload) o;
        return Objects.equals(encryptedKeywordLocationMap, that.encryptedKeywordLocationMap);
    }

    @Override
    public int hashCode() {
        return Objects.hash(encryptedKeywordLocationMap);
    }

    @Override
    public String toString() {
        return "InitialStatePayload[" +
                "encryptedKeywordLocationMap=" + encryptedKeywordLocationMap +
                ']';
    }
}
