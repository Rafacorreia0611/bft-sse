package sse.domain.update;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;

import javax.crypto.SecretKey;

import org.junit.Test;

import sse.crypto.TupleEncryption;

public class IndexEntryTest {

    @Test
    public void preservesEncryptedTupleAndMaskedKey() throws Exception {
        EncryptedUpdateTuple encryptedTuple = encryptedTuple();
        byte[] maskedKey = maskedKey();

        IndexEntry entry = new IndexEntry(encryptedTuple, maskedKey);

        assertEquals(encryptedTuple, entry.encryptedTuple());
        assertArrayEquals(maskedKey, entry.maskedEphemeralKey());
    }

    @Test
    public void protectsMaskedKeyFromModification() throws Exception {
        byte[] maskedKey = maskedKey();
        IndexEntry entry = new IndexEntry(encryptedTuple(), maskedKey);

        maskedKey[0] = 99;
        byte[] returnedKey = entry.maskedEphemeralKey();
        returnedKey[1] = 99;

        assertArrayEquals(maskedKey(), entry.maskedEphemeralKey());
    }

    @Test
    public void comparesEntriesByContent() throws Exception {
        EncryptedUpdateTuple encryptedTuple = encryptedTuple();
        IndexEntry first = new IndexEntry(encryptedTuple, maskedKey());
        IndexEntry same = new IndexEntry(encryptedTuple, maskedKey());
        byte[] differentKey = maskedKey();
        differentKey[0] = 1;
        IndexEntry different = new IndexEntry(encryptedTuple, differentKey);

        assertEquals(first, same);
        assertEquals(first.hashCode(), same.hashCode());
        assertNotEquals(first, different);
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsMaskedKeyWithWrongLength() throws Exception {
        new IndexEntry(encryptedTuple(), new byte[15]);
    }

    private static EncryptedUpdateTuple encryptedTuple() throws Exception {
        SecretKey tupleKey = TupleEncryption.generateRandomKey();
        byte[] iv = TupleEncryption.generateIv();
        return new EncryptedUpdateTuple(
                TupleEncryption.encryptTuple(tupleKey, iv, new UpdateTuple("document", UpdateOp.ADD)),
                iv);
    }

    private static byte[] maskedKey() {
        return new byte[] {
                0, 1, 2, 3, 4, 5, 6, 7,
                8, 9, 10, 11, 12, 13, 14, 15
        };
    }
}
