export CGO_ENABLED = 0

.PHONY: test gno-test go-test e2e vectors fmt

test: gno-test go-test

gno-test:
	gno lint ./...
	gno test ./...

go-test:
	go vet ./...
	go test ./...

e2e:
	go test -tags e2e -count=1 -v ./e2e

vectors:
	go run ./cmd/genvectors -out gno.land/p/drand/vectors_test.gno

fmt:
	gno fmt -w ./gno.land/p ./gno.land/r
	gofmt -w cmd internal e2e
