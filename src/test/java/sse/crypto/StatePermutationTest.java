package sse.crypto;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;

import javax.crypto.SecretKey;

import org.junit.Test;

import sse.domain.id.SearchTokenValue;

public class StatePermutationTest {

    @Test
    public void backwardRecoversPreviousState() {
        SecretKey key = StatePermutation.generateKey();
        SearchTokenValue previousState = StatePermutation.generateRandomState();

        SearchTokenValue currentState = StatePermutation.forward(key, previousState);

        assertNotEquals(previousState, currentState);
        assertEquals(previousState, StatePermutation.backward(key, currentState));
    }
}
