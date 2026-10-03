package sse.domain.state;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.io.Serializable;
import java.util.Objects;

import sse.domain.id.SearchTokenValue;

public final class KeywordBlock implements Serializable {

    private final boolean locked;
    private final KeywordState keywordState;

    public KeywordBlock(boolean locked, KeywordState keywordState) {
        this.locked = locked;
        this.keywordState = keywordState;
    }

    public static KeywordBlock empty() {
        return new KeywordBlock(false, null);
    }

    public boolean locked() {
        return locked;
    }

    public KeywordState keywordState() {
        return keywordState;
    }

    public KeywordBlock withLock(boolean locked) {
        return new KeywordBlock(locked, keywordState);
    }

    public KeywordBlock withKeywordState(KeywordState keywordState) {
        return new KeywordBlock(locked, keywordState);
    }

    public byte[] serialize() {
        try (ByteArrayOutputStream bos = new ByteArrayOutputStream();
             DataOutputStream out = new DataOutputStream(bos)) {
            out.writeByte(locked ? 1 : 0);
            out.writeByte(keywordState == null ? 0 : 1);
            if (keywordState != null) {
                byte[] token = keywordState.currentToken().value();
                out.writeInt(keywordState.counter());
                out.writeInt(token.length);
                out.write(token);
            }
            out.flush();
            return bos.toByteArray();
        } catch (IOException e) {
            throw new RuntimeException("Error serializing keyword block", e);
        }
    }

    public static KeywordBlock deserialize(byte[] serializedBlock) {
        if (serializedBlock == null || serializedBlock.length == 0) {
            return empty();
        }

        try (ByteArrayInputStream bis = new ByteArrayInputStream(serializedBlock);
             DataInputStream in = new DataInputStream(bis)) {
            boolean locked = readFlag(in, "lock");
            boolean hasState = readFlag(in, "state presence");
            if (!hasState) {
                return new KeywordBlock(locked, null);
            }

            int counter = in.readInt();
            int tokenLength = in.readInt();
            if (tokenLength != KeywordState.STATE_LENGTH_BYTES) {
                throw new IllegalArgumentException(
                        "Keyword block state must be exactly "
                                + KeywordState.STATE_LENGTH_BYTES + " bytes");
            }

            byte[] token = new byte[tokenLength];
            in.readFully(token);
            return new KeywordBlock(locked, new KeywordState(new SearchTokenValue(token), counter));
        } catch (IOException e) {
            throw new RuntimeException("Error deserializing keyword block", e);
        }
    }

    private static boolean readFlag(DataInputStream in, String name) throws IOException {
        int value = in.readUnsignedByte();
        if (value != 0 && value != 1) {
            throw new IllegalArgumentException("Keyword block " + name + " flag must be 0 or 1");
        }
        return value == 1;
    }

    @Override
    public boolean equals(Object o) {
        if (this == o) {
            return true;
        }
        if (o == null || getClass() != o.getClass()) {
            return false;
        }
        KeywordBlock that = (KeywordBlock) o;
        return locked == that.locked
                && Objects.equals(keywordState, that.keywordState);
    }

    @Override
    public int hashCode() {
        return Objects.hash(locked, keywordState);
    }

    @Override
    public String toString() {
        return "KeywordBlock[" +
                "locked=" + locked +
                ", keywordState=" + keywordState +
                ']';
    }
}
