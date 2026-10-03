package sse.service.server;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.fail;

import java.util.Arrays;

import javax.crypto.SecretKey;

import org.junit.Test;

import sse.crypto.TupleEncryption;
import sse.domain.id.IndexAddress;
import sse.domain.update.EncryptedUpdateTuple;
import sse.domain.update.IndexEntry;
import sse.domain.update.UpdateOp;
import sse.domain.update.UpdateToken;
import sse.domain.update.UpdateTokenItem;
import sse.domain.update.UpdateTuple;
import sse.state.SSEServerState;
import vss.secretsharing.VerifiableShare;

public class UpdateServiceTest {

    private final UpdateService service = new UpdateService();

    @Test
    public void storesCompleteEntriesAndMatchingShares() throws Exception {
        SSEServerState state = new SSEServerState();
        IndexAddress firstAddress = address(1);
        IndexAddress secondAddress = address(2);
        IndexEntry firstEntry = indexEntry((byte) 1);
        IndexEntry secondEntry = indexEntry((byte) 2);
        VerifiableShare firstShare = new VerifiableShare();
        VerifiableShare secondShare = new VerifiableShare();
        UpdateToken token = token(
                new UpdateTokenItem(firstAddress, firstEntry),
                new UpdateTokenItem(secondAddress, secondEntry));

        service.update(state, token, new VerifiableShare[] {firstShare, secondShare});

        assertEquals(firstEntry, state.invertedIndexStore().get(firstAddress));
        assertEquals(secondEntry, state.invertedIndexStore().get(secondAddress));
        assertSame(firstShare, state.keyShareStore().getUpdateTupleShare(firstAddress));
        assertSame(secondShare, state.keyShareStore().getUpdateTupleShare(secondAddress));
    }

    @Test
    public void rejectsDuplicateAddressesWithoutChangingState() throws Exception {
        SSEServerState state = new SSEServerState();
        IndexAddress duplicateAddress = address(1);
        UpdateToken token = token(
                new UpdateTokenItem(duplicateAddress, indexEntry((byte) 1)),
                new UpdateTokenItem(duplicateAddress, indexEntry((byte) 2)));

        assertRejectedWithoutChanges(
                state,
                token,
                new VerifiableShare[] {new VerifiableShare(), new VerifiableShare()});
    }

    @Test
    public void existingAddressPreventsPartialBatchUpdate() throws Exception {
        SSEServerState state = new SSEServerState();
        IndexAddress existingAddress = address(1);
        IndexAddress newAddress = address(2);
        IndexEntry existingEntry = indexEntry((byte) 1);
        state.invertedIndexStore().put(existingAddress, existingEntry);

        UpdateToken token = token(
                new UpdateTokenItem(newAddress, indexEntry((byte) 2)),
                new UpdateTokenItem(existingAddress, indexEntry((byte) 3)));

        try {
            service.update(
                    state,
                    token,
                    new VerifiableShare[] {new VerifiableShare(), new VerifiableShare()});
            fail("Expected existing address to be rejected");
        } catch (IllegalArgumentException expected) {
            // Expected.
        }

        assertEquals(existingEntry, state.invertedIndexStore().get(existingAddress));
        assertFalse(state.invertedIndexStore().contains(newAddress));
        assertEquals(0, state.keyShareStore().snapshotUpdateTupleShareOrder().size());
    }

    @Test
    public void rejectsMismatchedEntryAndShareCounts() throws Exception {
        SSEServerState state = new SSEServerState();
        UpdateToken token = token(new UpdateTokenItem(address(1), indexEntry((byte) 1)));

        assertRejectedWithoutChanges(state, token, new VerifiableShare[0]);
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsNullServerState() throws Exception {
        UpdateToken token = token(new UpdateTokenItem(address(1), indexEntry((byte) 1)));
        service.update(null, token, new VerifiableShare[] {new VerifiableShare()});
    }

    private void assertRejectedWithoutChanges(SSEServerState state, UpdateToken token,
                                              VerifiableShare[] shares) {
        try {
            service.update(state, token, shares);
            fail("Expected update to be rejected");
        } catch (IllegalArgumentException expected) {
            // Expected.
        }

        assertEquals(0, state.invertedIndexStore().snapshot().size());
        assertEquals(0, state.keyShareStore().snapshotUpdateTupleShareOrder().size());
    }

    private static UpdateToken token(UpdateTokenItem... items) {
        return new UpdateToken(Arrays.asList(items));
    }

    private static IndexAddress address(int value) {
        return new IndexAddress(new byte[] {(byte) value});
    }

    private static IndexEntry indexEntry(byte maskedKeyValue) throws Exception {
        SecretKey tupleKey = TupleEncryption.generateRandomKey();
        byte[] iv = TupleEncryption.generateIv();
        EncryptedUpdateTuple encryptedTuple = new EncryptedUpdateTuple(
                TupleEncryption.encryptTuple(tupleKey, iv, new UpdateTuple("document", UpdateOp.ADD)),
                iv);
        byte[] maskedKey = new byte[16];
        Arrays.fill(maskedKey, maskedKeyValue);
        return new IndexEntry(encryptedTuple, maskedKey);
    }
}
