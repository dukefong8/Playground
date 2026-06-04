{-# LANGUAGE OverloadedStrings #-}
module Htmx (hsx, module Lucid) where

import Data.Set qualified as Set
import IHP.HSX.Lucid2.QQ (customHsx)
import IHP.HSX.Parser
import Language.Haskell.TH.Quote
import Lucid

hsx :: QuasiQuoter
hsx = customHsx
    (HsxSettings
        { checkMarkup = True
        , additionalTagNames = Set.fromList
            [ "ty-button"
            , "ty-calendar"
            , "ty-calendar-month"
            , "ty-calendar-navigation"
            , "ty-checkbox"
            , "ty-copy"
            , "ty-date-picker"
            , "ty-dropdown"
            , "ty-file-upload"
            , "ty-icon"
            , "ty-input"
            , "ty-modal"
            , "ty-multiselect"
            , "ty-option"
            , "ty-popup"
            , "ty-radio"
            , "ty-radio-group"
            , "ty-resize-observer"
            , "ty-scroll-container"
            , "ty-step"
            , "ty-switch"
            , "ty-tab"
            , "ty-tabs"
            , "ty-tag"
            , "ty-textarea"
            , "ty-tooltip"
            , "ty-wizard"
            ]
        , additionalAttributeNames = Set.fromList
            [ "hx-action"
            , "hx-boost"
            , "hx-config"
            , "hx-confirm"
            , "hx-delete"
            , "hx-disable"
            , "hx-encoding"
            , "hx-get"
            , "hx-headers"
            , "hx-ignore"
            , "hx-include"
            , "hx-indicator"
            , "hx-method"
            , "hx-optimistic"
            , "hx-patch"
            , "hx-post"
            , "hx-preload"
            , "hx-preserve"
            , "hx-push-url"
            , "hx-put"
            , "hx-replace-url"
            , "hx-select"
            , "hx-select-oob"
            , "hx-swap"
            , "hx-swap-oob"
            , "hx-sync"
            , "hx-target"
            , "hx-trigger"
            , "hx-validate"
            , "hx-vals"
            , "appearance"
            , "flavor"
            ]
        }
    )
