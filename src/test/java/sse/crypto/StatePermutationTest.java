package sse.crypto;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;

import javax.crypto.Cipher;
import javax.crypto.SecretKey;

import org.junit.Test;

import sse.domain.id.SearchTokenValue;

public class StatePermutationTest {

    @Test
    public void backwardRecoversPreviousState() {
        SecretKey key = StatePermutation.generateKey();
        SearchTokenValue previousState = StatePermutation.generateRandomState();
        Cipher cipher = StatePermutation.createCipher();

        SearchTokenValue currentState = StatePermutation.forward(cipher, key, previousState);

        assertNotEquals(previousState, currentState);
        assertEquals(previousState, StatePermutation.backward(cipher, key, currentState));
    }

    @Test
    public void reusableCipherWorksAcrossKeys() {
        Cipher cipher = StatePermutation.createCipher();

        for (int i = 0; i < 2; i++) {
            SecretKey key = StatePermutation.generateKey();
            SearchTokenValue previousState = StatePermutation.generateRandomState();
            SearchTokenValue currentState = StatePermutation.forward(cipher, key, previousState);

            assertEquals(previousState, StatePermutation.backward(cipher, key, currentState));
        }
    }
}
