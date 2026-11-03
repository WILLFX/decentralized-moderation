# Existing-work connection profiles

These profiles keep access to the earlier Chiado deployments through updated
clients that support `purpose: "existingWork"`. They disable new publication
fee approvals, new submissions and fresh staking in those clients. Existing-case
voting and completion, receipt recovery, refunds and eligible stake withdrawals
remain available under the contracts' original checks.

| Source | Publisher | Moderator | Reader |
| --- | --- | --- | --- |
| Earlier workflow deployment, moderation `0x7969b0941d2f41181b85211d95150c3b2501be50` | [Profile](earlier-workflow/publisher.json) | [Profile](earlier-workflow/moderator.json) | [Profile](earlier-workflow/reader.json) |
| Released MVP deployment, moderation `0x006392a3f365c3ed4b2ab39897c6de9e2346cdc8` | [Profile](released-mvp/publisher.json) | [Profile](released-mvp/moderator.json) | [Profile](released-mvp/reader.json) |

The deployments use different TEST token addresses. Each profile selects its own
actual token and registries. These sources are separate deployments, not versions
registered under the new persistent authority. The earlier approval stays at its
original index; it is not copied or re-reviewed merely to populate another index.

The supplied connections are local-Bee presets. Loopback URLs refer to the browser
user's device. Adapt RPC/read gateways for your own or an operator's services;
keep deployment pins and the existing-work purpose. These presets use raw `/bytes`
content access. Use the existing `contentPath`/viewer settings if your source uses
Bee file or collection references. No upload stamp or authorization is supplied.

This is client policy, not an on-chain shutdown. Old websites and direct contract
calls remain possible. Use a matching purpose-aware client: older builds may
reject or ignore the field. Adding a profile does not update a published website
or register an old deployment in a new authority.
