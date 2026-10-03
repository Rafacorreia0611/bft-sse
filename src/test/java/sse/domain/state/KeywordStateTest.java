package sse.domain.state;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

import sse.domain.id.SearchTokenValue;

public class KeywordStateTest {

    @Test
    public void acceptsSixteenByteStateAndPositiveCounter() {
        SearchTokenValue currentToken = new SearchTokenValue(new byte[16]);

        KeywordState state = new KeywordState(currentToken, 3);

        assertEquals(currentToken, state.currentToken());
        assertEquals(3, state.counter());
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsStateWithWrongLength() {
        new KeywordState(new SearchTokenValue(new byte[15]), 1);
    }

    @Test(expected = IllegalArgumentException.class)
    public void rejectsNonPositiveCounter() {
        new KeywordState(new SearchTokenValue(new byte[16]), 0);
    }
}
