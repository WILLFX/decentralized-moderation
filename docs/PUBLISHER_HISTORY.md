# Publisher history and archives

Transaction history is local to this browser origin, account, chain and moderation
contract. It contains public request data, not wallet keys. An archive action
never sends a transaction, cancels a request or changes a moderation case.

## Back up and archive

In Saved requests and transaction recovery:

1. Check active count, bytes, unresolved requests and eligible records.
2. Choose Download archive backup. The app selects a bounded batch of locally
   resolved records. A download request alone changes no archive state.
3. Select the saved JSON file and choose Verify saved archive backup. Verification
   compares exact bytes with the prepared snapshot. A filename or claimed status
   is not verification.
4. Choose Archive verified resolved records. The app rechecks the file and current
   records before one storage write. A changed snapshot or failed write keeps the
   old archive state; retry only after reading its feedback.

Full archived records remain locally available to history, My publications,
receipt checks and duplicate-submission confirmation. A confirmed submission
can still be under moderation or have a refund outstanding. Opening it refreshes
its receipt, case and membership evidence as before. A later receipt update that
changes an archived record makes it active again until a new backup covers it.

Requesting, unknown and unchecked records cannot be archived. Missing hashes,
age, unavailable receipts and imported status labels cannot clear uncertainty.
If all active records remain uncertain, resolve their receipts before creating
more matching requests. Never clear browser storage to bypass these guards.

History and publication lists are paged. Export displayed history page backs up
only that page. Importing a history page or archive file treats its contents as
unverified hints; it does not restore trusted confirmation or archive markers.
Keep the files and use receipt checks to establish current facts.

## Capacity and failures

The active journal permits 100 records and 256 KiB, with additional space reserved
before each send for returned hashes and receipt updates. Retained history,
including archives, is bounded to 2,000 records and 4 MiB. Backup files contain at
most 100 records and 1 MiB; large sets use repeated bounded batches. These are
application bounds, not blockchain limits or a promise of unlimited browser space.
Browser quota can refuse a write sooner. Archiving frees active slots; it does
not free total local storage. Export retains a recoverable copy but does not by
itself make room at the total bound. The app reports that limit and preserves
records rather than silently deleting evidence.

If a hash returns but a save fails, keep the tab open, export its relevant history
page, then retry saving. The in-memory recovery cache retains returned evidence
before fallible disk operations. Do not close the last copy before saving a file.
A corrupt stored history is retained and is not overwritten by a save retry.

All persistent history writers use a Web Lock shared by publisher tabs on the
same origin. A busy lock refuses the action with guidance; it does not queue a
transaction for later. Browsers without this coordination can still read/export
but cannot perform journal writes. Unsaved changes are merged against their
original snapshot so a stale tab cannot replace another tab's newer confirmation
or archive. Conflicting checked outcomes require another explicit receipt check.

Old array-format journals are read in place and migrate to the versioned storage
envelope on a successful write. The record identities and statuses are retained.
Old application versions cannot parse the new envelope and should be replaced by
the updated publisher. Browser origins have separate storage: changing localhost
to 127.0.0.1 or another origin requires deliberate history-file recovery.

The coordination and single-write design follow the
[Web Locks specification](https://www.w3.org/TR/web-locks/) and
[Web Storage specification](https://html.spec.whatwg.org/multipage/webstorage.html).
