# Publisher history and archives

Publisher keeps transaction follow-up in browser storage, scoped to the account,
chain and moderation contract. These records contain public request data, not
wallet keys. They help **My publications** find submitted cases and **Saved
requests** resume receipt checks.

A transaction hash is not a confirmed receipt. Check the affected record after a
wallet interruption. Missing hashes, unavailable receipts and imported status
labels do not clear uncertainty. Keep the original record and wallet activity
until the request is resolved; no recovery route automatically resends it.

## Back up resolved records

When active history fills, use the existing archive controls in Saved requests:

1. Choose **Download archive backup**. The application prepares a bounded set of
   locally resolved records.
2. Select the saved JSON file and choose **Verify saved archive backup**. The
   application compares its bytes with the prepared records.
3. Choose **Archive verified resolved records**. The application checks that the
   file and current records still agree before writing the archive state.

A download alone does not archive anything. Failed or changed backups leave the
records active. Uncertain records cannot be archived. Archiving does not cancel a
transaction, settle a case or remove publication follow-up.

Archived records remain available to history, My publications and receipt checks.
A later receipt change can make a record active again until another backup covers
it. A confirmed submission may still need moderation or have a refund owed.

**Export displayed history page** saves only that page. Imported history and
archive files are untrusted hints until receipt checks establish their current
state. They do not restore confirmation authority from a claimed saved status.

## Storage and return

Active history permits 100 records and 256 KiB. Retained history, including archives,
is bounded to 2,000 records and 4 MiB. Archive backup files contain at most 100
records and 1 MiB; use repeated batches for larger sets. Browser quota can be lower.
Archiving frees active slots, not the total retained-storage limit.

If a hash returns but saving fails, keep the tab open, export the relevant history
page and use the save retry. Preserve that copy before closing the tab. Do not
clear site data to bypass a capacity or uncertain-request guard.

Publisher coordinates writes between tabs with Web Locks. A browser without that
coordination can read/export history but cannot perform journal writes. A busy
lock refuses the action rather than queueing a transaction for later.

Changing origin changes the browser storage area: `localhost`, `127.0.0.1` and a
hosted domain are different origins. Keep exported history when moving between
them. Public history is separate from authoring drafts and Moderator's encrypted
private-vote recovery. Older publisher builds may not read the current journal
format; use the matching release when recovering it.
