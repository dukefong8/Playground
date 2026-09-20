{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}

-- | The todo filter's client source, served at @/todo/todo_filter.cljs@:
-- its filename (single source of truth shared by the markup and the
-- embedding), its compile-time embedding, and the 'Application' serving it.
module Todo.Filter
  ( filterScriptFile
  , filterApp
  ) where

import Language.Haskell.TH.Syntax (addDependentFile)
import Network.HTTP.Types (methodGet, status405)
import Network.Wai (Application, pathInfo, requestMethod, responseLBS)

import Home.Route (notFoundResponse)
import Network.Wai.Application.Static (staticApp)
import Todo.Asset (todoFilterEntries)
import WaiAppStatic.Storage.Embedded (mkSettings)
import WaiAppStatic.Types (MaxAge (NoStore), ssMaxAge)

-- | Served at @/todo/todo_filter.cljs@, referenced by the page head.
filterScriptFile :: Text
filterScriptFile = "todo_filter.cljs"

-- FIXME: merge into Asset.hs
-- | Serve the embedded copy under @/todo@. No etag/max-age: the file changes
-- with every edit, so a cached copy is always the wrong copy. Embedding
-- happens at compile time, and @addDependentFile@ at the splice site makes an
-- edit to the @.cljs@ recompile this module — without that, GHC would see no
-- Haskell change and keep serving the previous embedding.
filterApp :: Application
filterApp req respond = case pathInfo req of
  ["todo", file] | file == filterScriptFile -> case requestMethod req of
    m | m == methodGet -> staticApp settings req respond
      | otherwise -> respond $ responseLBS status405 [] ""
  _ -> respond notFoundResponse
  where
    settings =
      ( $( do
            addDependentFile "static/todo_filter.cljs"
            mkSettings todoFilterEntries
        )
          { ssMaxAge = NoStore }
      )
