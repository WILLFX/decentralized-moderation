# Content metadata

Metadata gives publishing, moderation and discovery a common description of an
item. Content and metadata are stored separately on Swarm. A listing case binds
both references and the ordered topic keys; the metadata JSON does not itself
contain the content reference.

Publisher creates this document from its form. Moderator and Reader check its
structure, topic keys and Swarm reference before using its descriptive fields.
The contract records the references and keys, not the JSON bytes. Moderators judge
whether the description and topics honestly describe the content.

## Version 1 fields

```json
{
  "schemaVersion": 1,
  "type": "article",
  "title": "Cells and DNA",
  "description": "A short introduction to cell structure.",
  "topics": ["biology"],
  "language": "en",
  "contentType": "text/plain",
  "source": "An author or source identifier"
}
```

| Field | Meaning and format |
| --- | --- |
| `schemaVersion` | Numeric value 1 |
| `type` | Item kind: `article`, `post`, `comment`, `image`, `video`, `audio`, `document`, `dataset` or `other` |
| `title` | Required, 1–200 Unicode characters |
| `description` | Optional string, up to 5,000 characters |
| `topics` | Required, 1–5 distinct normalized strings, each 1–64 characters |
| `language` | Optional language tag, up to 35 characters; a 2–3 letter language code followed by optional 2–8 character alphanumeric subtags |
| `contentType` | Required MIME type, up to 255 characters, such as `text/plain` or `image/png` |
| `source` | Optional string, up to 2,048 characters; a publisher-supplied source description, not an authenticated identity |

Unknown fields, duplicate JSON fields, invalid UTF-8, null optional values and
invalid field types are refused. Metadata is bounded to 256 KiB. An initial UTF-8
byte-order mark is ignored only after the original bytes are authenticated.
MIME type components use lowercase letters/digits and the parser's token alphabet;
parameters use `key=value` syntax. The parser in
`websites/crates/swarm-core/src/review.rs` defines the exact wire rules.

The item kind and file format serve different purposes: an article can be stored
as `text/plain` or `text/html`. Correct syntax does not prove that those declarations
are truthful. That remains part of content review.

## Topics and keys

Publisher normalizes topics using Unicode NFC, lowercase conversion, NFC again,
and collapsed whitespace. Leading/trailing whitespace is removed. For example,
`"  BiOlOgY  "` becomes `"biology"`. A pair that normalizes to the same string is a
duplicate, not two topics.

Each topic key is Keccak-256 of the normalized topic's UTF-8 bytes. The JSON topic
order must match the case's topic-key order. Reader and Moderator reject a mismatch.
Topics are plain labels; an optional category graph can group them in a discovery
client without changing the published topic keys or the contract.

## References and access

A Swarm reference is a content address, not a URL or a normal file checksum.
For bounded raw files, the clients calculate Swarm's binary-Merkle-tree reference
and compare it with the submitted reference. This differs from the plain
Keccak-256 used to identify contract code or the guidelines document.

Metadata uploaded by Publisher uses the raw `/bytes` route. The content reference
can identify raw bytes or a Bee file/collection. Its viewing route is supplied
by the selected profile, not by `type` or `contentType`. See
[matching content access](OPERATORS.md#match-content-access). Changing metadata
bytes changes its reference and therefore the content/metadata claim key.
