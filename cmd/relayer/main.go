// Command relayer submits drand evmnet beacons to r/drand for every round
// that has pending requests.
//
// Signing key, one of:
//
//	RELAYER_MNEMONIC                        bip39 mnemonic (account 0, index 0)
//	-key <name> + RELAYER_PASSWORD          key from the gnokey keybase (-home)
//
// Example against a local gnodev:
//
//	RELAYER_MNEMONIC="..." relayer -remote http://127.0.0.1:26657 -chain-id dev
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gnolang/gno/gno.land/pkg/gnoclient"
	"github.com/gnolang/gno/gnovm/pkg/gnoenv"
	rpcclient "github.com/gnolang/gno/tm2/pkg/bft/rpc/client"
	"github.com/gnolang/gno/tm2/pkg/crypto/keys"

	"github.com/albttx/gno-drand/internal/relayer"
)

func main() {
	if err := run(); err != nil && !errors.Is(err, context.Canceled) {
		fmt.Fprintln(os.Stderr, "relayer:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		remote    = flag.String("remote", "https://rpc.gno.land:443", "gno.land RPC endpoint")
		chainID   = flag.String("chain-id", "gnoland-1", "gno.land chain id")
		pkgPath   = flag.String("pkgpath", "gno.land/r/albttx/drand/v0", "r/drand package path")
		home      = flag.String("home", gnoenv.HomeDir(), "gnokey home, used with -key")
		keyName   = flag.String("key", "", "gnokey key name or address (password in RELAYER_PASSWORD)")
		gasFee    = flag.String("gas-fee", "1000000ugnot", "fee per transaction")
		gasWanted = flag.Int64("gas-wanted", 30_000_000, "gas per submitted beacon")
		maxBatch  = flag.Int("max-batch", 10, "max beacons per transaction")
		interval  = flag.Duration("interval", 3*time.Second, "poll interval (evmnet period is 3s)")
		mirrors   = flag.String("drand", strings.Join(relayer.DefaultMirrors, ","), "comma-separated drand HTTP mirrors")
	)
	flag.Parse()
	log := slog.New(slog.NewTextHandler(os.Stderr, nil))

	signer, err := newSigner(*home, *keyName, *chainID)
	if err != nil {
		return err
	}
	rpc, err := rpcclient.NewHTTPClient(*remote)
	if err != nil {
		return fmt.Errorf("rpc client: %w", err)
	}
	info, err := signer.Info()
	if err != nil {
		return err
	}

	r := &relayer.Relayer{
		Source: relayer.HTTPSource{
			Mirrors: strings.Split(*mirrors, ","),
			Client:  &http.Client{Timeout: 5 * time.Second},
		},
		Chain: relayer.GnoChain{
			Client:    &gnoclient.Client{Signer: signer, RPCClient: rpc},
			PkgPath:   *pkgPath,
			GasFee:    *gasFee,
			GasWanted: *gasWanted,
		},
		Log:      log,
		MaxBatch: *maxBatch,
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	log.Info("relayer started", "remote", *remote, "chain_id", *chainID, "pkgpath", *pkgPath, "address", info.GetAddress().String())
	return r.Run(ctx, *interval)
}

func newSigner(home, keyName, chainID string) (gnoclient.Signer, error) {
	if m := os.Getenv("RELAYER_MNEMONIC"); m != "" {
		return gnoclient.SignerFromBip39(m, chainID, "", 0, 0)
	}
	if keyName == "" {
		return nil, errors.New("set RELAYER_MNEMONIC or -key")
	}
	kb, err := keys.NewKeyBaseFromDir(home)
	if err != nil {
		return nil, fmt.Errorf("open keybase: %w", err)
	}
	s := gnoclient.SignerFromKeybase{
		Keybase:  kb,
		Account:  keyName,
		Password: os.Getenv("RELAYER_PASSWORD"),
		ChainID:  chainID,
	}
	return s, s.Validate()
}
