# Participant guide

Use the [release entry](releases/TESTNET_MVP.md) to open a website and obtain the
profile for the deployment you want. A **profile** is a JSON file that identifies
the contracts and the connections the website should use. It contains configuration,
not a wallet or a private vote.

## Connect to the intended deployment

1. Obtain the profile from the release entry or the operator you chose. Select it
   in the website's Source area. Publisher and Reader also accept public profile
   links. Review the displayed deployment and accept the profile.
2. Publisher and Moderator let you choose a compatible browser wallet. Connect the
   account you intend to use and select the profile's chain. The release uses
   **Chiado, chain ID 10200**. Reader needs no wallet.
3. Use the application's deployment check before signing. Loading a profile or
   connecting an account does not itself submit a transaction.

The supplied local-Bee profiles are an option for people using a Bee on their own
device. For a hosted or different Bee service, use the operator's profile or the
existing connection settings. A loopback address such as `127.0.0.1` refers to the
device running your browser, not to a project server.

### Fees and access

Publishers need TEST for the review fee and Chiado test xDAI for wallet transactions.
Moderators need TEST for the fixed stake and test xDAI for transactions. The release
uses a minimum review fee of **0.01 TEST** and a stake of **10 TEST**. Check the
website's current amounts before signing. An operator can supply TEST; its public
faucet contract is described in the [operator guide](OPERATORS.md#fund-test-accounts).

Content and metadata uploads need a Bee upload service and a usable postage batch.
Use an operator's service or your own connection. Postage pays for Swarm storage;
it is separate from the moderation fee. Reader and Moderator need read access,
not an upload batch.

## Publish content

1. Open **Editor** in Swarm Publish. Write a title, select the item kind (such as
   article or image), supply the file format (such as `text/plain`) and add one to
   five topics. Add a description, language or source where useful. Save a draft
   file to keep the text after closing the tab.
2. Supply content. The built-in uploader accepts an unencrypted file up to 256 KiB.
   Apply the Bee endpoint and usable batch in Source & wallet, select the file and
   upload explicitly. The website checks the returned reference and downloaded
   bytes. Use the **raw-content profiles** for this route.
3. For an existing Bee file or collection, paste its reference and select collection
   mode. A collection groups files under paths, often with a default page. Open
   its root or default page for inspection. Use the **collection-content profiles**
   for the moderator and reader that will open it. The operator guide explains
   [matching content access](OPERATORS.md#match-content-access).
4. Inspect the content and the deployment's guidelines. Choose **Review & submit**,
   correct any field errors and review the metadata. Upload that metadata through
   the applied Bee connection. Content upload, metadata upload and case submission
   are separate actions.
5. Review the fee. If spending permission is needed, approve the displayed amount
   for the displayed moderation contract. Approval does not pay the fee or submit
   a case. Submit explicitly and check the transaction receipt.

Use **My publications** to return to submitted cases. Submission is not approval;
a preliminary outcome is not final. If a case becomes unresolved, the website can
show a refund owed to the original submitter. Withdrawing that refund is a separate
transaction. A later removal can take an approved listing out of the index.

Draft files keep authoring text. They do not restore wallet connection, uploaded
metadata checks or permission to send. **Saved requests** retains transaction
follow-up. See [publisher history](PUBLISHER_HISTORY.md) for backup and archive use.

## Moderate content

### Stake and choose work

Open Swarm Review, accept the intended profile, connect your account and check the
deployment. In **Stake**, refresh your balance, approve the exact stake if needed,
and stake. Frozen stake cannot make new commitments or challenges; existing
commitments still need to be revealed. Unsettled votes prevent withdrawal even
when no freeze remains.

Use **Browse cases** to find work. Eligibility depends on the account, case and
current voting group; being staked does not guarantee a place in every group.
Being eligible and declining to participate creates no penalty.

In **Selected case**, read the question, content, metadata, topics and guidelines.
For a listing, decide whether it belongs in the index. For a removal, decide whether
an existing listing should be taken out. The practical choices differ: **Approve
on a removal means remove**, not approve the original content again.

### Save, commit and reveal

1. Create or unlock private vote storage in **Recovery**. Save your choice, export
   its encrypted recovery file, then select that file and verify that it covers
   the choice. Keep the file and its password. Preparing a choice sends nothing.
2. Review and commit the choice while its commit window is open. Commitment sends
   a hash that hides the choice and its random secret. It also creates an obligation
   to reveal and settle later.
3. Return through **My work**. The case shows its deadlines and the next available
   action. Reconnect and unlock or import recovery as needed; refresh the case.
4. Reveal the saved choice during the shared reveal period. The website checks
   finalized chain state and the time left for inclusion before disclosing the
   secret. Allow time for wallet confirmation and network inclusion; a timer at
   zero does not extend the contract's deadline.
5. After a final or unresolved result, settle the vote. Settlement releases its
   outstanding-vote count and pays any reward or applies frozen time. It is a
   separate transaction, not an automatic transfer.

The release's reveal period is 30 minutes. Each contrary vote or missing reveal
adds **eight days** of frozen time. Multiple freezes accumulate. On an unresolved
initial case, a moderator who revealed gets neither a reward nor an outcome-based
freeze; missing reveals still receive the freeze.

**Change choice** is available only for a choice created in the current unlocked
session that can be proved unsent. Earlier secrets are retained, and a changed
choice needs a new verified recovery backup. A missing receipt or an imported file
does not make an attempted choice editable.

### Challenges and progress

A preliminary outcome normally opens a one-hour challenge period. A challenge is
an immediate **public vote against that outcome**, from an active moderator who
has not voted in the case. It needs no separate bond or review fee, but the vote
can earn a reward or frozen time when settled. Each case permits two challenges.
Read the outcome and consequences in the action review before signing.

Deadlines do not execute transactions. Closing a phase, drawing an outcome,
finalizing a case and settling votes can require a caller to pay gas. Follow the
case's available advancement actions. If a challenge cannot produce another
outcome, the preceding outcome can stand and ordinary settlement applies. A freeze
against that fallback is a settlement consequence, not proof of misconduct.

## Discover content

Open Swarm Search, review the Reader profile and choose **Use this source**. Enter
a topic and search. The website normalizes topic text and shows the applied query.
You can also load an optional category graph supplied as a JSON file to search
related groups of topics.

Results come from the selected deployment's index. Collection progress and display
pages are separate: an incomplete collection is not proof that no more matches
exist. Use the displayed continuation or paging controls.

A result shows its authenticated description and the listing that introduced it.
Choose **Check current listing** before opening content. That refreshes membership
and metadata at a new chain block. Content opens separately, leaving your search
available. Use a profile with the content access mode chosen for that submission.

## Return after an interruption

If a wallet response is missing, check the saved request and wallet activity before
trying again. Publisher uses **Saved requests**; Moderator uses **Transactions**.
Attach the transaction hash where available and check its receipt. The websites
keep the original account, deployment and request details; they do not resend an
uncertain request automatically.

Keep browser site data, authoring files and private recovery files until their work
is complete. Changing browser origin creates a different storage area. Connecting
the same wallet elsewhere does not recover a private vote by itself.

Send feedback through [GitHub Issues](https://github.com/WILLFX/decentralized-moderation/issues).
Include public case/transaction details where relevant, not private recovery data.
