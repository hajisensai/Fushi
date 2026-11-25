package app.fushi.reader

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * The panel's first messages (the companion's "ready") can come before the
 * relay connection: they wait and go out in order once it is up.
 */
class SecondScreenRelayOutboxTest {
    private val outbox = SecondScreenRelayOutbox<String>()
    private val sent = mutableListOf<String>()
    private var relayTakes = true

    private val sink = SecondScreenRelayOutbox.Sink<String> { message ->
        if (relayTakes) sent += message
        relayTakes
    }

    @Test
    fun messagesBeforeTheConnectionWaitAndGoOutInOrder() {
        assertTrue(outbox.offer("ready"))
        assertTrue(outbox.offer("ui"))
        assertEquals(2, outbox.pendingCount())
        assertTrue(sent.isEmpty())

        assertTrue(outbox.connect(sink))
        assertEquals(listOf("ready", "ui"), sent)
        assertEquals(0, outbox.pendingCount())

        assertTrue(outbox.offer("request"))
        assertEquals(listOf("ready", "ui", "request"), sent)
    }

    @Test
    fun aConnectedRelayThatRefusesReportsIt() {
        assertTrue(outbox.connect(sink))
        relayTakes = false
        assertFalse(outbox.offer("ready"))
    }

    @Test
    fun aRefusedWaitingMessageClosesTheOutbox() {
        outbox.offer("ready")
        outbox.offer("ui")
        relayTakes = false
        assertFalse(outbox.connect(sink))
        assertEquals(0, outbox.pendingCount())
        relayTakes = true
        assertFalse(outbox.offer("later"))
        assertTrue(sent.isEmpty())
    }

    @Test
    fun closedTakesNothingAndDropsWhatWaited() {
        outbox.offer("ready")
        outbox.close()
        assertEquals(0, outbox.pendingCount())
        assertFalse(outbox.offer("later"))
        assertFalse(outbox.connect(sink))
        assertTrue(sent.isEmpty())
    }
}
