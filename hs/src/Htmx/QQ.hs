{-# LANGUAGE OverloadedStrings #-}
module Htmx.QQ (hsx) where

import Data.Set qualified as Set
import IHP.HSX.Lucid2.QQ (customHsx)
import IHP.HSX.Parser
import Language.Haskell.TH.Quote

hsx :: QuasiQuoter
hsx = customHsx
    (HsxSettings
        { checkMarkup = True
        , additionalTagNames = Set.empty
        , additionalAttributeNames = Set.fromList
            [ "hx-action"
            , "hx-alpine-compat"
            , "hx-boost"
            , "hx-browser-indicator"
            , "hx-config"
            , "hx-confirm"
            , "hx-csp"
            , "hx-delete"
            , "hx-disable"
            , "hx-download"
            , "hx-encoding"
            , "hx-get"
            , "hx-headers"
            , "hx-head"
            , "hx-history-cache"
            , "hx-history-elt"
            , "hx-ignore"
            , "hx-include"
            , "hx-indicator"
            , "hx-live"
            , "hx-method"
            , "hx-morph-skip"
            , "hx-morph-skip-children"
            , "hx-multipart"
            , "hx-nonce"
            , "hx-on"
            , "hx-on:click"
            , "hx-on:input"
            , "hx-on::finally:swap"
            , "hx-optimistic"
            , "hx-patch"
            , "hx-pending"
            , "hx-post"
            , "hx-preload"
            , "hx-preserve"
            , "hx-prompt"
            , "hx-ptag"
            , "hx-push-url"
            , "hx-put"
            , "hx-query"
            , "hx-replace-url"
            , "hx-select"
            , "hx-select-oob"
            , "hx-sse"
            , "hx-status"
            , "hx-swap"
            , "hx-swap-oob"
            , "hx-sync"
            , "hx-target"
            , "hx-targets"
            , "hx-trigger"
            , "hx-upsert"
            , "hx-validate"
            , "hx-vals"
            , "hx-ws"
            ]
        }
    )
