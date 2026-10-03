package sse.state;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.util.LinkedHashMap;
import java.util.Map;

import javax.crypto.SecretKey;

import org.junit.Test;

import sse.crypto.TupleEncryption;
import sse.domain.id.IndexAddress;
import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.update.IndexEntry;
import sse.domain.update.UpdateOp;
import sse.domain.update.UpdateTuple;

public class InvertedIndexStoreTest {

    @Test
    public void storesTheCompleteIndexEntry() throws Exception {
        InvertedIndexStore store = new InvertedIndexStore();
        IndexAddress address = new IndexAddress(new byte[] {1, 2, 3});
        IndexEntry entry = indexEntry();

        store.put(address, entry);

        assertTrue(store.contains(address));
        assertEquals(entry, store.get(address));
        assertEquals(entry.encryptedTuple(), store.get(address).encryptedTuple());
        assertEquals(16, store.get(address).maskedEphemeralKey().length);
    }

    @Test
    public void snapshotAndRestoreDoNotShareTheirMapsWithTheStore() throws Exception {
        IndexAddress address = new IndexAddress(new byte[] {1, 2, 3});
        IndexEntry entry = indexEntry();
        InvertedIndexStore store = new InvertedIndexStore();
        store.put(address, entry);

        Map<IndexAddress, IndexEntry> snapshot = store.snapshot();
        snapshot.clear();
        assertTrue(store.contains(address));

        Map<IndexAddress, IndexEntry> restoredEntries = new LinkedHashMap<IndexAddress, IndexEntry>();
        restoredEntries.put(address, entry);
        InvertedIndexStore restoredStore = new InvertedIndexStore();
        restoredStore.restore(restoredEntries);
        restoredEntries.clear();

        assertTrue(restoredStore.contains(address));
        assertFalse(restoredStore.snapshot().isEmpty());
    }

    private static IndexEntry indexEntry() throws Exception {
        SecretKey tupleKey = TupleEncryption.generateRandomKey();
        byte[] iv = TupleEncryption.generateIv();
        EncryptedUpdateTuple encryptedTuple = new EncryptedUpdateTuple(
                TupleEncryption.encryptTuple(tupleKey, iv, new UpdateTuple("document", UpdateOp.ADD)),
                iv);
        return new IndexEntry(encryptedTuple, new byte[16]);
    }
}
