# Distribute a publisher profile

This guide is for operators preparing public configuration and setup links. For
the publishing task itself, use the [participant guide](PARTICIPANTS.md#publish-content).
Service and storage responsibilities are in the [operator guide](OPERATORS.md).

## Start with public configuration

Use the release's [raw-content Publisher profile](../deployments/chiado/profiles/raw/publisher.json)
or [collection-content Publisher profile](../deployments/chiado/profiles/collections/publisher.json)
when connecting to its Chiado contracts. For another deployment, replace all
contract addresses/code hashes and the guidelines identity with that deployment's
values. Adapt public connection URLs to the services you provide.

The optional `display` object supplies a token symbol and decimal precision.
Optional `upload` contains an `endpoint` and `postageBatchId`; that batch must be
usable by the uploading node. A private file can also carry `upload.authorization`,
but a public profile or setup link must not contain it. Participants can apply
private upload access separately through Source & wallet.

Select `contentPath: "bytes"` for the in-page raw uploader and `"bzz"` for an
externally uploaded Bee file or collection. Keep Moderator and Reader access
consistent with that choice. The website and content viewer must have different
origins. See [matching content access](OPERATORS.md#match-content-access).

## Create an exact-byte setup link

1. Host the public JSON at an HTTPS URL with browser GET access from the Publisher
   origin. Profile fetches omit credentials/referrers, refuse redirects and accept
   at most 64 KiB. Loopback HTTP is supported for local connections.
2. Generate a link using the existing helper:

   ```sh
   python tools/publisher_setup.py --profile publisher.json \
     --profile-url https://profiles.example/publisher.json \
     --app-url https://publish.example/
   ```

   These example hostnames must be replaced with your actual public locations.
   The helper reads the file and prints a link; it does not host or fetch it.
3. Distribute the link and deployment identity through your normal public channel.
   Any byte change, including JSON whitespace, changes the fingerprint and needs
   a new link.

Opening the link fills the candidate URL/fingerprint inputs. A participant chooses
to fetch it, reviews its identity and accepts it through **Use reviewed profile**.
Opening or accepting a profile does not connect a wallet or authorize a transaction.
Local JSON-file selection follows the same review step.

## Applying personal upload access

Publisher's existing **Use my own Bee node** settings take an endpoint, batch and
optional authorization. They can point to the user's node or a service the user
is authorized to use. Edits take effect only after **Apply**. Changing access keeps
authoring text but clears content/metadata readiness that depended on the old
connection. These personal settings stay in memory and are excluded from draft
and public setup-link exports.
