SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c

GHC  ?= 9.12
MAIN ?= Main
EXE  := $(shell basename $(MAIN) .Main)

.PHONY: dev exe env hie pg

dev:
	ghciwatch --clear --no-interrupt-reloads \
		--command ghci-$(GHC) \
		--error-file ghcid.txt \
		--enable-eval --watch .

exe:
	mkdir -p .build && ln -sf .build .hiefiles && ln -sf .build .hifiles
	ghc-$(GHC) -threaded -isrc -outputdir .build -main-is $(MAIN) -o .build/$(EXE) $(MAIN)

env:
	rm .ghc.environment.*$(GHC)* || true
	cabal install -w ghc-$(GHC) --allow-newer --enable-documentation \
		--package-env . --lib \
		base relude containers stm-containers text vector template-haskell \
		aeson aeson-optics generic-data optics safe-wild-cards witch \
		bluefin co-log ki io-classes io-sim nothunks strict-wrapper \
		hasql hasql-th hasql-pool hasql-transaction \
		http-api-data http-media http-types ihp-hsx lucid2 \
		servant servant-server ihp-router wai wai-extra warp \
		breakpoint rapid tasty tasty-hunit tasty-wai

hie:
	hiedb-$(GHC) -D .hiedb index .build

pg:
	docker run --name postgres \
		-e POSTGRES_PASSWORD=$(PGPASSWORD) \
		-p 5432:5432 \
		-d postgres
