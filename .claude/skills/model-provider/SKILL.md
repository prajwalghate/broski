---
name: model-provider
description: Add or change a model provider, or any code path that sends text to a model, without tying Broski to one company or leaking a local-only project - presets, the gateway, wire tests with a fake transport, and the privacy tests every send path needs. Use before touching Sources/BroskiCore/Models.swift, Gateway.swift, Providers.swift or a feature that calls a model.
---

# Models in Broski

## The shape

- **Features ask for a role** (`fast`, `everyday`, `deep`) through `ModelGateway` (`send`, or `sendJSON` for a schema). Never a provider, never a model id. The gateway masks secrets, routes by role, keeps local-only work on local models (or refuses), turns PDFs into text for models that can't read them, explains errors in the person's words, and logs usage.
- **Providers are presets** (`ProviderPreset` in Providers.swift): name, kind (Anthropic Messages API, OpenAI-compatible chat completions, Apple on-device), address, where to get a key, what it reads, whether its API takes a JSON schema, and a suggested model per role. Suggestions are checked against the provider's own `/models` list when it's connected (`ProviderCheck`); `pick` falls back to a model whose name fits the role.
- **Keys** stay on each device: the Mac's secrets file (`Secrets.key(forProvider:)`), the iPhone's Keychain (`Keychain.key(forProvider:)`). They never sync and never go in config.json.

## Adding a preset

1. Check the provider's docs today for the base URL, the key page, the current model ids and whether it supports `response_format: json_schema` and images. Model names change every few months: don't trust memory.
2. Add it to `ProviderPreset` and to `all`, and its symbol to `ProviderIcon`.
3. Tests in `Tests/BroskiCoreTests/ProvidersTests.swift`: it's recognized from its address (`ProviderPreset.of`), its suggestions are picked when offered, and the request it gets is right (use a fake `ModelTransport`; no test touches the network).

## Changing what's stored

`ModelProvider` lives in config.json, which older versions on other devices still read. Add only optional fields; never add a value to `ModelCapability` or `ModelProvider.Kind` (an older version would fail to read the whole file). There's a test for this (`providerFormat`).

## A new send path

- Through the gateway, with `localOnly:` set from the project, and a `task:` name for the spending breakdown.
- Untrusted text (files, pages, trackers) fenced as data in the prompt.
- A privacy test: with only cloud providers set up, a local-only request is refused before anything is sent (`localOnlyEverywhere` shows how), and a local-only project's text never appears in what a fake connector receives.
- A real call costs money: only with the person's yes, and say what it cost.
