# gno-drand

[![ci](https://github.com/albttx/gno-drand/actions/workflows/ci.yml/badge.svg)](https://github.com/albttx/gno-drand/actions/workflows/ci.yml)

> [!WARNING]
> This repository is the prototype. The code is being upstreamed to the official gno repository in [gnolang/gno#6268](https://github.com/gnolang/gno/pull/6268), which supersedes it:
>
> - The packages move to `gno.land/p/drand/v0` and `gno.land/r/drand/v0` (instead of `gno.land/{p,r}/albttx/drand/v0`), the demo to `gno.land/r/drand/coinflip/v0`, and the relayer to `contribs/gnodrand`.
> - The PR version is cheaper (`Verify` about 9.6M gas, `Submit` about 17.9M) and follows the current interrealm rules (no `cur.IsCurrent()` guard in crossing functions).
>
> New work should target the PR.

Verifiable randomness for every gno.land realm, from [drand](https://drand.love), checked on-chain.

A realm asks for randomness, a relayer brings the drand beacon, and gno.land verifies its BLS signature with the native BN254 pairing. No oracle committee, no trusted relayer: a relayer can only deliver the real beacon, or nothing.

It follows the same idea as Nois on Cosmos, without the IBC part: everything lives on one chain.

## Quick start: use it from a realm

```go
import "gno.land/r/albttx/drand/v0"

// tx 1: freeze your inputs (bets, tickets), then request.
func Close(cur realm) {
	reqID = drand.Request(cross(cur))
}

// tx 2: a few seconds later, once a relayer has delivered the round.
func Draw(cur realm) {
	if _, ready := drand.Status(reqID); !ready {
		panic("not yet")
	}
	winner = players[drand.Rand(reqID).IntN(len(players))]
}
```

[`r/demo/coinflip`](r/demo/coinflip/coinflip.gno) is a complete example.

**One rule:** record everything the randomness decides *before* calling `Request`. The request is pinned to a drand round that is not published yet, so nobody, including you and the validators, can know the outcome when the inputs are frozen.

## How it works

```
 consumer realm ──Request()──▶ r/drand ◀──Submit(round, sig)── relayer (anyone)
       ▲                          │ verifies with p/drand              ▲
       └─────────Get(id)──────────┘                       drand HTTP API (evmnet)
```

1. `Request` pins the request to the first drand round published at least `SafetyGap` (5s) after the current block time.
2. A relayer polls `PendingRounds`, fetches the round from drand once it is out, and calls `Submit`.
3. `Submit` verifies the signature on-chain and stores the 32-byte randomness. Only requested rounds are stored.
4. `Get(id)` returns `sha256(beacon || requester || ":" || id)`, so two requests on the same round get independent values.

### Why drand evmnet

drand runs several networks. **evmnet** (chain hash `04f1e906...6ec8c3`, one beacon every 3s) signs on the **BN254** curve, which gno.land exposes as native precompiles (`crypto/bn254`, same layout as Ethereum's EIP-196/197). That makes full on-chain verification possible without any chain upgrade.

| Item | Value |
|---|---|
| Scheme | `bls-bn254-unchained-on-g1` (signature on G1, key on G2) |
| Signed message | `keccak256(uint64_be(round))` |
| Hash to curve | RFC 9380, `expand_message_xmd` with keccak256, SVDW map |
| DST | `BLS_SIG_BN254G1_XMD:KECCAK-256_SVDW_RO_NUL_` |
| Randomness | `sha256(signature)`, identical to drand's published value |
| Check | `e(sig, G2) == e(H(m), pk)`, one native pairing call |

Cost: one verification is about 12M gas, roughly 0.012 GNOT at the mainnet price of 1 ugnot per 1000 gas. The relayer pays it, once per round, however many requests share that round.

## Packages

| Path | What |
|---|---|
| [`gno.land/p/albttx/drand/v0`](p/drand) | Pure library: `Verify`, `HashToG1`, `Randomness`, `Derive`, `NewRand`, `RoundAt`, `TimeOf` |
| [`gno.land/r/albttx/drand/v0`](r/drand) | The realm: `Request`, `RequestAfter`, `Submit`, `Get`, `MustGet`, `Status`, `Beacon`, `PendingRounds` |
| [`gno.land/r/albttx/demo/coinflip/v0`](r/demo/coinflip) | Example consumer |
| [`cmd/relayer`](cmd/relayer) | Go relayer binary |
| [`cmd/genvectors`](cmd/genvectors) | Regenerates the gno test vectors from live drand + kyber |
| [`internal/evmnet`](internal/evmnet) | Off-chain reference verifier (drand/kyber) |

### Realm API

| Function | Notes |
|---|---|
| `Request(cur) string` | Next safe round. Returns the request id. |
| `RequestAfter(cur, unix int64) string` | First round published strictly after `unix`, never earlier than the next safe round. |
| `Get(id) ([32]byte, bool)` | Per-request randomness, `false` until delivered. |
| `MustGet(id) [32]byte` | Panics until delivered. |
| `Rand(id) *rand.Rand` | PRNG seeded with `Get(id)`: `IntN`, `Shuffle`, `Perm`... Panics until delivered. |
| `Status(id) (round uint64, ready bool)` | `round` is 0 for an unknown id. |
| `Beacon(round) ([32]byte, bool)` | Raw drand randomness, shared by every user of that round. Prefer `Get`. |
| `Submit(cur, round uint64, sigHex string)` | Permissionless. Panics on a bad signature or an unrequested round; a resubmit is a no-op. |
| `PendingRounds(limit int) string` | Comma-separated rounds waiting for a beacon, oldest first, at most 100. |

The realm has no admin: no owner, no pause, no parameter a key can change. Changing behaviour means shipping a new version (`/v1`).

## Running a relayer

Anyone can run one. Relayers are interchangeable and only matter for liveness.

```sh
CGO_ENABLED=0 go build -o relayer ./cmd/relayer

# key from the gnokey keybase
RELAYER_PASSWORD=... ./relayer -key relayer

# or from a mnemonic
RELAYER_MNEMONIC="..." ./relayer -remote http://127.0.0.1:26657 -chain-id dev
```

| Flag | Default | Meaning |
|---|---|---|
| `-remote` | `https://rpc.gno.land:443` | gno.land RPC |
| `-chain-id` | `gnoland-1` | Chain id |
| `-pkgpath` | `gno.land/r/albttx/drand/v0` | Realm to serve |
| `-key` | | gnokey key name, password in `RELAYER_PASSWORD` |
| `-home` | gnokey default | Keybase directory |
| `-gas-fee` | `1000000ugnot` | Fee per transaction |
| `-gas-wanted` | `30000000` | Gas per beacon in the batch |
| `-max-batch` | `10` | Beacons per transaction |
| `-interval` | `3s` | Poll interval |
| `-drand` | api.drand.sh, api2, api3, drand.cloudflare.com | Mirrors, tried in order |

Each beacon is verified locally before it is sent, so a bad mirror never costs gas.

### Docker

```sh
docker run --rm -e RELAYER_MNEMONIC="..." ghcr.io/albttx/gno-drand-relayer:main
```

Images are published from `main` (`:main`, `:sha-<commit>`) and from `v*` tags (`:1.2.3`), for linux/amd64 and linux/arm64.

## Development

Requires `gno` and `gnodev` built from a `gnolang/gno` checkout at the revision the target chain runs (`chain/mainnet` for gnoland-1), with `GNOROOT` pointing at it.

```sh
make test       # gno lint + gno test + go vet + go test
make e2e        # gnodev + live drand: request, relay, verify, settle
make vectors    # regenerate p/drand/vectors_test.gno from live drand
```

`CGO_ENABLED=0` is set in the Makefile: the relayer does not need cgo.

CI (`.github/workflows`) runs the same gates on every PR: gofmt, `go vet`, golangci-lint, `gno fmt`, `gno lint`, gno and Go tests, the gnodev e2e, and a multi-arch image build. gno and gnodev are built from the gnolang/gno commit gnoland-1 runs.

## Limits

- **BN254 security.** evmnet's curve gives about 100 bits of security, against about 128 for drand's BLS12-381 networks. It is the trade-off Ethereum makes for its precompiles, fine for games, raffles and lotteries.
- **drand trust model.** Randomness is as good as the drand League of Entropy threshold: it is unbiasable unless a threshold of drand nodes collude.
- **Liveness.** If no relayer runs, requests wait. Nothing wrong can be delivered.
- **Block time.** `SafetyGap` covers normal drift between block time and real time. A proposer that sets block time far behind real time could pin a request to an already published round.
