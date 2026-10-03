package sse.domain.state;

import static org.junit.Assert.assertEquals;

import java.nio.ByteBuffer;

import org.junit.Test;

import sse.domain.id.SearchTokenValue;

public class KeywordBlockTest {

    @Test
    public void serializesAndRestoresFastKeywordState() {
        KeywordBlock block = new KeywordBlock(
                true,
                new KeywordState(new SearchTokenValue(new byte[16]), 4));

        assertEquals(block, KeywordBlock.deserialize(block.serialize()));
    }

    @Test
    public void emptyOramContentProducesEmptyBlock() {
        assertEquals(KeywordBlock.empty(), KeywordBlock.deserialize(null));
        assertEquals(KeywordBlock.empty(), KeywordBlock.deserialize(new byte[0]));
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsLegacyRsaSizedState() {
        KeywordBlock.deserialize(serializedBlockWithTokenLength(256));
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsInvalidLockFlag() {
        KeywordBlock.deserialize(new byte[] {2, 0});
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsInvalidStatePresenceFlag() {
        KeywordBlock.deserialize(new byte[] {0, 2});
    }

    private static byte[] serializedBlockWithTokenLength(int tokenLength) {
        return ByteBuffer.allocate(2 + Integer.BYTES + Integer.BYTES + tokenLength)
                .put((byte) 0)
                .put((byte) 1)
                .putInt(1)
                .putInt(tokenLength)
                .put(new byte[tokenLength])
                .array();
    }
}
