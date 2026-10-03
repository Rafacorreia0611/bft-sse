package sse.state;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

import org.junit.Test;

import sse.domain.id.IndexAddress;
import vss.secretsharing.VerifiableShare;

public class KeyShareStoreTest {

    @Test
    public void ordersMasterKeyBeforeTupleKeyShares() {
        KeyShareStore store = new KeyShareStore();
        IndexAddress firstAddress = address(1);
        IndexAddress secondAddress = address(2);
        VerifiableShare masterKeyShare = new VerifiableShare();
        VerifiableShare firstTupleKeyShare = new VerifiableShare();
        VerifiableShare secondTupleKeyShare = new VerifiableShare();

        assertFalse(store.hasMasterKeyShare());
        store.setMasterKeyShare(masterKeyShare);
        store.putUpdateTupleShare(firstAddress, firstTupleKeyShare);
        store.putUpdateTupleShare(secondAddress, secondTupleKeyShare);

        assertTrue(store.hasMasterKeyShare());
        assertEquals(
                Arrays.asList(firstAddress, secondAddress),
                store.snapshotUpdateTupleShareOrder());

        VerifiableShare[] shares = store.sharesInOrder(
                Arrays.asList(firstAddress, secondAddress),
                true);
        assertEquals(3, shares.length);
        assertSame(masterKeyShare, shares[0]);
        assertSame(firstTupleKeyShare, shares[1]);
        assertSame(secondTupleKeyShare, shares[2]);
    }

    @Test
    public void restoreCopiesTheProvidedMap() {
        IndexAddress address = address(1);
        VerifiableShare tupleKeyShare = new VerifiableShare();
        Map<IndexAddress, VerifiableShare> shares =
                new LinkedHashMap<IndexAddress, VerifiableShare>();
        shares.put(address, tupleKeyShare);
        KeyShareStore store = new KeyShareStore();

        store.restoreUpdateTupleShares(shares);
        shares.clear();

        assertSame(tupleKeyShare, store.getUpdateTupleShare(address));
    }

    private static IndexAddress address(int value) {
        return new IndexAddress(new byte[] {(byte) value});
    }
}
