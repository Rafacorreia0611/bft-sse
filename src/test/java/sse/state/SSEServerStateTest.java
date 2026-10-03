package sse.state;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import sse.domain.state.EncryptedKeywordLocationMap;
import vss.secretsharing.VerifiableShare;

public class SSEServerStateTest {

    @Test
    public void requiresEncryptedMapAndMasterKeyShareForInitialization() {
        SSEServerState emptyState = new SSEServerState();
        assertFalse(emptyState.isInitialized());

        SSEServerState mapOnlyState = new SSEServerState();
        mapOnlyState.setEncryptedKeywordLocationMap(encryptedMap());
        assertFalse(mapOnlyState.isInitialized());

        SSEServerState masterKeyOnlyState = new SSEServerState();
        masterKeyOnlyState.keyShareStore().setMasterKeyShare(new VerifiableShare());
        assertFalse(masterKeyOnlyState.isInitialized());

        SSEServerState initializedState = new SSEServerState();
        initializedState.setEncryptedKeywordLocationMap(encryptedMap());
        initializedState.keyShareStore().setMasterKeyShare(new VerifiableShare());
        assertTrue(initializedState.isInitialized());
    }

    private static EncryptedKeywordLocationMap encryptedMap() {
        return new EncryptedKeywordLocationMap(new byte[] {1, 2, 3}, new byte[12]);
    }
}
