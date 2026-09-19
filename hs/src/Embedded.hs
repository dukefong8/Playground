{-# LANGUAGE OverloadedStrings #-}

-- | Files baked into the executable at compile time.
--
-- Kept in its own module because Template Haskell's stage restriction requires
-- the entry list to live somewhere other than the module calling 'mkSettings'.
module Embedded
  ( todoFilterEntries
  ) where

import Data.ByteString.Lazy qualified as LBS
import WaiAppStatic.Storage.Embedded (EmbeddableEntry (..))

-- | The todo filter's client source, served at @/todo-filter.cljs@.
--
-- The empty etag means "no etag", i.e. clients re-fetch every time: this file
-- changes with every edit, so a cached copy is always the wrong copy. Embedding
-- happens at compile time, and @addDependentFile@ at the splice site makes an
-- edit to the @.cljs@ recompile the serving module (the Makefile also reloads
-- ghciwatch on @**/*.cljs@), so the loop is edit → reload → browser refresh.
todoFilterEntries :: IO [EmbeddableEntry]
todoFilterEntries = do
  cljs <- readFileLBS "static/todo-filter.cljs"
  pure
    [ EmbeddableEntry
        { eLocation = "todo-filter.cljs"
        , eMimeType = "application/x-scittle"
        , eContent = Left ("", cljs)
        }
    ]
