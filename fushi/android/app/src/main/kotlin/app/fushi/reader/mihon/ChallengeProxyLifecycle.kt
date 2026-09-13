package app.fushi.reader.mihon

/** A session may report completion only after its pending proxy mutation is undone. */
internal class ChallengeProxyLifecycle(private val clear: (() -> Unit) -> Unit) {
    private var installing = false
    private var applied = false
    private var clearing = false
    private var completion: (() -> Unit)? = null
    private var completed = false

    fun begin() {
        check(!installing && !applied && completion == null)
        installing = true
    }

    fun installed() {
        check(installing)
        installing = false
        applied = true
        if (completion != null) clearThenComplete()
    }

    fun close(done: () -> Unit) {
        if (completion != null || completed) return
        completion = done
        if (installing) return
        if (applied) clearThenComplete() else complete()
    }

    private fun clearThenComplete() {
        if (clearing) return
        clearing = true
        clear {
            applied = false
            complete()
        }
    }

    private fun complete() {
        if (completed) return
        completed = true
        completion?.invoke()
        completion = null
    }
}
