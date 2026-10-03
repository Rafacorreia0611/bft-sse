package sse.service.server;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import javax.crypto.SecretKey;

import org.junit.Test;

import sse.crypto.TupleEncryption;
import sse.domain.id.IndexAddress;
import sse.domain.state.EncryptedKeywordLocationMap;
import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.update.IndexEntry;
import sse.domain.update.UpdateOp;
import sse.domain.update.UpdateTuple;
import sse.snapshot.SSEPlainSnapshotData;
import sse.state.SSEServerState;
import vss.secretsharing.VerifiableShare;

public class SnapshotServiceTest {

    private final SnapshotService service = new SnapshotService();

    @Test
    public void snapshotPreservesMasterKeyAndFastIndexEntries() throws Exception {
        SSEServerState source = new SSEServerState();
        EncryptedKeywordLocationMap encryptedMap =
                new EncryptedKeywordLocationMap(new byte[] {1, 2, 3}, new byte[12]);
        IndexAddress address = new IndexAddress(new byte[] {4, 5, 6});
        SecretKey tupleKey = TupleEncryption.generateRandomKey();
        IndexEntry entry = indexEntry(tupleKey);
        VerifiableShare masterKeyShare = new VerifiableShare();
        VerifiableShare tupleKeyShare = new VerifiableShare();
        source.setEncryptedKeywordLocationMap(encryptedMap);
        source.keyShareStore().setMasterKeyShare(masterKeyShare);
        source.invertedIndexStore().put(address, entry);
        source.keyShareStore().putUpdateTupleShare(address, tupleKeyShare);

        SSEPlainSnapshotData snapshot = service.getPlainSnapshotData(source);
        VerifiableShare[] shares = service.getSnapshotShares(
                source,
                snapshot.updateTupleShareOrder(),
                snapshot.hasMasterKeyShare());
        SSEPlainSnapshotData restoredSnapshot =
                SSEPlainSnapshotData.deserialize(snapshot.serialize());
        SSEServerState restored = new SSEServerState();
        Map<IndexAddress, VerifiableShare> restoredTupleShares =
                restoredSnapshot.updateTupleShares(shares);
        service.installSnapshot(
                restored,
                restoredSnapshot,
                restoredSnapshot.masterKeyShare(shares),
                restoredTupleShares);

        assertTrue(restored.isInitialized());
        assertEquals(encryptedMap, restored.encryptedKeywordLocationMap());
        IndexEntry restoredEntry = restored.invertedIndexStore().get(address);
        assertArrayEquals(entry.maskedEphemeralKey(), restoredEntry.maskedEphemeralKey());
        assertArrayEquals(entry.encryptedTuple().iv(), restoredEntry.encryptedTuple().iv());
        assertEquals(
                new UpdateTuple("document", UpdateOp.ADD),
                TupleEncryption.decryptTuple(
                        tupleKey,
                        restoredEntry.encryptedTuple().iv(),
                        restoredEntry.encryptedTuple().encryptedTuple()));
        assertSame(masterKeyShare, restored.keyShareStore().masterKeyShare());
        assertSame(tupleKeyShare, restored.keyShareStore().getUpdateTupleShare(address));
    }

    @Test
    public void snapshotProtectsItsIndexAndShareOrder() throws Exception {
        EncryptedKeywordLocationMap encryptedMap =
                new EncryptedKeywordLocationMap(new byte[] {1, 2, 3}, new byte[12]);
        IndexAddress address = new IndexAddress(new byte[] {4, 5, 6});
        IndexEntry entry = indexEntry(TupleEncryption.generateRandomKey());
        Map<IndexAddress, IndexEntry> invertedIndex =
                new LinkedHashMap<IndexAddress, IndexEntry>();
        invertedIndex.put(address, entry);
        List<IndexAddress> shareOrder = new ArrayList<IndexAddress>();
        shareOrder.add(address);

        SSEPlainSnapshotData snapshot = new SSEPlainSnapshotData(
                encryptedMap,
                invertedIndex,
                shareOrder,
                true);
        invertedIndex.clear();
        shareOrder.clear();

        assertEquals(1, snapshot.invertedIndex().size());
        assertEquals(1, snapshot.updateTupleShareOrder().size());

        snapshot.invertedIndex().clear();
        snapshot.updateTupleShareOrder().clear();

        assertEquals(1, snapshot.invertedIndex().size());
        assertEquals(1, snapshot.updateTupleShareOrder().size());
    }

    private static IndexEntry indexEntry(SecretKey tupleKey) throws Exception {
        byte[] iv = TupleEncryption.generateIv();
        EncryptedUpdateTuple encryptedTuple = new EncryptedUpdateTuple(
                TupleEncryption.encryptTuple(tupleKey, iv, new UpdateTuple("document", UpdateOp.ADD)),
                iv);
        return new IndexEntry(encryptedTuple, new byte[16]);
    }
}
