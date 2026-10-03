package sse.demo.server;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertSame;
import static org.junit.Assert.assertTrue;

import java.util.Arrays;

import org.junit.Test;

import confidential.ConfidentialMessage;
import sse.demo.messages.ResponseStatus;
import sse.domain.setup.InitialStatePayload;
import sse.domain.state.EncryptedKeywordLocationMap;
import sse.domain.state.State;
import vss.secretsharing.VerifiableShare;

public class SSEServerHandlerTest {

    @Test
    public void initializesAndReturnsExactlyOneMasterKeyShare() {
        SSEServerHandler handler = new SSEServerHandler();
        EncryptedKeywordLocationMap encryptedMap =
                new EncryptedKeywordLocationMap(new byte[] {1, 2, 3}, new byte[12]);
        VerifiableShare masterKeyShare = new VerifiableShare();

        assertTrue(handler.initializeState(
                new InitialStatePayload(encryptedMap),
                masterKeyShare));

        ConfidentialMessage response = handler.handleState();
        assertEquals(ResponseStatus.OK.ordinal(), Byte.toUnsignedInt(response.getPlainData()[0]));
        assertEquals(1, response.getShares().length);
        assertSame(masterKeyShare, response.getShares()[0]);

        State state = State.deserialize(Arrays.copyOfRange(
                response.getPlainData(),
                1,
                response.getPlainData().length));
        assertEquals(encryptedMap, state.encryptedKeywordLocationMap());
    }
}
