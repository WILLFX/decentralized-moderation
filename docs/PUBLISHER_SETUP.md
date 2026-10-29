# Publisher setup and content hand-off

The publisher has no built-in operator or deployment address. A deployment
operator supplies a public profile through a trusted announcement channel.
Each user reviews that profile and can apply their own Bee access settings.

## Operator: distribute a reviewed public profile

1. Start with the verified deployment record for your own contracts. Record the
   chain ID, moderation/stakes/index/token addresses, the Keccak-256 hash of each
   runtime, and the immutable guidelines version/hash. Check the deployment's
   links; `contracts/script/Deploy.s.sol` includes the stack verification logic.
2. Create the publisher JSON below using those pins and public access URLs.
   `display` is an optional label/precision setting; check it against the token.
   Do not include an upload authorization header or a private RPC access URL.
3. Host those exact bytes at a public HTTPS URL. Allow GET requests from the
   publisher origin using CORS. The client omits credentials/referrers, refuses
   redirects and limits profiles to 64 KiB. Loopback HTTP is supported for local
   work; a loopback setup link does not give another person's device access to
   your local service.
4. Generate a setup link without fetching, hosting or sending anything:

   ```sh
   python tools/publisher_setup.py --profile public-profile.json \
     --profile-url https://your-service.example/publisher.json \
     --app-url https://your-publisher.example/
   ```

5. Share that link and the deployment identity through the announcement channel
   your users trust. A hash supplied by an unknown party does not make that party
   trustworthy. Changing even JSON whitespace requires a new fingerprint/link.

The following is a format outline. Replace every placeholder with verified data;
it is not a working deployment profile:

```json
{
  "deployment": {
    "chainId": 10200,
    "moderation": {"address": "<20-byte 0x address>", "codeHash": "<32-byte 0x hash>"},
    "stakes": {"address": "<20-byte 0x address>", "codeHash": "<32-byte 0x hash>"},
    "index": {"address": "<20-byte 0x address>", "codeHash": "<32-byte 0x hash>"},
    "token": {"address": "<20-byte 0x address>", "codeHash": "<32-byte 0x hash>"},
    "guidelines": {"version": 1, "hash": "<32-byte 0x hash>"}
  },
  "rpcUrl": "https://your-public-rpc.example/",
  "guidelinesUrl": "./MODERATION_GUIDELINES.md",
  "display": {"decimals": 16, "symbol": "TEST"},
  "contentGatewayUrl": "https://your-content-gateway.example/",
  "contentPath": "bytes"
}
```

Supported moderation chains remain Gnosis (100) and Chiado (10200). The example's
display settings are illustrative, not a default for other tokens. Optional
`upload` contains `endpoint` and `postageBatchId`. The batch must be usable by the
node doing the upload. A private local file can additionally contain
`upload.authorization`; the public-link generator refuses that field. Never
publish private access settings with a public profile. No profile is packaged
inside the static website collection.

## Publisher: select the deployment and your Bee node

Opening a setup link only fills its URL/fingerprint inputs. Fetch the candidate,
compare the displayed chain, contract addresses and exact-byte fingerprint with
the source you trust, then choose Use reviewed profile. A local file follows the
same review step. No wallet is contacted merely by loading or accepting a file.
The runtime/link/guidelines and wallet checks still run before payment.

Use my own Bee node lets a user apply an endpoint, postage batch and optional
authorization independently of the deployment pins. Edits make the old access
settings inactive until Apply. These values stay in memory and are excluded from
authoring files and generated setup links. Changing them clears content and
metadata review readiness.

## Content, metadata and payment are separate

The built-in uploader handles raw unencrypted files up to 256 KiB. It calculates
the reference locally, uploads with the applied Bee settings and checks the
returned reference plus exact readback before replacing the form's reference.
An interrupted response may still have stored public bytes; the page retains the
expected reference and never retries an upload automatically. Readback does not
establish replication or long-term availability.

For larger files/folders/websites, the UI links to the
[Swarm Desktop upload workflow](https://docs.ethswarm.org/docs/desktop/upload-content/).
Paste the returned reference and select file/collection mode for `/bzz` roots.
That view opens the root/default document; the publisher does not select an inner
collection path. Use a separate file reference when publishing a specific item.
The [Bee API](https://docs.ethswarm.org/api/) distinguishes raw `/bytes` data from
`/bzz` file and collection resources.

Raw byte checking is bounded to 256 KiB. Downloads use an octet-stream Blob;
active content is not rendered in the publisher. Opening content requires a
different origin and uses `noopener noreferrer`. The manual viewer route does
not authenticate all large-file or collection bytes inside the app. Its checkbox
is the user's inspection declaration, not proof of human attention or safety.
Known raw-byte mismatches block acknowledgement in that access context.

After inspection, preview metadata, read the pinned guidelines and acknowledge
both. Metadata upload still verifies exact bytes. Fee approval only grants
permission; explicit submission pays the selected fee and enters moderation.
