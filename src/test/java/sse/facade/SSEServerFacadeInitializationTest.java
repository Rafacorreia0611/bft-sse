package sse.facade;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import sse.domain.setup.InitialStatePayload;
import sse.domain.state.EncryptedKeywordLocationMap;
import sse.domain.state.State;
import vss.secretsharing.VerifiableShare;

public class SSEServerFacadeInitializationTest {

    @Test
    public void initializesWithOnlyEncryptedMapAndMasterKeyShare() {
        SSEServerFacade facade = new SSEServerFacade();
        EncryptedKeywordLocationMap encryptedMap = encryptedMap();
        VerifiableShare masterKeyShare = new VerifiableShare();

        assertFalse(facade.isInitialized());
        assertTrue(facade.initializeState(encryptedMap, masterKeyShare));
        assertTrue(facade.isInitialized());
        assertEquals(encryptedMap, facade.getState().encryptedKeywordLocationMap());
        assertSame(masterKeyShare, facade.getMasterKey());
        assertFalse(facade.initializeState(encryptedMap, new VerifiableShare()));
    }

    @Test
    public void setupPayloadAndStateSurviveSerialization() {
        EncryptedKeywordLocationMap encryptedMap = encryptedMap();
        InitialStatePayload payload = new InitialStatePayload(encryptedMap);
        State state = new State(encryptedMap);

        assertEquals(payload, InitialStatePayload.deserialize(payload.serialize()));
        assertEquals(state, State.deserialize(state.serialize()));
    }

    private static EncryptedKeywordLocationMap encryptedMap() {
        return new EncryptedKeywordLocationMap(new byte[] {1, 2, 3}, new byte[12]);
    }
}
